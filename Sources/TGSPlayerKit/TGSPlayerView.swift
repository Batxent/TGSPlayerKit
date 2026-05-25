#if canImport(UIKit)
import UIKit

public protocol TGSPlayerViewDelegate: AnyObject {
    func tgsPlayerViewDidLoadFirstFrame(_ view: TGSPlayerView)
    func tgsPlayerViewDidStartPlaying(_ view: TGSPlayerView)
    func tgsPlayerViewDidPause(_ view: TGSPlayerView)
    func tgsPlayerView(_ view: TGSPlayerView, didFailWith error: TGSPlayerError)
}

public final class TGSPlayerView: UIView {
    // MARK: - Public configuration / callbacks
    public var configuration: TGSPlayerConfiguration
    public weak var delegate: TGSPlayerViewDelegate?
    public var animationLoader: TGSLottieAnimationLoading

    public var automaticallyLoadFirstFrame: Bool = false
    public var automaticallyLoadLastFrame: Bool = false
    public var playToCompletionOnStop: Bool = false
    public var stopAtNearestLoop: Bool = false

    public var started: () -> Void = {}
    public var completed: (Bool) -> Void = { _ in }
    public var frameUpdated: (Int, Int) -> Void = { _, _ in }
    public var isPlayingChanged: (Bool) -> Void = { _ in }

    public private(set) var currentFrameIndex: Int = 0
    public private(set) var currentFrameCount: Int = 0
    public private(set) var currentFrameRate: Int = 0

    public var currentFrameImage: UIImage? {
        if let image = imageView.image {
            return image
        }
        if let contents = layer.contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID {
            return UIImage(cgImage: contents as! CGImage)
        }
        return nil
    }

    public private(set) var isPlaying: Bool = false

    public var autoplay: Bool {
        get { visibilityGate.autoplay }
        set {
            visibilityGate.autoplay = newValue
            updateIsPlaying()
        }
    }

    public var visibility: Bool {
        get { visibilityGate.visibility }
        set {
            visibilityGate.visibility = newValue
            updateIsPlaying()
        }
    }

    public var overrideVisibility: Bool {
        get { visibilityGate.overrideVisibility }
        set {
            visibilityGate.overrideVisibility = newValue
            updateIsPlaying()
        }
    }

    public var source: TGSSource? {
        stateMachine.source
    }

    public var state: TGSPlayerState {
        stateMachine.state
    }

    public var silhouette: TGSStickerSilhouette? {
        get { silhouetteView.silhouette }
        set {
            silhouetteView.setSilhouette(newValue)
            updateSilhouetteVisibility(animated: false)
        }
    }

    public var showsSilhouetteUntilFirstFrame: Bool = true {
        didSet { updateSilhouetteVisibility(animated: false) }
    }

    public var silhouetteFadeOutDuration: TimeInterval = 0.25

    public var hasRenderedFirstFrame: Bool { hasSubmittedFirstFrame }

    public var silhouetteView: TGSStickerShimmerEffectView { _silhouetteView }

    // MARK: - Main-thread state
    private var stateMachine = TGSPlayerStateMachine()
    private var visibilityGate = TGSAnimatedStickerVisibilityGate()
    private var sourceCancellable: TGSCancellable?
    private var playbackMode: TGSAnimatedStickerPlaybackMode = .loop
    private var mode: TGSAnimatedStickerMode = .direct(cachePathPrefix: nil)
    private let imageView = UIImageView()
    private let _silhouetteView = TGSStickerShimmerEffectView()
    private var hasSubmittedFirstFrame: Bool = false

    // MARK: - sharedQueue-only state
    /// These fields are read/written **only** on `Self.sharedQueue`; the main thread
    /// touches them indirectly via dispatched work.
    /// This avoids releasing `lottie_render` state across threads and keeps heavy work off the main thread.
    private var frameSource: TGSAnimatedStickerFrameSource?
    private var frameQueue: TGSAnimatedStickerFrameQueue?
    private var playbackTimer: DispatchSourceTimer?

    // MARK: - Generation token
    /// Each `reset()` bumps the token; work on `sharedQueue` compares before committing to the main thread.
    /// Mismatches are dropped to avoid stale results from cell reuse / tab switches (visual glitches or races).
    /// Main thread writes and `sharedQueue` reads use a lock for a proper memory barrier.
    private let generationLock = NSLock()
    private var _setupGeneration: UInt64 = 0

    private func currentGeneration() -> UInt64 {
        generationLock.lock(); defer { generationLock.unlock() }
        return _setupGeneration
    }

    @discardableResult
    private func bumpGeneration() -> UInt64 {
        generationLock.lock(); defer { generationLock.unlock() }
        _setupGeneration &+= 1
        return _setupGeneration
    }

    /// Same idea as telegram-iOS: one module-wide serial `userInteractive` queue.
    /// File IO, gzip decode, rlottie load, `lottie_render`, and `CGImage` creation run here;
    /// the main thread only receives dispatched `CGImage`s and assigns `layer.contents`.
    /// Serial (not concurrent) caps global sticker decode/render concurrency so many cells
    /// do not all parallelize and drag the main thread.
    fileprivate static let sharedQueue: DispatchQueue = DispatchQueue(
        label: "com.tgsplayerkit.shared",
        qos: .userInteractive
    )

    public init(
        configuration: TGSPlayerConfiguration = TGSPlayerConfiguration(),
        animationLoader: TGSLottieAnimationLoading = TGSUnavailableLottieAnimationLoader()
    ) {
        self.configuration = configuration
        self.animationLoader = animationLoader
        super.init(frame: .zero)
        self.playbackMode = configuration.playbackMode
        self.mode = configuration.mode
        self.automaticallyLoadFirstFrame = configuration.automaticallyLoadFirstFrame
        self.automaticallyLoadLastFrame = configuration.automaticallyLoadLastFrame
        self.playToCompletionOnStop = configuration.playToCompletionOnStop
        isOpaque = false
        layer.contentsGravity = .resizeAspect
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .clear
        addSubview(imageView)
        _silhouetteView.isHidden = true
        addSubview(_silhouetteView)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    deinit {
        // `playbackTimer` / `frameSource` / `frameQueue` are sharedQueue-only.
        // Tear them down on `sharedQueue` so they are not released while `lottie_render` may still be running.
        let timer = self.playbackTimer
        let source = self.frameSource
        let queue = self.frameQueue
        Self.sharedQueue.async {
            timer?.cancel()
            _ = source
            _ = queue
        }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        _silhouetteView.frame = bounds
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        visibilityGate.isDisplaying = window != nil
        updateIsPlaying()
    }

    public func setSource(_ source: TGSSource) {
        stateMachine.setSource(source)
    }

    // MARK: - Setup / reset

    public func setup(
        source: TGSAnimatedStickerSource,
        width: Int,
        height: Int,
        playbackMode: TGSAnimatedStickerPlaybackMode = .loop,
        mode: TGSAnimatedStickerMode = .direct(cachePathPrefix: nil)
    ) {
        guard width >= 2, height >= 2 else {
            return
        }

        reset()
        self.playbackMode = playbackMode
        self.mode = mode
        updateSilhouetteVisibility(animated: false)

        switch mode {
        case .cached:
            sourceCancellable = source.cachedDataPath(width: width, height: height) { _ in
            }
        case .direct:
            // `reset()` already called `bumpGeneration()`. Capture `generation`; later
            // `sharedQueue` work and main-thread commits use it to drop stale results.
            let generation = currentGeneration()
            // Capture `animationLoader` on the main thread (callers may swap it between setups).
            let animationLoader = self.animationLoader
            sourceCancellable = source.directDataPath(attemptSynchronously: false) { [weak self] path in
                guard let self, let path else { return }
                guard self.currentGeneration() == generation else { return }
                Self.sharedQueue.async { [weak self] in
                    guard let self else { return }
                    guard self.currentGeneration() == generation else { return }
                    // mmap → gzip decode → rlottie load all run on `sharedQueue`.
                    // These are the heaviest cold-path steps; on the main thread, many visible cells
                    // can stall the panel for tens to hundreds of ms.
                    guard let data = try? Data(
                        contentsOf: URL(fileURLWithPath: path),
                        options: [.mappedRead]
                    ) else { return }
                    guard let loaded = TGSAnimatedStickerDirectFrameSource(
                        data: data,
                        width: width,
                        height: height,
                        cacheKey: path,
                        loader: animationLoader
                    ) else { return }
                    guard self.currentGeneration() == generation else { return }
                    self.frameSource = loaded
                    self.frameQueue = TGSAnimatedStickerFrameQueue(length: 1, source: loaded)

                    // Read main-thread-owned flags (`isPlaying`, `autoplay`, `automaticallyLoadFirstFrame`);
                    // hop back to the main queue to decide whether to start playback.
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        guard self.currentGeneration() == generation else { return }
                        if case let .still(position) = playbackMode {
                            self.seekTo(position)
                        } else if self.isPlaying || self.autoplay {
                            self.play()
                        } else if self.automaticallyLoadFirstFrame {
                            self.play(firstFrame: true, fromIndex: nil)
                        }
                    }
                }
            }
        }
    }

    public func reset() {
        // 1. Clear main-thread state synchronously: UI, state machine, generation.
        bumpGeneration()
        sourceCancellable?.cancel()
        sourceCancellable = nil
        currentFrameIndex = 0
        currentFrameCount = 0
        currentFrameRate = 0
        isPlaying = false
        hasSubmittedFirstFrame = false
        imageView.image = nil
        layer.contents = nil
        stateMachine.prepareForReuse()
        updateSilhouetteVisibility(animated: false)

        // 2. Release sharedQueue-only state on `sharedQueue`.
        // No generation check here — the next `setup` overwrites in-order on the serial queue; clearing unconditionally is safer.
        Self.sharedQueue.async { [weak self] in
            guard let self else { return }
            self.playbackTimer?.cancel()
            self.playbackTimer = nil
            self.frameSource = nil
            self.frameQueue = nil
        }
    }

    public func prepareForReuse() {
        reset()
    }

    // MARK: - Public play / pause / stop / seek

    public func play() {
        play(firstFrame: false, fromIndex: nil)
    }

    public func playOnce() {
        playbackMode = .once
        play()
    }

    public func playLoop() {
        playbackMode = .loop
        play()
    }

    public func play(firstFrame: Bool, fromIndex: Int?) {
        // Main thread: state machine + delegate.
        if let _ = source {
            stateMachine.play()
            switch stateMachine.state {
            case .playing:
                delegate?.tgsPlayerViewDidStartPlaying(self)
            case let .failed(error):
                delegate?.tgsPlayerView(self, didFailWith: error)
                return
            default:
                break
            }
        } else {
            // No `setSource()` — typical Hawa path loads via `setup()` only;
            // still notify the delegate that playback has started.
            delegate?.tgsPlayerViewDidStartPlaying(self)
        }

        let generation = currentGeneration()
        Self.sharedQueue.async { [weak self] in
            guard let self else { return }
            guard self.currentGeneration() == generation else { return }
            self.startPlaybackOnSharedQueue(
                firstFrame: firstFrame,
                fromIndex: fromIndex,
                generation: generation
            )
        }
    }

    public func pause() {
        stateMachine.pause()
        delegate?.tgsPlayerViewDidPause(self)
        cancelPlaybackTimerOnSharedQueue()
    }

    public func stop() {
        stateMachine.stop()
        isPlaying = false
        cancelPlaybackTimerOnSharedQueue()
    }

    private func cancelPlaybackTimerOnSharedQueue() {
        // No generation check: cancel is always safe. The serial `sharedQueue` orders
        // chained calls like pause→play; the last enqueued operation wins.
        Self.sharedQueue.async { [weak self] in
            guard let self else { return }
            self.playbackTimer?.cancel()
            self.playbackTimer = nil
        }
    }

    public func seekTo(_ position: TGSAnimatedStickerPlaybackPosition) {
        let generation = currentGeneration()
        Self.sharedQueue.async { [weak self] in
            guard let self else { return }
            guard self.currentGeneration() == generation else { return }
            self.seekToOnSharedQueue(position, generation: generation)
        }
    }

    @discardableResult
    public func playIfNeeded() -> Bool {
        guard !isPlaying else {
            return false
        }
        isPlaying = true
        play()
        return true
    }

    public func renderFirstFrame() {
        guard source != nil else {
            stateMachine.fail(.invalidSource)
            delegate?.tgsPlayerView(self, didFailWith: .invalidSource)
            return
        }
        stateMachine.markReady()
        delegate?.tgsPlayerViewDidLoadFirstFrame(self)
    }

    // MARK: - Layout helpers

    public func updateLayout(size: CGSize) {
        frame = CGRect(origin: frame.origin, size: size)
        setNeedsLayout()
    }

    public func setOverlayColor(_ color: UIColor?, replace: Bool, animated: Bool) {
        imageView.tintColor = color
        imageView.image = imageView.image?.withRenderingMode(color == nil ? .alwaysOriginal : .alwaysTemplate)
    }

    /// Legacy hook for pushing a frame directly (rare). Must run on the main thread.
    public func submitFrame(_ image: CGImage) {
        layer.contents = image
    }

    /// Legacy API. The internal playback path **does not** use this (`renderTickOnSharedQueue`
    /// sets `contents` from `sharedQueue`); kept for external one-off static frame submission.
    public func submitFrame(_ frame: TGSAnimatedStickerFrame) {
        guard frame.type == .argb else {
            return
        }
        guard let image = Self.makeUIImage(from: frame) else {
            return
        }
        imageView.image = image
        currentFrameIndex = frame.index
        currentFrameCount = frame.totalFrames
        frameUpdated(frame.index, frame.totalFrames)
        started()
        delegate?.tgsPlayerViewDidLoadFirstFrame(self)
        if !hasSubmittedFirstFrame {
            hasSubmittedFirstFrame = true
            updateSilhouetteVisibility(animated: true)
        }
    }

    // MARK: - sharedQueue helpers

    /// `sharedQueue` only. Renders the current frame immediately, then starts a repeating timer if needed.
    private func startPlaybackOnSharedQueue(
        firstFrame: Bool,
        fromIndex: Int?,
        generation: UInt64
    ) {
        guard let frameSource else {
            // `setup` still loading; when `frameSource` is ready the setup closure will call
            // `play()` again and this path will run with a live source.
            return
        }
        guard frameQueue != nil else { return }
        if let fromIndex {
            frameSource.skipToFrameIndex(fromIndex)
        }
        playbackTimer?.cancel()
        playbackTimer = nil

        // Draw one frame immediately so the first frame appears without waiting for the timer.
        renderTickOnSharedQueue(generation: generation)

        if firstFrame {
            return
        }

        let interval = 1.0 / Double(max(1, frameSource.frameRate))
        let timer = DispatchSource.makeTimerSource(queue: Self.sharedQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.currentGeneration() == generation else {
                self.playbackTimer?.cancel()
                self.playbackTimer = nil
                return
            }
            self.renderTickOnSharedQueue(generation: generation)
        }
        playbackTimer = timer
        timer.resume()
    }

    /// `sharedQueue` only. Take one frame → `lottie_render` → build `CGImage` → main thread sets `contents`.
    private func renderTickOnSharedQueue(generation: UInt64) {
        guard let frameQueue else { return }
        guard let frame = frameQueue.take(draw: true) else { return }
        // With queue length 1 there is no next-frame prefetch; keep the call for when length grows.
        frameQueue.generateFramesIfNeeded()

        let cgImage = Self.makeCGImage(from: frame)
        let frameRate = frameSource?.frameRate ?? 0
        let isLast = frame.isLastFrame
        let frameIndex = frame.index
        let totalFrames = frame.totalFrames

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.currentGeneration() == generation else { return }

            if let cgImage {
                self.layer.contents = cgImage
            }
            self.currentFrameIndex = frameIndex
            self.currentFrameCount = totalFrames
            self.currentFrameRate = frameRate
            self.frameUpdated(frameIndex, totalFrames)

            if !self.hasSubmittedFirstFrame {
                self.hasSubmittedFirstFrame = true
                self.started()
                self.delegate?.tgsPlayerViewDidLoadFirstFrame(self)
                self.updateSilhouetteVisibility(animated: true)
            }

            if isLast {
                var shouldStop = false
                switch self.playbackMode {
                case .once, .still:
                    shouldStop = true
                case let .count(count):
                    shouldStop = count <= 1
                    if count > 1 {
                        self.playbackMode = .count(count - 1)
                    }
                case .loop:
                    shouldStop = self.stopAtNearestLoop
                }
                self.completed(shouldStop)
                if shouldStop {
                    self.stop()
                }
            }
        }
    }

    /// `sharedQueue` only.
    private func seekToOnSharedQueue(
        _ position: TGSAnimatedStickerPlaybackPosition,
        generation: UInt64
    ) {
        guard let frameSource else { return }
        switch position {
        case .start:
            frameSource.skipToFrameIndex(0)
        case .end:
            frameSource.skipToEnd()
        case let .frameIndex(index):
            frameSource.skipToFrameIndex(index)
        case let .timestamp(timestamp):
            let duration = frameSource.frameRate > 0
                ? Double(frameSource.frameCount) / Double(frameSource.frameRate)
                : 0
            guard duration > 0 else { return }
            var ts = timestamp
            while ts > duration { ts -= duration }
            frameSource.skipToFrameIndex(Int(ts / duration * Double(frameSource.frameCount)))
        }

        // After seek, show the frame at the new position immediately.
        frameQueue = TGSAnimatedStickerFrameQueue(length: 1, source: frameSource)
        startPlaybackOnSharedQueue(firstFrame: true, fromIndex: nil, generation: generation)
    }

    // MARK: - Image creation (thread-safe)

    /// Safe from any thread; does not retain `self`.
    /// Each `lottie_render` yields `Data` backed by an independent buffer, so the next frame
    /// on `sharedQueue` cannot overwrite pixels already handed off to the main thread as a `CGImage`.
    private static func makeCGImage(from frame: TGSAnimatedStickerFrame) -> CGImage? {
        guard frame.type == .argb else {
            return nil
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedFirst.rawValue |
            CGBitmapInfo.byteOrder32Little.rawValue
        )
        guard let provider = CGDataProvider(data: frame.data as CFData) else {
            return nil
        }
        return CGImage(
            width: frame.width,
            height: frame.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: frame.bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    private static func makeUIImage(from frame: TGSAnimatedStickerFrame) -> UIImage? {
        makeCGImage(from: frame).map { UIImage(cgImage: $0) }
    }

    // MARK: - Silhouette / Visibility

    private func updateSilhouetteVisibility(animated: Bool) {
        let shouldShow = showsSilhouetteUntilFirstFrame
            && _silhouetteView.silhouette != nil
            && !hasSubmittedFirstFrame

        if shouldShow {
            bringSubviewToFront(_silhouetteView)
            _silhouetteView.alpha = 1
            _silhouetteView.isHidden = false
            _silhouetteView.startAnimating()
            return
        }

        guard !_silhouetteView.isHidden else {
            _silhouetteView.stopAnimating()
            return
        }

        let finalize: () -> Void = { [weak self] in
            guard let self else { return }
            self._silhouetteView.isHidden = true
            self._silhouetteView.alpha = 1
            self._silhouetteView.stopAnimating()
        }

        if animated, silhouetteFadeOutDuration > 0 {
            UIView.animate(
                withDuration: silhouetteFadeOutDuration,
                delay: 0,
                options: [.beginFromCurrentState, .allowUserInteraction],
                animations: { [weak self] in
                    self?._silhouetteView.alpha = 0
                },
                completion: { _ in finalize() }
            )
        } else {
            finalize()
        }
    }

    private func updateIsPlaying() {
        let nextIsPlaying = visibilityGate.shouldPlay
        guard isPlaying != nextIsPlaying else {
            return
        }
        isPlaying = nextIsPlaying
        if nextIsPlaying {
            play()
        } else {
            pause()
        }
        isPlayingChanged(nextIsPlaying)
    }
}
#endif

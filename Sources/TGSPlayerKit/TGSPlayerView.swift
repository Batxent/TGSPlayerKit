#if canImport(UIKit)
import QuartzCore
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
        if let image = _imageView?.image {
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
        get { _silhouetteView?.silhouette }
        set {
            // Only materialize the shimmer view when the caller actually wants a silhouette.
            // Listing 60+ cells with no silhouette saves 60 * (CAShapeLayer + CAGradientLayer + ...)
            // worth of layer tree, layout, and hit-test overhead.
            if newValue == nil && _silhouetteView == nil {
                return
            }
            silhouetteView.setSilhouette(newValue)
            updateSilhouetteVisibility(animated: false)
        }
    }

    public var showsSilhouetteUntilFirstFrame: Bool = true {
        didSet { updateSilhouetteVisibility(animated: false) }
    }

    public var silhouetteFadeOutDuration: TimeInterval = 0.25

    public var hasRenderedFirstFrame: Bool { hasSubmittedFirstFrame }

    /// Lazily materialized; tests rely on accessing this property forcing the view to exist.
    public var silhouetteView: TGSStickerShimmerEffectView {
        if let view = _silhouetteView {
            return view
        }
        let view = TGSStickerShimmerEffectView()
        view.frame = bounds
        view.isHidden = true
        _silhouetteView = view
        addSubview(view)
        return view
    }

    // MARK: - Main-thread state
    private var stateMachine = TGSPlayerStateMachine()
    private var visibilityGate = TGSAnimatedStickerVisibilityGate()
    private var sourceCancellable: TGSCancellable?
    private var playbackMode: TGSAnimatedStickerPlaybackMode = .loop
    private var mode: TGSAnimatedStickerMode = .direct(cachePathPrefix: nil)
    /// Created on demand for the legacy `submitFrame(_:)` / `setOverlayColor` paths.
    /// The hot rendering path writes directly to `self.layer.contents`, so most cells in
    /// a long sticker list never pay for an extra `UIImageView` in their hierarchy.
    private var _imageView: UIImageView?
    private var _silhouetteView: TGSStickerShimmerEffectView?
    private var hasSubmittedFirstFrame: Bool = false

    // MARK: - workQueue-only state
    /// All heavy lifting (file IO, gzip decode, rlottie load, `lottie_render`, `CGImage` creation)
    /// runs on this view's `workQueue`. Each view owns its own serial `workQueue` that targets
    /// the module-wide concurrent `renderPool`, so:
    ///   1. Many sticker views render in parallel (~processor count) — matching Telegram's
    ///      `Queue.concurrentDefaultQueue()` + per-node serial frame pipeline model.
    ///   2. A single view's frames are still serialized, because `rlottie::Animation` mutates
    ///      no shared state across `renderSync` calls only when the caller doesn't interleave
    ///      operations on a single instance.
    private var frameSource: TGSAnimatedStickerFrameSource?
    private var frameQueue: TGSAnimatedStickerFrameQueue?
    private var playbackTimer: DispatchSourceTimer?

    // MARK: - Generation token
    /// Each `reset()` bumps the token; work on `workQueue` compares before committing to the main thread.
    /// Mismatches are dropped to avoid stale results from cell reuse / tab switches (visual glitches or races).
    /// Main thread writes and `workQueue` reads use a lock for a proper memory barrier.
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

    /// Module-wide concurrent render pool — the rough UIKit equivalent of Telegram iOS's
    /// `Queue.concurrentDefaultQueue()`. Per-view serial `workQueue`s target this pool so
    /// the scheduler can run as many sticker views in parallel as there are CPU cores.
    fileprivate static let renderPool: DispatchQueue = DispatchQueue(
        label: "com.tgsplayerkit.render-pool",
        qos: .userInteractive,
        attributes: .concurrent
    )

    /// Per-view serial queue. Created lazily so views that never get a `setup()` don't pay
    /// for the dispatch queue object. Targets the shared `renderPool` so heavy work fans out.
    private lazy var workQueue: DispatchQueue = DispatchQueue(
        label: "com.tgsplayerkit.view",
        qos: .userInteractive,
        target: Self.renderPool
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
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    deinit {
        // `playbackTimer` / `frameSource` / `frameQueue` are `workQueue`-only.
        // Tear them down on `workQueue` so they are not released while `lottie_render` may still be running.
        let queue = self.workQueue
        let timer = self.playbackTimer
        let source = self.frameSource
        let fq = self.frameQueue
        queue.async {
            timer?.cancel()
            _ = source
            _ = fq
        }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        // Layout passes inside an outer UIView.animate {} block would otherwise pick up
        // an implicit fade animation on every frame swap. Disable actions here for the
        // entire sublayer relayout — `layer.contents` writes also run inside their own
        // disabled-actions transaction below.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        _imageView?.frame = bounds
        _silhouetteView?.frame = bounds
        CATransaction.commit()
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
            // `workQueue` work and main-thread commits use it to drop stale results.
            let generation = currentGeneration()
            // Capture `animationLoader` on the main thread (callers may swap it between setups).
            let animationLoader = self.animationLoader
            sourceCancellable = source.directDataPath(attemptSynchronously: false) { [weak self] path in
                guard let self, let path else { return }
                guard self.currentGeneration() == generation else { return }
                self.workQueue.async { [weak self] in
                    guard let self else { return }
                    guard self.currentGeneration() == generation else { return }
                    // mmap → gzip decode → rlottie load all run on `workQueue` (parallel across
                    // views thanks to the concurrent `renderPool` target). A shared
                    // `LottieInstance` cache inside the loader collapses N identical loads to 1.
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
        _imageView?.image = nil
        // Wrap the contents clear in a no-action transaction so cell reuse doesn't trigger
        // a cross-fade between the previous sticker's last frame and the new sticker's first.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = nil
        CATransaction.commit()
        stateMachine.prepareForReuse()
        updateSilhouetteVisibility(animated: false)

        // 2. Release workQueue-only state on `workQueue`.
        // No generation check here — the next `setup` overwrites in-order on the serial queue; clearing unconditionally is safer.
        workQueue.async { [weak self] in
            guard let self else { return }
            self.playbackTimer?.cancel()
            self.playbackTimer = nil
            self.frameSource = nil
            self.frameQueue = nil
            // Mirror the main-thread `hasSubmittedFirstFrame = false` so the next setup's
            // first frame re-runs the started() / silhouette fade transition exactly once.
            self.hasSubmittedFirstFrameOnWorkQueue = false
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
        workQueue.async { [weak self] in
            guard let self else { return }
            guard self.currentGeneration() == generation else { return }
            self.startPlaybackOnWorkQueue(
                firstFrame: firstFrame,
                fromIndex: fromIndex,
                generation: generation
            )
        }
    }

    public func pause() {
        stateMachine.pause()
        delegate?.tgsPlayerViewDidPause(self)
        cancelPlaybackTimerOnWorkQueue()
    }

    public func stop() {
        stateMachine.stop()
        isPlaying = false
        cancelPlaybackTimerOnWorkQueue()
    }

    private func cancelPlaybackTimerOnWorkQueue() {
        // No generation check: cancel is always safe. The serial `workQueue` orders
        // chained calls like pause→play; the last enqueued operation wins.
        workQueue.async { [weak self] in
            guard let self else { return }
            self.playbackTimer?.cancel()
            self.playbackTimer = nil
        }
    }

    public func seekTo(_ position: TGSAnimatedStickerPlaybackPosition) {
        let generation = currentGeneration()
        workQueue.async { [weak self] in
            guard let self else { return }
            guard self.currentGeneration() == generation else { return }
            self.seekToOnWorkQueue(position, generation: generation)
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
        let view = imageView()
        view.tintColor = color
        view.image = view.image?.withRenderingMode(color == nil ? .alwaysOriginal : .alwaysTemplate)
    }

    /// Legacy hook for pushing a frame directly (rare). Must run on the main thread.
    public func submitFrame(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = image
        CATransaction.commit()
    }

    /// Legacy API. The internal playback path **does not** use this (`renderTickOnWorkQueue`
    /// sets `contents` from `workQueue`); kept for external one-off static frame submission.
    public func submitFrame(_ frame: TGSAnimatedStickerFrame) {
        guard frame.type == .argb else {
            return
        }
        guard let image = Self.makeUIImage(from: frame) else {
            return
        }
        imageView().image = image
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

    // MARK: - workQueue helpers

    /// `workQueue` only. Renders the current frame immediately, then starts a repeating timer if needed.
    private func startPlaybackOnWorkQueue(
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
        renderTickOnWorkQueue(skipFrames: 0, generation: generation)

        if firstFrame {
            return
        }

        let interval = 1.0 / Double(max(1, frameSource.frameRate))
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self, weak timer] in
            guard let self, let timer else { return }
            guard self.currentGeneration() == generation else {
                self.playbackTimer?.cancel()
                self.playbackTimer = nil
                return
            }
            // `timer.data` is the number of ticks accumulated since the last handler call.
            // When the render pool falls behind (long lists, thermal throttling), we want to
            // advance the frame index by the missed count but only render the latest frame —
            // never burn CPU rendering stale intermediate frames the user will never see.
            let ticks = max(1, Int(timer.data))
            self.renderTickOnWorkQueue(skipFrames: ticks - 1, generation: generation)
        }
        playbackTimer = timer
        timer.resume()
    }

    /// `workQueue` only. Advance `skipFrames` frames without rendering, then render the next frame
    /// and hand it to the main thread.
    private func renderTickOnWorkQueue(skipFrames: Int, generation: UInt64) {
        guard let frameQueue else { return }
        if skipFrames > 0, let frameSource {
            // Drain skipped frames cheaply (no rlottie render, no CGImage creation).
            for _ in 0..<skipFrames {
                _ = frameSource.takeFrame(draw: false)
            }
        }
        guard let frame = frameQueue.take(draw: true) else { return }
        // With queue length 1 there is no next-frame prefetch; keep the call for when length grows.
        frameQueue.generateFramesIfNeeded()

        let cgImage = Self.makeCGImage(from: frame)
        let frameRate = frameSource?.frameRate ?? 0
        let isLast = frame.isLastFrame
        let frameIndex = frame.index
        let totalFrames = frame.totalFrames

        // Snapshot the few flags we actually need on the main thread, then dispatch a small,
        // tight commit. The goal is to keep this main-thread closure under a few hundred
        // nanoseconds in steady state so 100+ visible cells don't saturate the main RunLoop.
        let firstFrameThisRun = !hasSubmittedFirstFrameOnWorkQueue
        if firstFrameThisRun {
            hasSubmittedFirstFrameOnWorkQueue = true
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.currentGeneration() == generation else { return }

            if let cgImage {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.layer.contents = cgImage
                CATransaction.commit()
            }
            self.currentFrameIndex = frameIndex
            self.currentFrameCount = totalFrames
            self.currentFrameRate = frameRate
            self.frameUpdated(frameIndex, totalFrames)

            if firstFrameThisRun, !self.hasSubmittedFirstFrame {
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

    /// `workQueue` only. Mirrors `hasSubmittedFirstFrame` but lives off-main so the first-frame
    /// transition (delegate + silhouette fade) is scheduled exactly once even under fast cell reuse.
    private var hasSubmittedFirstFrameOnWorkQueue: Bool = false

    /// `workQueue` only.
    private func seekToOnWorkQueue(
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
        startPlaybackOnWorkQueue(firstFrame: true, fromIndex: nil, generation: generation)
    }

    // MARK: - Image creation (thread-safe)

    /// Safe from any thread; does not retain `self`.
    /// Each `lottie_render` yields `Data` backed by an independent buffer, so the next frame
    /// on `workQueue` cannot overwrite pixels already handed off to the main thread as a `CGImage`.
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
            // Rendered at exact pixel size of the player view; CoreGraphics interpolation
            // would just add per-frame GPU sampling cost for no quality gain.
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private static func makeUIImage(from frame: TGSAnimatedStickerFrame) -> UIImage? {
        makeCGImage(from: frame).map { UIImage(cgImage: $0) }
    }

    // MARK: - Silhouette / Visibility

    private func imageView() -> UIImageView {
        if let view = _imageView {
            return view
        }
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.backgroundColor = .clear
        view.frame = bounds
        _imageView = view
        // Insert under any existing silhouette so the shimmer remains on top.
        if let silhouette = _silhouetteView {
            insertSubview(view, belowSubview: silhouette)
        } else {
            addSubview(view)
        }
        return view
    }

    private func updateSilhouetteVisibility(animated: Bool) {
        // No silhouette view ever materialized → nothing to show / hide. This is the common
        // path for non-silhouette stickers and we deliberately avoid creating the view here.
        guard let silhouetteView = _silhouetteView else { return }

        let shouldShow = showsSilhouetteUntilFirstFrame
            && silhouetteView.silhouette != nil
            && !hasSubmittedFirstFrame

        if shouldShow {
            bringSubviewToFront(silhouetteView)
            silhouetteView.alpha = 1
            silhouetteView.isHidden = false
            silhouetteView.startAnimating()
            return
        }

        guard !silhouetteView.isHidden else {
            silhouetteView.stopAnimating()
            return
        }

        let finalize: () -> Void = { [weak silhouetteView] in
            silhouetteView?.isHidden = true
            silhouetteView?.alpha = 1
            silhouetteView?.stopAnimating()
        }

        if animated, silhouetteFadeOutDuration > 0 {
            UIView.animate(
                withDuration: silhouetteFadeOutDuration,
                delay: 0,
                options: [.beginFromCurrentState, .allowUserInteraction],
                animations: { [weak silhouetteView] in
                    silhouetteView?.alpha = 0
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

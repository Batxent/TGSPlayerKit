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
    /// In-flight cache *write* for `.cached` mode's first-play fallback path. Separate
    /// from `sourceCancellable` because cancelling it only unsubscribes our handler —
    /// the underlying `TGSCachedFrameGenerator` task keeps going and finishes writing
    /// the `.tgsc` file, which is exactly what we want so the next play hits the fast
    /// path even if this cell scrolled away mid-write.
    private var cacheGenerationCancellable: TGSCancellable?
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

    // MARK: - Coordinator wiring (main thread)
    /// When this view is actively driving playback, it's registered with
    /// `TGSPlaybackCoordinator.shared`, which fires a global `CADisplayLink` and asks the
    /// view for the next frame at every vsync. The entry is the channel through which the
    /// view's workQueue publishes rendered frames back to the coordinator for batched
    /// commit. `nil` means this view is currently idle (paused / stopped / reset / never
    /// started). Main-thread only.
    private var coordinatorEntry: TGSPlaybackCoordinator.ViewEntry?

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
        // Coordinator holds a weak reference to self via its ViewEntry, so it will
        // auto-prune our entry on its next vsync. We deliberately do NOT dispatch a
        // cleanup to the main thread from here — Swift's deinit guarantees no further
        // references to self exist, and queueing an async closure that captured the
        // about-to-be-deallocated reference would be undefined behavior.
        //
        // `frameSource` / `frameQueue` are workQueue-only state; release them on the
        // workQueue so they can't be dropped mid-render. Capture them by value so the
        // closure doesn't reference self.
        let queue = self.workQueue
        let source = self.frameSource
        let fq = self.frameQueue
        queue.async {
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

        // `reset()` already called `bumpGeneration()`. Capture `generation`; later
        // `workQueue` work and main-thread commits use it to drop stale results.
        let generation = currentGeneration()

        switch mode {
        case .cached:
            sourceCancellable = source.cachedDataPath(width: width, height: height) { [weak self] result in
                guard let self else { return }
                guard self.currentGeneration() == generation else { return }
                if let result, result.complete {
                    // Cache file is on disk and the source says it's complete.
                    // Try the fast path; if the file is corrupt or sized for a
                    // different (width, height), wipe it and fall through to direct.
                    self.openCachedSourceOrFallbackToDirect(
                        source: source,
                        cachePath: result.path,
                        width: width,
                        height: height,
                        playbackMode: playbackMode,
                        generation: generation
                    )
                } else {
                    // Either the source can't suggest a cache path (`nil`) or the file
                    // isn't there yet. Render direct now for immediate playback, and if
                    // we *do* have a target path, fire off background cache generation
                    // so the next play (or another view's request) hits fast path.
                    self.sourceCancellable = self.loadDirect(
                        source: source,
                        width: width,
                        height: height,
                        playbackMode: playbackMode,
                        generation: generation,
                        cacheWritePath: result?.path
                    )
                }
            }
        case .direct:
            sourceCancellable = loadDirect(
                source: source,
                width: width,
                height: height,
                playbackMode: playbackMode,
                generation: generation,
                cacheWritePath: nil
            )
        }
    }

    /// Drives the "load `.tgs` via the source → mmap → build
    /// `TGSAnimatedStickerDirectFrameSource` → install" pipeline. Used by both
    /// `.direct` mode and `.cached`'s first-play fallback.
    ///
    /// When `cacheWritePath` is non-nil the same mapped `.tgs` data is also handed
    /// off to `TGSCachedFrameGenerator.shared` for a fire-and-forget background
    /// write so the next request at this `(source, width, height)` hits the fast path.
    private func loadDirect(
        source: TGSAnimatedStickerSource,
        width: Int,
        height: Int,
        playbackMode: TGSAnimatedStickerPlaybackMode,
        generation: UInt64,
        cacheWritePath: String?
    ) -> TGSCancellable {
        // Capture `animationLoader` on the calling thread (callers may swap it between
        // setups, and we need the value that was active at the time of this load).
        let animationLoader = self.animationLoader
        return source.directDataPath(attemptSynchronously: false) { [weak self] path in
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

                // Schedule background cache generation if the caller wants the
                // `.tgsc` written for next time. The generator dedupes by path, so
                // N views in a list rendering the same sticker only do this once.
                if let cacheWritePath {
                    let generatorCacheKey = (source as? TGSAnimatedStickerLocalFileSource)?.cacheKey ?? path
                    let cancellable = TGSCachedFrameGenerator.shared.generate(
                        tgsData: data,
                        cachePath: cacheWritePath,
                        cacheKey: generatorCacheKey,
                        width: width,
                        height: height,
                        loader: animationLoader,
                        completionQueue: .main
                    ) { _ in
                        // Result is irrelevant to the foreground render: success means
                        // the next play is fast, failure means the next play just goes
                        // through this same `loadDirect` path again. Either way, no
                        // user-visible change to this play.
                    }
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        guard self.currentGeneration() == generation else {
                            cancellable.cancel()
                            return
                        }
                        self.cacheGenerationCancellable = cancellable
                    }
                }

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

    /// Tries to open the cache file at `cachePath` as a `TGSAnimatedStickerCachedFrameSource`.
    /// On any failure (file missing, corrupt magic, version mismatch, wrong baked dims)
    /// the file is removed and the load falls back to `loadDirect(...)` which will
    /// regenerate the cache as a side effect.
    private func openCachedSourceOrFallbackToDirect(
        source: TGSAnimatedStickerSource,
        cachePath: String,
        width: Int,
        height: Int,
        playbackMode: TGSAnimatedStickerPlaybackMode,
        generation: UInt64
    ) {
        workQueue.async { [weak self] in
            guard let self else { return }
            guard self.currentGeneration() == generation else { return }

            if let cached = try? TGSAnimatedStickerCachedFrameSource(cachePath: cachePath),
               cached.width == width,
               cached.height == height {
                guard self.currentGeneration() == generation else { return }
                self.frameSource = cached
                self.frameQueue = TGSAnimatedStickerFrameQueue(length: 1, source: cached)
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
                return
            }

            // Cache file unusable (missing / corrupt / wrong dims). Remove it so the
            // background regenerate from `loadDirect` writes a fresh one rather than
            // hitting "file exists, skip" on the writer's atomic-rename path.
            try? FileManager.default.removeItem(atPath: cachePath)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.currentGeneration() == generation else { return }
                self.sourceCancellable = self.loadDirect(
                    source: source,
                    width: width,
                    height: height,
                    playbackMode: playbackMode,
                    generation: generation,
                    cacheWritePath: cachePath
                )
            }
        }
    }

    public func reset() {
        // 1. Clear main-thread state synchronously: UI, state machine, generation.
        bumpGeneration()
        sourceCancellable?.cancel()
        sourceCancellable = nil
        // Cancelling the generator handler only drops our completion; the underlying
        // writer keeps going so the cache still lands on disk for the next play.
        cacheGenerationCancellable?.cancel()
        cacheGenerationCancellable = nil
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
        // Drop our coordinator registration; the global display link can park if no
        // other views are active. Any in-flight worker task for the previous entry
        // will resolve harmlessly because the generation check will fail.
        TGSPlaybackCoordinator.shared.unregister(self)
        coordinatorEntry = nil

        // 2. Release workQueue-only state on `workQueue`.
        // No generation check here — the next `setup` overwrites in-order on the serial queue; clearing unconditionally is safer.
        workQueue.async { [weak self] in
            guard let self else { return }
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
        // Stop receiving vsync ticks. Any in-flight render task on the workQueue still
        // runs to completion; its result goes into the now-detached entry's pending slot
        // (the coordinator already dropped that entry from its map, so the commit is
        // never applied — same effect as cancelling).
        TGSPlaybackCoordinator.shared.unregister(self)
        coordinatorEntry = nil
    }

    public func stop() {
        stateMachine.stop()
        isPlaying = false
        TGSPlaybackCoordinator.shared.unregister(self)
        coordinatorEntry = nil
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

    /// `workQueue` only. Renders the current frame immediately and hops to main to apply it,
    /// then (unless `firstFrame == true`) registers this view with the global playback
    /// coordinator so subsequent frames are driven by the shared CADisplayLink.
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

        // Render the very first frame eagerly so the cell shows content without waiting
        // for the next vsync. The coordinator picks it up from there.
        let firstCommit = makeCommitOnWorkQueue(skipFrames: 0, generation: generation)
        let frameRate = frameSource.frameRate

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.currentGeneration() == generation else { return }

            if let firstCommit {
                self.applyCoordinatedCommit(firstCommit)
            }

            if firstFrame { return }

            // Register with the coordinator. From this point onwards every new frame is
            // driven by the global CADisplayLink and committed in a batched CATransaction.
            self.coordinatorEntry = TGSPlaybackCoordinator.shared.register(
                self,
                frameRate: frameRate
            )
        }
    }

    /// Called by `TGSPlaybackCoordinator` on the main thread when this view's next frame is
    /// due. Bounces the work onto the per-view serial workQueue (so it can run in parallel
    /// with other views on the shared `renderPool`) and lets the result land in the
    /// coordinator entry's pending slot for the next vsync to commit.
    internal func dispatchCoordinatedTick(
        skipFrames: Int,
        entry: TGSPlaybackCoordinator.ViewEntry
    ) {
        let generation = currentGeneration()
        workQueue.async { [weak self, weak entry] in
            guard let self else { return }
            guard let entry else { return }
            guard self.currentGeneration() == generation else {
                // Reset / setup happened while this tick was scheduled. Clear the in-flight
                // flag on main so the coordinator doesn't stall waiting on us forever.
                DispatchQueue.main.async { entry.inFlight = false }
                return
            }
            guard let commit = self.makeCommitOnWorkQueue(
                skipFrames: skipFrames,
                generation: generation
            ) else {
                DispatchQueue.main.async { entry.inFlight = false }
                return
            }
            entry.submitPendingCommit(commit)
        }
    }

    /// Main thread only. Called by `TGSPlaybackCoordinator` from inside its per-vsync
    /// `CATransaction.setDisableActions(true)` envelope, so the `layer.contents` write
    /// here doesn't need its own transaction in the coordinator path. The one place that
    /// calls this outside a coordinator transaction is the eager first-frame path in
    /// `startPlaybackOnWorkQueue`; we wrap that one in its own transaction below.
    internal func applyCoordinatedCommit(_ commit: TGSPlaybackCoordinator.ViewEntry.PendingCommit) {
        guard self.currentGeneration() == commit.generation else { return }

        if let cgImage = commit.cgImage {
            // Wrap defensively: nested CATransactions are cheap, and this lets the same
            // code path serve both the coordinator-driven case and the eager first-frame
            // case without callers needing to know which is which.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.layer.contents = cgImage
            CATransaction.commit()
        }
        self.currentFrameIndex = commit.frameIndex
        self.currentFrameCount = commit.totalFrames
        self.currentFrameRate = commit.frameRate
        self.frameUpdated(commit.frameIndex, commit.totalFrames)

        if !self.hasSubmittedFirstFrame {
            self.hasSubmittedFirstFrame = true
            self.started()
            self.delegate?.tgsPlayerViewDidLoadFirstFrame(self)
            self.updateSilhouetteVisibility(animated: true)
        }

        if commit.isLast {
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

    /// `workQueue` only. Advance `skipFrames` frames without rendering, then render the next
    /// frame and return a `PendingCommit` ready for the main thread to apply.
    private func makeCommitOnWorkQueue(
        skipFrames: Int,
        generation: UInt64
    ) -> TGSPlaybackCoordinator.ViewEntry.PendingCommit? {
        guard let frameQueue else { return nil }
        if skipFrames > 0, let frameSource {
            // Drain skipped frames cheaply (no rlottie render, no CGImage creation).
            for _ in 0..<skipFrames {
                _ = frameSource.takeFrame(draw: false)
            }
        }
        guard let frame = frameQueue.take(draw: true) else { return nil }
        // With queue length 1 there is no next-frame prefetch; keep the call for when length grows.
        frameQueue.generateFramesIfNeeded()

        return TGSPlaybackCoordinator.ViewEntry.PendingCommit(
            cgImage: Self.makeCGImage(from: frame),
            frameIndex: frame.index,
            totalFrames: frame.totalFrames,
            isLast: frame.isLastFrame,
            frameRate: frameSource?.frameRate ?? 0,
            generation: generation
        )
    }

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

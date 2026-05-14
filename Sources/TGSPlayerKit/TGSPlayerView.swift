#if canImport(UIKit)
import UIKit

public protocol TGSPlayerViewDelegate: AnyObject {
    func tgsPlayerViewDidLoadFirstFrame(_ view: TGSPlayerView)
    func tgsPlayerViewDidStartPlaying(_ view: TGSPlayerView)
    func tgsPlayerViewDidPause(_ view: TGSPlayerView)
    func tgsPlayerView(_ view: TGSPlayerView, didFailWith error: TGSPlayerError)
}

public final class TGSPlayerView: UIView {
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

    private var stateMachine = TGSPlayerStateMachine()
    private var visibilityGate = TGSAnimatedStickerVisibilityGate()
    private var sourceCancellable: TGSCancellable?
    private var frameSource: TGSAnimatedStickerFrameSource?
    private var frameQueue: TGSAnimatedStickerFrameQueue?
    private var playbackTimer: Timer?
    private var playbackMode: TGSAnimatedStickerPlaybackMode = .loop
    private var mode: TGSAnimatedStickerMode = .direct(cachePathPrefix: nil)
    private let imageView = UIImageView()

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
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        visibilityGate.isDisplaying = window != nil
        updateIsPlaying()
    }

    public func setSource(_ source: TGSSource) {
        stateMachine.setSource(source)
    }

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

        switch mode {
        case .cached:
            sourceCancellable = source.cachedDataPath(width: width, height: height) { _ in
            }
        case .direct:
            sourceCancellable = source.directDataPath(attemptSynchronously: false) { [weak self] path in
                guard let self, let path else {
                    return
                }
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedRead]) else {
                    return
                }
                self.frameSource = TGSAnimatedStickerDirectFrameSource(
                    data: data,
                    width: width,
                    height: height,
                    cacheKey: path,
                    loader: self.animationLoader
                )
                self.frameQueue = self.frameSource.map {
                    TGSAnimatedStickerFrameQueue(length: 1, source: $0)
                }
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
        if frameSource == nil {
            stateMachine.play()
            switch stateMachine.state {
            case .playing:
                delegate?.tgsPlayerViewDidStartPlaying(self)
            case let .failed(error):
                delegate?.tgsPlayerView(self, didFailWith: error)
            default:
                break
            }
        } else {
            delegate?.tgsPlayerViewDidStartPlaying(self)
        }

        if let fromIndex {
            frameSource?.skipToFrameIndex(fromIndex)
        }
        guard let frameSource, let frameQueue else {
            return
        }
        playbackTimer?.invalidate()

        let renderFrame = { [weak self] in
            guard let self else {
                return
            }
            guard let frame = frameQueue.take(draw: true) else {
                return
            }
            self.submitFrame(frame)
            frameQueue.generateFramesIfNeeded()
            if frame.isLastFrame {
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

        renderFrame()

        if !firstFrame {
            let timer = Timer(timeInterval: 1.0 / Double(max(1, frameSource.frameRate)), repeats: true) { _ in
                renderFrame()
            }
            RunLoop.main.add(timer, forMode: .common)
            playbackTimer = timer
        }
    }

    public func pause() {
        stateMachine.pause()
        playbackTimer?.invalidate()
        playbackTimer = nil
        delegate?.tgsPlayerViewDidPause(self)
    }

    public func stop() {
        stateMachine.stop()
        playbackTimer?.invalidate()
        playbackTimer = nil
        isPlaying = false
    }

    public func prepareForReuse() {
        reset()
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

    public func seekTo(_ position: TGSAnimatedStickerPlaybackPosition) {
        guard let frameSource else {
            return
        }

        switch position {
        case .start:
            frameSource.skipToFrameIndex(0)
        case .end:
            frameSource.skipToEnd()
        case let .frameIndex(index):
            frameSource.skipToFrameIndex(index)
        case let .timestamp(timestamp):
            let duration = frameSource.frameRate > 0 ? Double(frameSource.frameCount) / Double(frameSource.frameRate) : 0
            guard duration > 0 else {
                return
            }
            var stickerTimestamp = timestamp
            while stickerTimestamp > duration {
                stickerTimestamp -= duration
            }
            frameSource.skipToFrameIndex(Int(stickerTimestamp / duration * Double(frameSource.frameCount)))
        }

        frameQueue = TGSAnimatedStickerFrameQueue(length: 1, source: frameSource)
        play(firstFrame: true, fromIndex: nil)
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

    public func updateLayout(size: CGSize) {
        frame = CGRect(origin: frame.origin, size: size)
        setNeedsLayout()
    }

    public func setOverlayColor(_ color: UIColor?, replace: Bool, animated: Bool) {
        imageView.tintColor = color
        imageView.image = imageView.image?.withRenderingMode(color == nil ? .alwaysOriginal : .alwaysTemplate)
    }

    public func submitFrame(_ image: CGImage) {
        layer.contents = image
    }

    public func submitFrame(_ frame: TGSAnimatedStickerFrame) {
        guard frame.type == .argb else {
            return
        }
        guard let image = makeImage(from: frame) else {
            return
        }
        imageView.image = image
        currentFrameIndex = frame.index
        currentFrameCount = frame.totalFrames
        currentFrameRate = frameSource?.frameRate ?? 0
        frameUpdated(frame.index, frame.totalFrames)
        started()
        delegate?.tgsPlayerViewDidLoadFirstFrame(self)
    }

    public func reset() {
        sourceCancellable?.cancel()
        sourceCancellable = nil
        playbackTimer?.invalidate()
        playbackTimer = nil
        frameSource = nil
        frameQueue = nil
        imageView.image = nil
        layer.contents = nil
        currentFrameIndex = 0
        currentFrameCount = 0
        currentFrameRate = 0
        isPlaying = false
        stateMachine.prepareForReuse()
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

    private func makeImage(from frame: TGSAnimatedStickerFrame) -> UIImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedFirst.rawValue |
            CGBitmapInfo.byteOrder32Little.rawValue
        )
        guard let provider = CGDataProvider(data: frame.data as CFData) else {
            return nil
        }
        guard let image = CGImage(
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
        ) else {
            return nil
        }
        return UIImage(cgImage: image)
    }
}
#endif

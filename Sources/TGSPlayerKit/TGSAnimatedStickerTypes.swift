import Foundation

public enum TGSAnimatedStickerMode: Equatable {
    case cached
    case direct(cachePathPrefix: String?)
}

public enum TGSAnimatedStickerPlaybackPosition: Equatable {
    case start
    case end
    case timestamp(Double)
    case frameIndex(Int)
}

public enum TGSAnimatedStickerPlaybackMode: Equatable {
    case once
    case count(Int)
    case loop
    case still(TGSAnimatedStickerPlaybackPosition)
}

public enum TGSAnimationFrameType: Equatable {
    case argb
    case yuva
    case dct
}

public final class TGSAnimatedStickerFrame: Equatable {
    public let data: Data
    public let type: TGSAnimationFrameType
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let index: Int
    public let isLastFrame: Bool
    public let totalFrames: Int
    public let multiplyAlpha: Bool

    public init(
        data: Data,
        type: TGSAnimationFrameType,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        index: Int,
        isLastFrame: Bool,
        totalFrames: Int,
        multiplyAlpha: Bool = false
    ) {
        self.data = data
        self.type = type
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.index = index
        self.isLastFrame = isLastFrame
        self.totalFrames = totalFrames
        self.multiplyAlpha = multiplyAlpha
    }

    public static func == (lhs: TGSAnimatedStickerFrame, rhs: TGSAnimatedStickerFrame) -> Bool {
        lhs.data == rhs.data
            && lhs.type == rhs.type
            && lhs.width == rhs.width
            && lhs.height == rhs.height
            && lhs.bytesPerRow == rhs.bytesPerRow
            && lhs.index == rhs.index
            && lhs.isLastFrame == rhs.isLastFrame
            && lhs.totalFrames == rhs.totalFrames
            && lhs.multiplyAlpha == rhs.multiplyAlpha
    }
}

public struct TGSAnimatedStickerStatus: Equatable {
    public let playing: Bool
    public let duration: Double
    public let timestamp: Double

    public init(playing: Bool, duration: Double, timestamp: Double) {
        self.playing = playing
        self.duration = duration
        self.timestamp = timestamp
    }
}

public protocol TGSAnimatedStickerFrameSource: AnyObject {
    var frameRate: Int { get }
    var frameCount: Int { get }
    var frameIndex: Int { get }

    func takeFrame(draw: Bool) -> TGSAnimatedStickerFrame?
    func skipToEnd()
    func skipToFrameIndex(_ index: Int)
}

public final class TGSAnimatedStickerFrameQueue {
    private let length: Int
    private let source: TGSAnimatedStickerFrameSource
    private var frames: [TGSAnimatedStickerFrame] = []

    public init(length: Int, source: TGSAnimatedStickerFrameSource) {
        self.length = max(1, length)
        self.source = source
    }

    public func take(draw: Bool) -> TGSAnimatedStickerFrame? {
        if frames.isEmpty, let frame = source.takeFrame(draw: draw) {
            frames.append(frame)
        }
        guard !frames.isEmpty else {
            return nil
        }
        return frames.removeFirst()
    }

    public func generateFramesIfNeeded() {
        while frames.count < length {
            guard let frame = source.takeFrame(draw: true) else {
                return
            }
            frames.append(frame)
        }
    }
}

public struct TGSAnimatedStickerVisibilityGate: Equatable {
    public var autoplay: Bool
    public var visibility: Bool
    public var isDisplaying: Bool
    public var overrideVisibility: Bool

    public init(
        autoplay: Bool = false,
        visibility: Bool = false,
        isDisplaying: Bool = false,
        overrideVisibility: Bool = false
    ) {
        self.autoplay = autoplay
        self.visibility = visibility
        self.isDisplaying = isDisplaying
        self.overrideVisibility = overrideVisibility
    }

    public var shouldPlay: Bool {
        if autoplay {
            return true
        }
        return visibility && (isDisplaying || overrideVisibility)
    }
}

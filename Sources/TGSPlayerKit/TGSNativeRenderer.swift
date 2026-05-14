import CoreGraphics
import Foundation

public enum TGSLottieFitzModifier: Equatable {
    case none
    case type12
    case type3
    case type4
    case type5
    case type6
}

public struct TGSAnimationMetadata: Equatable {
    public let frameRate: Double
    public let totalFrameCount: Int
    public let duration: TimeInterval

    public init(frameRate: Double, totalFrameCount: Int, duration: TimeInterval) {
        self.frameRate = frameRate
        self.totalFrameCount = totalFrameCount
        self.duration = duration
    }
}

public protocol TGSLottieAnimationInstance: AnyObject {
    var frameCount: Int { get }
    var frameRate: Int { get }
    var dimensions: CGSize { get }

    func renderFrame(index: Int, width: Int, height: Int, bytesPerRow: Int) throws -> Data
}

public protocol TGSLottieAnimationLoading {
    func loadAnimation(
        data: Data,
        fitzModifier: TGSLottieFitzModifier,
        colorReplacements: [UInt32: UInt32]?,
        cacheKey: String
    ) throws -> TGSLottieAnimationInstance
}

public enum TGSPixelFormat: Equatable {
    case rgba8888
    case bgra8888
}

public struct TGSRenderedFrame: Equatable {
    public let data: Data
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let pixelFormat: TGSPixelFormat

    public init(
        data: Data,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        pixelFormat: TGSPixelFormat
    ) {
        self.data = data
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.pixelFormat = pixelFormat
    }
}

public protocol TGSNativeRendering {
    func loadAnimation(jsonData: Data, cacheKey: String) throws -> TGSAnimationMetadata
    func renderFrame(cacheKey: String, frameIndex: Int, pixelSize: CGSize) throws -> TGSRenderedFrame
}

public final class TGSUnavailableNativeRenderer: TGSNativeRendering {
    public init() {}

    public func loadAnimation(jsonData: Data, cacheKey: String) throws -> TGSAnimationMetadata {
        throw TGSPlayerError.animationLoadFailed
    }

    public func renderFrame(cacheKey: String, frameIndex: Int, pixelSize: CGSize) throws -> TGSRenderedFrame {
        throw TGSPlayerError.renderFailed
    }
}

public final class TGSUnavailableLottieAnimationLoader: TGSLottieAnimationLoading {
    public init() {}

    public func loadAnimation(
        data: Data,
        fitzModifier: TGSLottieFitzModifier,
        colorReplacements: [UInt32: UInt32]?,
        cacheKey: String
    ) throws -> TGSLottieAnimationInstance {
        throw TGSPlayerError.animationLoadFailed
    }
}

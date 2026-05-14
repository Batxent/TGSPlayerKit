import CoreGraphics
import Foundation

public final class TGSAnimatedStickerDirectFrameSource: TGSAnimatedStickerFrameSource {
    private let animation: TGSLottieAnimationInstance
    private let width: Int
    private let height: Int
    private let bytesPerRow: Int
    private var currentFrame: Int

    public let frameCount: Int
    public let frameRate: Int

    public var frameIndex: Int {
        currentFrame % frameCount
    }

    public init?(
        data: Data,
        width: Int,
        height: Int,
        cacheKey: String,
        loader: TGSLottieAnimationLoading
    ) {
        guard width > 0, height > 0 else {
            return nil
        }
        let decodedData = (try? TGSDecoder().decode(data)) ?? data
        guard let animation = try? loader.loadAnimation(
            data: decodedData,
            fitzModifier: .none,
            colorReplacements: nil,
            cacheKey: cacheKey
        ) else {
            return nil
        }
        self.animation = animation
        self.width = width
        self.height = height
        self.bytesPerRow = width * 4
        self.currentFrame = 0
        self.frameCount = max(1, animation.frameCount)
        self.frameRate = max(1, animation.frameRate)
    }

    public func takeFrame(draw: Bool) -> TGSAnimatedStickerFrame? {
        let frameIndex = currentFrame % frameCount
        currentFrame += 1
        guard draw else {
            return nil
        }

        guard let data = try? animation.renderFrame(
            index: frameIndex,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow
        ) else {
            return nil
        }

        return TGSAnimatedStickerFrame(
            data: data,
            type: .argb,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            index: frameIndex,
            isLastFrame: frameIndex == frameCount - 1,
            totalFrames: frameCount
        )
    }

    public func skipToEnd() {
        currentFrame = frameCount - 1
    }

    public func skipToFrameIndex(_ index: Int) {
        currentFrame = max(0, index)
    }
}

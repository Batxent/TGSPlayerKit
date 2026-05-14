import Foundation
import TGSPlayerKit
import TGSPlayerKitRLottieNative

public final class TGSRLottieAnimationLoader: TGSLottieAnimationLoading {
    public init() {}

    public func loadAnimation(
        data: Data,
        fitzModifier: TGSPlayerKit.TGSLottieFitzModifier,
        colorReplacements: [UInt32: UInt32]?,
        cacheKey: String
    ) throws -> TGSPlayerKit.TGSLottieAnimationInstance {
        guard let instance = TGSLottieInstance(
            data: data,
            fitzModifier: nativeFitzModifier(fitzModifier),
            colorReplacements: nativeColorReplacements(colorReplacements),
            cacheKey: cacheKey
        ) else {
            throw TGSPlayerError.animationLoadFailed
        }
        return TGSRLottieAnimationInstance(instance: instance)
    }
}

private final class TGSRLottieAnimationInstance: TGSPlayerKit.TGSLottieAnimationInstance {
    private let instance: TGSLottieInstance

    var frameCount: Int {
        Int(instance.frameCount)
    }

    var frameRate: Int {
        Int(instance.frameRate)
    }

    var dimensions: CGSize {
        instance.dimensions
    }

    init(instance: TGSLottieInstance) {
        self.instance = instance
    }

    func renderFrame(index: Int, width: Int, height: Int, bytesPerRow: Int) throws -> Data {
        guard width > 0, height > 0, bytesPerRow >= width * 4 else {
            throw TGSPlayerError.renderFailed
        }
        guard index >= 0,
              index <= Int(Int32.max),
              width <= Int(Int32.max),
              height <= Int(Int32.max),
              bytesPerRow <= Int(Int32.max) else {
            throw TGSPlayerError.renderFailed
        }

        let byteCount = height * bytesPerRow
        var data = Data(count: byteCount)
        data.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return
            }
            instance.renderFrame(
                with: Int32(index),
                into: baseAddress,
                width: Int32(width),
                height: Int32(height),
                bytesPerRow: Int32(bytesPerRow)
            )
        }
        return data
    }
}

private func nativeFitzModifier(_ modifier: TGSPlayerKit.TGSLottieFitzModifier) -> TGSPlayerKitRLottieNative.TGSLottieFitzModifier {
    switch modifier {
    case .none:
        return .none
    case .type12:
        return .type12
    case .type3:
        return .type3
    case .type4:
        return .type4
    case .type5:
        return .type5
    case .type6:
        return .type6
    }
}

private func nativeColorReplacements(_ replacements: [UInt32: UInt32]?) -> [NSNumber: NSNumber]? {
    guard let replacements else {
        return nil
    }

    var native: [NSNumber: NSNumber] = [:]
    native.reserveCapacity(replacements.count)
    for (source, replacement) in replacements {
        native[NSNumber(value: source)] = NSNumber(value: replacement)
    }
    return native
}

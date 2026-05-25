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
        // Note: rlottie keeps an in-process model cache keyed by `cacheKey` (see
        // `rlottie::configureModelCacheSize`). When 60 cells of the same sticker load with
        // the same cacheKey, the heavy JSON → animation-tree parse runs once and subsequent
        // loads return the already-parsed model. We deliberately do NOT share the resulting
        // `TGSLottieInstance` objects across views: each `rlottie::Animation` carries
        // mutable per-instance renderer state (`mRenderer`, frame caches), so concurrent
        // `renderSync` calls on the same instance from different view workQueues would race.
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

        // `Data(count:)` zero-fills the buffer before rlottie writes pixels — wasted work,
        // because `lottie_render` writes every pixel of the destination surface (transparent
        // areas get 0x00000000). At ~60 cells × 60fps × ~36 KB this is double-digit MB/s of
        // pointless memory traffic. Allocate raw memory, let rlottie populate it, then wrap
        // it in a no-copy `Data` whose deallocator hands the buffer back to the system.
        let byteCount = height * bytesPerRow
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
        instance.renderFrame(
            with: Int32(index),
            into: pointer.assumingMemoryBound(to: UInt8.self),
            width: Int32(width),
            height: Int32(height),
            bytesPerRow: Int32(bytesPerRow)
        )
        return Data(
            bytesNoCopy: pointer,
            count: byteCount,
            deallocator: .custom { pointer, _ in
                pointer.deallocate()
            }
        )
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

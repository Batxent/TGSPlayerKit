import CoreGraphics
import Foundation
import XCTest
@testable import TGSPlayerKit

final class TGSAnimatedStickerDirectFrameSourceTests: XCTestCase {
    func testDirectFrameSourceDecodesGzipTGSBeforeLoadingAnimation() {
        let loader = RecordingLottieLoader()
        let gzippedEmptyJSONObject = Data([
            31, 139, 8, 0, 109, 170, 4, 106, 0, 3, 171, 174, 5, 0, 67, 191,
            166, 163, 2, 0, 0, 0
        ])

        _ = TGSAnimatedStickerDirectFrameSource(
            data: gzippedEmptyJSONObject,
            width: 32,
            height: 32,
            cacheKey: "fixture.tgs",
            loader: loader
        )

        XCTAssertEqual(loader.loadedData, #"{}"#.data(using: .utf8))
    }
}

private final class RecordingLottieLoader: TGSLottieAnimationLoading {
    private(set) var loadedData: Data?

    func loadAnimation(
        data: Data,
        fitzModifier: TGSLottieFitzModifier,
        colorReplacements: [UInt32: UInt32]?,
        cacheKey: String
    ) throws -> TGSLottieAnimationInstance {
        loadedData = data
        return FakeLottieAnimation()
    }
}

private final class FakeLottieAnimation: TGSLottieAnimationInstance {
    let frameCount: Int = 1
    let frameRate: Int = 60
    let dimensions = CGSize(width: 32, height: 32)

    func renderFrame(index: Int, width: Int, height: Int, bytesPerRow: Int) throws -> Data {
        Data(count: height * bytesPerRow)
    }
}

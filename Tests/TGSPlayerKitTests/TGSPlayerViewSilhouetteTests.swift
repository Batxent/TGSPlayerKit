#if canImport(UIKit)
import UIKit
import XCTest
@testable import TGSPlayerKit

final class TGSPlayerViewSilhouetteTests: XCTestCase {
    func testSilhouetteHiddenByDefault() {
        let view = TGSPlayerView()
        view.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        view.layoutIfNeeded()
        XCTAssertNil(view.silhouette)
        XCTAssertTrue(view.silhouetteView.isHidden)
        XCTAssertFalse(view.silhouetteView.isAnimating)
    }

    func testAssigningSilhouetteShowsAndAnimates() {
        let view = TGSPlayerView()
        view.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        view.layoutIfNeeded()

        view.silhouette = .image(makeImage())
        XCTAssertNotNil(view.silhouette)
        XCTAssertFalse(view.silhouetteView.isHidden)
        XCTAssertTrue(view.silhouetteView.isAnimating)
    }

    func testFirstFrameHidesSilhouette() {
        let view = TGSPlayerView()
        view.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        view.silhouetteFadeOutDuration = 0
        view.layoutIfNeeded()

        view.silhouette = .image(makeImage())
        XCTAssertFalse(view.silhouetteView.isHidden)

        view.submitFrame(makeFrame())

        XCTAssertTrue(view.silhouetteView.isHidden)
        XCTAssertFalse(view.silhouetteView.isAnimating)
        XCTAssertTrue(view.hasRenderedFirstFrame)
    }

    func testResetRestoresSilhouette() {
        let view = TGSPlayerView()
        view.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        view.silhouetteFadeOutDuration = 0
        view.layoutIfNeeded()

        view.silhouette = .image(makeImage())
        view.submitFrame(makeFrame())
        XCTAssertTrue(view.silhouetteView.isHidden)

        view.reset()
        XCTAssertFalse(view.hasRenderedFirstFrame)
        XCTAssertFalse(view.silhouetteView.isHidden)
        XCTAssertTrue(view.silhouetteView.isAnimating)
    }

    func testDisablingShowsSilhouetteUntilFirstFrameHidesImmediately() {
        let view = TGSPlayerView()
        view.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        view.silhouetteFadeOutDuration = 0
        view.layoutIfNeeded()

        view.silhouette = .image(makeImage())
        XCTAssertFalse(view.silhouetteView.isHidden)

        view.showsSilhouetteUntilFirstFrame = false

        XCTAssertTrue(view.silhouetteView.isHidden)
        XCTAssertFalse(view.silhouetteView.isAnimating)
    }

    private func makeImage() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        return renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    private func makeFrame() -> TGSAnimatedStickerFrame {
        let bytesPerRow = 4
        let data = Data(count: bytesPerRow)
        return TGSAnimatedStickerFrame(
            data: data,
            type: .argb,
            width: 1,
            height: 1,
            bytesPerRow: bytesPerRow,
            index: 0,
            isLastFrame: false,
            totalFrames: 1
        )
    }
}
#endif

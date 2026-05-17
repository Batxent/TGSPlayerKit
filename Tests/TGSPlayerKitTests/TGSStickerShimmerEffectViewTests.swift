#if canImport(UIKit)
import UIKit
import XCTest
@testable import TGSPlayerKit

final class TGSStickerShimmerEffectViewTests: XCTestCase {
    func testInitiallyNotAnimating() {
        let view = TGSStickerShimmerEffectView()
        XCTAssertFalse(view.isAnimating)
    }

    func testStartAnimatingFlipsState() {
        let view = TGSStickerShimmerEffectView()
        view.frame = CGRect(x: 0, y: 0, width: 80, height: 80)
        view.layoutIfNeeded()
        view.startAnimating()
        XCTAssertTrue(view.isAnimating)
        view.stopAnimating()
        XCTAssertFalse(view.isAnimating)
    }

    func testSetSilhouetteAcceptsImage() {
        let view = TGSStickerShimmerEffectView()
        view.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16))
        let image = renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        view.setSilhouette(.image(image))
        XCTAssertNotNil(view.silhouette)
        view.layoutIfNeeded()
    }

    func testSetSilhouetteAcceptsSVGData() throws {
        let view = TGSStickerShimmerEffectView()
        view.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 100 100\"><path d=\"M 10 10 L 90 10 L 50 90 Z\"/></svg>"
        view.setSilhouette(.svgData(svg.data(using: .utf8)!))
        XCTAssertNotNil(view.silhouette)
        view.layoutIfNeeded()
    }

    func testStyleUpdateAppliesNewColor() {
        let view = TGSStickerShimmerEffectView()
        view.style = TGSStickerShimmerStyle(
            foregroundColor: .red,
            shimmeringColor: .green,
            duration: 1.0
        )
        XCTAssertEqual(view.style.foregroundColor, .red)
        XCTAssertEqual(view.style.shimmeringColor, .green)
    }
}
#endif

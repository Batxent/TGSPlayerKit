#if canImport(UIKit)
import QuartzCore
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

    func testShimmerAnimationUsesLinearClearEndpointsForSeamlessRepeat() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 80, height: 80))
        let view = TGSStickerShimmerEffectView()
        view.frame = window.bounds
        window.addSubview(view)
        window.isHidden = false
        addTeardownBlock { window.isHidden = true }

        view.layoutIfNeeded()
        view.startAnimating()

        let shimmerLayer = try XCTUnwrap(findGradientLayer(in: view.layer))
        let animation = try XCTUnwrap(
            shimmerLayer.animation(forKey: "tgs.shimmer.translation") as? CABasicAnimation
        )

        XCTAssertEqual(numericValue(animation.fromValue), -80)
        XCTAssertEqual(numericValue(animation.toValue), 80)
        XCTAssertTrue(isLinear(animation.timingFunction))
        let expectedLocations: [CGFloat] = [1.0 / 3.0, 0.5, 2.0 / 3.0]
        XCTAssertEqual(
            shimmerLayer.locations?.compactMap(numericValue(_:)),
            expectedLocations
        )
    }

    private func findGradientLayer(in layer: CALayer) -> CAGradientLayer? {
        if let gradientLayer = layer as? CAGradientLayer {
            return gradientLayer
        }
        return layer.sublayers?.compactMap(findGradientLayer(in:)).first
    }

    private func numericValue(_ value: Any?) -> CGFloat? {
        switch value {
        case let number as NSNumber:
            return CGFloat(truncating: number)
        case let value as CGFloat:
            return value
        case let value as Double:
            return CGFloat(value)
        case let value as Float:
            return CGFloat(value)
        default:
            return nil
        }
    }

    private func isLinear(_ timingFunction: CAMediaTimingFunction?) -> Bool {
        guard let timingFunction else { return false }

        var firstControlPoint = [Float](repeating: 0, count: 2)
        var secondControlPoint = [Float](repeating: 0, count: 2)
        timingFunction.getControlPoint(at: 1, values: &firstControlPoint)
        timingFunction.getControlPoint(at: 2, values: &secondControlPoint)

        return firstControlPoint == [0, 0] && secondControlPoint == [1, 1]
    }
}
#endif

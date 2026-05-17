#if canImport(UIKit)
import QuartzCore
import UIKit

public final class TGSStickerShimmerEffectView: UIView {
    private static let shimmerAnimationKey = "tgs.shimmer.translation"

    public private(set) var silhouette: TGSStickerSilhouette? {
        didSet { rebuildSilhouette() }
    }

    public var style: TGSStickerShimmerStyle {
        didSet {
            backgroundLayer.fillColor = style.foregroundColor.cgColor
            updateGradientColors()
            if isAnimating {
                restartShimmer()
            }
        }
    }

    public private(set) var isAnimating: Bool = false

    private let containerLayer = CALayer()
    private let backgroundLayer = CAShapeLayer()
    private let shimmerLayer = CAGradientLayer()
    private let maskLayer = CAShapeLayer()
    private var silhouettePath: CGPath?
    private var silhouetteViewBox: CGRect?
    private var silhouetteImage: UIImage?

    public init(silhouette: TGSStickerSilhouette? = nil) {
        self.silhouette = silhouette
        self.style = silhouette?.style ?? TGSStickerShimmerStyle()
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear

        layer.addSublayer(containerLayer)
        containerLayer.addSublayer(backgroundLayer)
        containerLayer.addSublayer(shimmerLayer)
        containerLayer.mask = maskLayer

        backgroundLayer.fillRule = .evenOdd
        maskLayer.fillRule = .evenOdd

        shimmerLayer.startPoint = CGPoint(x: 0, y: 0.5)
        shimmerLayer.endPoint = CGPoint(x: 1, y: 0.5)
        shimmerLayer.locations = [0.0, 0.5, 1.0]

        backgroundLayer.fillColor = style.foregroundColor.cgColor
        updateGradientColors()
        rebuildSilhouette()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        containerLayer.frame = bounds
        updateLayoutAndPaths()
        if isAnimating {
            restartShimmer()
        }
        CATransaction.commit()
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, isAnimating {
            restartShimmer()
        }
    }

    public func setSilhouette(_ silhouette: TGSStickerSilhouette?) {
        self.silhouette = silhouette
        if let silhouette {
            self.style = silhouette.style
        }
    }

    public func startAnimating() {
        guard !isAnimating else { return }
        isAnimating = true
        restartShimmer()
    }

    public func stopAnimating() {
        guard isAnimating else { return }
        isAnimating = false
        shimmerLayer.removeAnimation(forKey: Self.shimmerAnimationKey)
    }

    private func updateGradientColors() {
        let clear = style.shimmeringColor.withAlphaComponent(0).cgColor
        shimmerLayer.colors = [clear, style.shimmeringColor.cgColor, clear]
    }

    private func rebuildSilhouette() {
        silhouettePath = nil
        silhouetteViewBox = nil
        silhouetteImage = nil

        guard let silhouette else {
            updateLayoutAndPaths()
            return
        }

        switch silhouette.shape {
        case let .path(path, viewBox):
            silhouettePath = path
            silhouetteViewBox = viewBox
        case let .svgData(data):
            if let parsed = try? TGSSVGPathParser.parse(data) {
                silhouettePath = parsed.path
                silhouetteViewBox = parsed.viewBox
            }
        case let .image(image):
            silhouetteImage = image
        }

        updateLayoutAndPaths()
    }

    private func updateLayoutAndPaths() {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else {
            return
        }

        backgroundLayer.frame = bounds
        maskLayer.frame = bounds

        if let path = silhouettePath, let viewBox = silhouetteViewBox, viewBox.width > 0, viewBox.height > 0 {
            let scale = min(size.width / viewBox.width, size.height / viewBox.height)
            let scaledWidth = viewBox.width * scale
            let scaledHeight = viewBox.height * scale
            let translateX = (size.width - scaledWidth) / 2 - viewBox.minX * scale
            let translateY = (size.height - scaledHeight) / 2 - viewBox.minY * scale
            var transform = CGAffineTransform(translationX: translateX, y: translateY)
                .scaledBy(x: scale, y: scale)
            let transformed = path.copy(using: &transform) ?? path

            backgroundLayer.path = transformed
            maskLayer.path = transformed
            maskLayer.contents = nil
        } else if let image = silhouetteImage, let cgImage = image.cgImage {
            backgroundLayer.path = CGPath(rect: bounds, transform: nil)
            maskLayer.path = nil
            maskLayer.contents = cgImage
            maskLayer.contentsGravity = .resizeAspect
        } else {
            backgroundLayer.path = nil
            maskLayer.path = nil
            maskLayer.contents = nil
        }

        shimmerLayer.frame = CGRect(x: -size.width, y: 0, width: size.width * 3, height: size.height)
    }

    private func restartShimmer() {
        guard window != nil, bounds.width > 0 else {
            return
        }
        let width = bounds.width
        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.fromValue = -width + style.horizontalOffset
        animation.toValue = width + style.horizontalOffset
        animation.duration = max(0.1, style.duration)
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        shimmerLayer.removeAnimation(forKey: Self.shimmerAnimationKey)
        shimmerLayer.add(animation, forKey: Self.shimmerAnimationKey)
    }
}
#endif

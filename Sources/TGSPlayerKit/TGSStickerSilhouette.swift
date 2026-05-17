#if canImport(UIKit)
import CoreGraphics
import Foundation
import UIKit

public struct TGSStickerShimmerStyle: Equatable {
    public var foregroundColor: UIColor
    public var shimmeringColor: UIColor
    public var duration: CFTimeInterval
    public var horizontalOffset: CGFloat

    public init(
        foregroundColor: UIColor = UIColor(white: 0.0, alpha: 0.08),
        shimmeringColor: UIColor = UIColor(white: 1.0, alpha: 0.55),
        duration: CFTimeInterval = 1.3,
        horizontalOffset: CGFloat = 0
    ) {
        self.foregroundColor = foregroundColor
        self.shimmeringColor = shimmeringColor
        self.duration = duration
        self.horizontalOffset = horizontalOffset
    }
}

public enum TGSStickerSilhouetteShape {
    case svgData(Data)
    case path(CGPath, viewBox: CGRect)
    case image(UIImage)
}

public struct TGSStickerSilhouette {
    public var shape: TGSStickerSilhouetteShape
    public var style: TGSStickerShimmerStyle

    public init(
        shape: TGSStickerSilhouetteShape,
        style: TGSStickerShimmerStyle = TGSStickerShimmerStyle()
    ) {
        self.shape = shape
        self.style = style
    }

    public static func svgData(
        _ data: Data,
        style: TGSStickerShimmerStyle = TGSStickerShimmerStyle()
    ) -> TGSStickerSilhouette {
        TGSStickerSilhouette(shape: .svgData(data), style: style)
    }

    public static func image(
        _ image: UIImage,
        style: TGSStickerShimmerStyle = TGSStickerShimmerStyle()
    ) -> TGSStickerSilhouette {
        TGSStickerSilhouette(shape: .image(image), style: style)
    }

    public static func path(
        _ path: CGPath,
        viewBox: CGRect,
        style: TGSStickerShimmerStyle = TGSStickerShimmerStyle()
    ) -> TGSStickerSilhouette {
        TGSStickerSilhouette(shape: .path(path, viewBox: viewBox), style: style)
    }
}
#endif

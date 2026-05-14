import Foundation

public enum TGSPlayerError: Error, Equatable {
    case invalidSource
    case sourceTooLarge
    case decodedJSONTooLarge
    case gzipDecodeFailed
    case invalidLottieJSON
    case unsupportedTGSFeature
    case animationLoadFailed
    case renderFailed
    case cancelled
}

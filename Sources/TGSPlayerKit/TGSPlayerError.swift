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
    /// Cached frame file failed structural validation (missing magic, unsupported
    /// version, truncated header / index table, inconsistent frame metadata).
    case cachedSourceInvalid
    /// LZFSE decompression of a cached frame failed or yielded a wrong-sized payload.
    case cachedFrameDecodeFailed
    /// The frame source passed to the cache writer ran out of frames before the
    /// expected `frameCount` was reached.
    case cachedSourceProducedNoFrames
    /// Writing the cache file to disk failed (typically out-of-space or permissions).
    case cachedWriteFailed
}

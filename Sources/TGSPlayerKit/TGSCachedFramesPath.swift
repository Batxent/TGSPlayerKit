import CryptoKit
import Foundation

/// Stable on-disk layout for `.tgsc` cached frame files.
///
/// The cache key + render dimensions uniquely identify a cached frame file (since
/// rasterized RGBA is baked at a specific pixel size). The filename is the SHA256
/// of `"{cacheKey}|{width}x{height}"` rendered as hex, so:
///
///   - The same `(cacheKey, width, height)` always lands on the same path across
///     processes, devices, and library versions, letting different views in a list
///     (and different app launches) share the same generated cache file.
///   - The path is filesystem-safe regardless of what `cacheKey` looks like
///     (URLs, file paths, arbitrary identifiers — all collapse to hex).
///   - A change in width or height routes to a different file, so cached pixel
///     data is never accidentally upscaled / downscaled at render time.
public enum TGSCachedFramesPath {
    /// Default base directory: `~/Library/Caches/TGSPlayerKit/cached-frames/`.
    ///
    /// `~/Library/Caches` is the iOS/macOS convention for regenerable data — the
    /// system may purge it under storage pressure, which is fine for us: a purged
    /// cache file just triggers a one-time re-generation on next play, identical
    /// to the very-first-play path.
    public static func defaultBaseDirectory() -> URL {
        let fileManager = FileManager.default
        let cachesURL: URL
        if let url = try? fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            cachesURL = url
        } else {
            // Devices in unusual sandbox states can fail `.cachesDirectory`. Fall back
            // to the temp dir so the cached source still functions; the user just loses
            // cross-launch persistence.
            cachesURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        }
        return cachesURL
            .appendingPathComponent("TGSPlayerKit", isDirectory: true)
            .appendingPathComponent("cached-frames", isDirectory: true)
    }

    /// Compute the destination URL for the cache file of `(cacheKey, width, height)`
    /// under `baseDirectory`. Pure function — does not create directories or files.
    /// Use `ensureDirectoryExists(_:)` before writing.
    public static func destination(
        baseDirectory: URL,
        cacheKey: String,
        width: Int,
        height: Int
    ) -> URL {
        let canonical = "\(cacheKey)|\(width)x\(height)"
        let digest = SHA256.hash(data: Data(canonical.utf8))
        // 32-byte SHA256 → 64 hex chars. Plenty for collision avoidance and short
        // enough that filesystems (especially HFS+/APFS) handle it easily.
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return baseDirectory.appendingPathComponent("\(hex).tgsc", isDirectory: false)
    }

    /// Best-effort `mkdir -p`. The cache directory is created on demand the first time
    /// we want to write into it; missing-directory is the only error we explicitly fix.
    @discardableResult
    public static func ensureDirectoryExists(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return true
        }
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }
}

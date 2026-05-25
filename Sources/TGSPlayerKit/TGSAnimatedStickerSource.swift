import Foundation

public protocol TGSCancellable {
    func cancel()
}

public final class TGSNoopCancellable: TGSCancellable {
    public init() {}

    public func cancel() {}
}

public protocol TGSAnimatedStickerSource {
    var isVideo: Bool { get }

    @discardableResult
    func cachedDataPath(width: Int, height: Int, completion: @escaping ((path: String, complete: Bool)?) -> Void) -> TGSCancellable

    @discardableResult
    func directDataPath(attemptSynchronously: Bool, completion: @escaping (String?) -> Void) -> TGSCancellable
}

public final class TGSAnimatedStickerLocalFileSource: TGSAnimatedStickerSource {
    public let path: String
    public let isVideo: Bool = false

    /// Cache key used to derive the `.tgsc` cache filename. Defaults to the absolute
    /// `path` so two sources pointing at the same file land on the same cache.
    /// Callers can override (e.g. when the same logical sticker may appear under
    /// multiple paths via symlinks or copies and they want to share the cache).
    public let cacheKey: String

    /// Base directory where `.tgsc` cache files for this source are stored.
    /// Defaults to `TGSCachedFramesPath.defaultBaseDirectory()`
    /// (`~/Library/Caches/TGSPlayerKit/cached-frames/`).
    public let cacheBaseDirectory: URL

    public init(
        path: String,
        cacheKey: String? = nil,
        cacheBaseDirectory: URL? = nil
    ) {
        self.path = path
        self.cacheKey = cacheKey ?? path
        self.cacheBaseDirectory = cacheBaseDirectory ?? TGSCachedFramesPath.defaultBaseDirectory()
    }

    /// Returns the deterministic on-disk location for this source's cache at the
    /// requested render size, along with a `complete` flag reflecting whether the
    /// file is currently present.
    ///
    /// Note: this method does NOT generate the cache. Cache generation is driven
    /// by `TGSPlayerView` (which owns the rlottie loader); the source's job is
    /// solely to answer "where should this cache live, and is it there yet?".
    /// `complete == false` is the signal to the view that it should fall back to
    /// direct rendering and then write a cache here for next time.
    public func cachedDataPath(width: Int, height: Int, completion: @escaping ((path: String, complete: Bool)?) -> Void) -> TGSCancellable {
        let dest = TGSCachedFramesPath.destination(
            baseDirectory: cacheBaseDirectory,
            cacheKey: cacheKey,
            width: width,
            height: height
        )
        let exists = FileManager.default.fileExists(atPath: dest.path)
        completion((path: dest.path, complete: exists))
        return TGSNoopCancellable()
    }

    public func directDataPath(attemptSynchronously: Bool, completion: @escaping (String?) -> Void) -> TGSCancellable {
        completion(path)
        return TGSNoopCancellable()
    }
}

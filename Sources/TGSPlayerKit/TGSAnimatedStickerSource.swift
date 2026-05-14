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

    public init(path: String) {
        self.path = path
    }

    public func cachedDataPath(width: Int, height: Int, completion: @escaping ((path: String, complete: Bool)?) -> Void) -> TGSCancellable {
        completion(nil)
        return TGSNoopCancellable()
    }

    public func directDataPath(attemptSynchronously: Bool, completion: @escaping (String?) -> Void) -> TGSCancellable {
        completion(path)
        return TGSNoopCancellable()
    }
}

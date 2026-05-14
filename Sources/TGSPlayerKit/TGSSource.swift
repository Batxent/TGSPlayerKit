import Foundation

public enum TGSSource: Equatable {
    case url(URL)
    case file(URL)
    case data(Data, cacheKey: String)

    public var cacheKey: String {
        switch self {
        case let .url(url):
            return url.absoluteString
        case let .file(url):
            return url.absoluteString
        case let .data(_, cacheKey):
            return cacheKey
        }
    }
}

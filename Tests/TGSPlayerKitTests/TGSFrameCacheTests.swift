import XCTest
@testable import TGSPlayerKit

final class TGSFrameCacheTests: XCTestCase {
    func testFrameCacheEvictsLeastRecentlyUsedEntryWhenByteLimitIsExceeded() {
        let cache = TGSFrameCache(byteLimit: 8)
        let first = TGSFrameCache.Key(cacheKey: "a", frameIndex: 0, pixelSize: .init(width: 1, height: 1))
        let second = TGSFrameCache.Key(cacheKey: "b", frameIndex: 0, pixelSize: .init(width: 1, height: 2))

        cache.insert(Data(repeating: 1, count: 4), for: first)
        cache.insert(Data(repeating: 2, count: 8), for: second)

        XCTAssertNil(cache.value(for: first))
        XCTAssertEqual(cache.value(for: second), Data(repeating: 2, count: 8))
    }

    func testReadingFrameMarksItAsRecentlyUsed() {
        let cache = TGSFrameCache(byteLimit: 12)
        let first = TGSFrameCache.Key(cacheKey: "a", frameIndex: 0, pixelSize: .init(width: 1, height: 1))
        let second = TGSFrameCache.Key(cacheKey: "b", frameIndex: 0, pixelSize: .init(width: 1, height: 1))
        let third = TGSFrameCache.Key(cacheKey: "c", frameIndex: 0, pixelSize: .init(width: 1, height: 1))

        cache.insert(Data(repeating: 1, count: 4), for: first)
        cache.insert(Data(repeating: 2, count: 4), for: second)
        XCTAssertEqual(cache.value(for: first), Data(repeating: 1, count: 4))
        cache.insert(Data(repeating: 3, count: 8), for: third)

        XCTAssertEqual(cache.value(for: first), Data(repeating: 1, count: 4))
        XCTAssertNil(cache.value(for: second))
    }
}

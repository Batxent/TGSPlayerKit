import XCTest
@testable import TGSPlayerKit

final class TGSSourceTests: XCTestCase {
    func testDataSourceUsesExplicitCacheKey() {
        let source = TGSSource.data(Data([0x1f, 0x8b]), cacheKey: "sticker/wave")

        XCTAssertEqual(source.cacheKey, "sticker/wave")
    }

    func testFileSourceUsesStableAbsolutePathCacheKey() {
        let url = URL(fileURLWithPath: "/tmp/stickers/wave.tgs")
        let source = TGSSource.file(url)

        XCTAssertEqual(source.cacheKey, url.absoluteString)
    }

    func testRemoteSourceUsesAbsoluteURLCacheKey() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/wave.tgs"))
        let source = TGSSource.url(url)

        XCTAssertEqual(source.cacheKey, "https://example.com/wave.tgs")
    }
}

import Foundation
import XCTest
@testable import TGSPlayerKit

final class TGSAnimatedStickerLocalFileSourceTests: XCTestCase {
    private var tempBaseDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempBaseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tgsc-source-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempBaseDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempBaseDir {
            try? FileManager.default.removeItem(at: tempBaseDir)
        }
        try super.tearDownWithError()
    }

    func testCachedDataPathReportsNotCompleteWhenFileIsMissing() {
        let source = TGSAnimatedStickerLocalFileSource(
            path: "/tmp/wave.tgs",
            cacheBaseDirectory: tempBaseDir
        )

        var captured: (path: String, complete: Bool)?
        _ = source.cachedDataPath(width: 96, height: 96) { result in
            captured = result
        }

        // Source always hands back a deterministic path even when the file isn't there
        // yet — that's the signal to the view "go render direct, then write cache here".
        XCTAssertNotNil(captured)
        XCTAssertFalse(captured?.complete ?? true)
        XCTAssertTrue(
            captured?.path.hasPrefix(tempBaseDir.path) == true,
            "Path should be rooted in the configured cache base directory"
        )
    }

    func testCachedDataPathReportsCompleteWhenFileExistsOnDisk() throws {
        let source = TGSAnimatedStickerLocalFileSource(
            path: "/tmp/wave.tgs",
            cacheBaseDirectory: tempBaseDir
        )

        // First call learns the destination, then we plant a file there to simulate
        // a cache having been generated previously.
        var capturedPath: String?
        _ = source.cachedDataPath(width: 96, height: 96) { result in
            capturedPath = result?.path
        }
        let path = try XCTUnwrap(capturedPath)
        try Data([0x00]).write(to: URL(fileURLWithPath: path))

        var second: (path: String, complete: Bool)?
        _ = source.cachedDataPath(width: 96, height: 96) { result in
            second = result
        }
        XCTAssertEqual(second?.path, path)
        XCTAssertEqual(second?.complete, true)
    }

    func testCachedDataPathReturnsDifferentPathsForDifferentRenderSizes() {
        let source = TGSAnimatedStickerLocalFileSource(
            path: "/tmp/wave.tgs",
            cacheBaseDirectory: tempBaseDir
        )

        var small: String?
        var large: String?
        _ = source.cachedDataPath(width: 96, height: 96) { small = $0?.path }
        _ = source.cachedDataPath(width: 192, height: 192) { large = $0?.path }
        XCTAssertNotNil(small)
        XCTAssertNotNil(large)
        XCTAssertNotEqual(small, large)
    }

    func testCustomCacheKeyDecouplesCachedPathFromSourcePath() {
        // Two physical files (different `path`) that share a `cacheKey` should land on
        // the same cache file. This lets a sticker reachable via a symlink / temp copy
        // share its cached frames with the canonical location.
        let alias1 = TGSAnimatedStickerLocalFileSource(
            path: "/tmp/copy1/wave.tgs",
            cacheKey: "wave",
            cacheBaseDirectory: tempBaseDir
        )
        let alias2 = TGSAnimatedStickerLocalFileSource(
            path: "/tmp/copy2/wave.tgs",
            cacheKey: "wave",
            cacheBaseDirectory: tempBaseDir
        )

        var path1: String?
        var path2: String?
        _ = alias1.cachedDataPath(width: 96, height: 96) { path1 = $0?.path }
        _ = alias2.cachedDataPath(width: 96, height: 96) { path2 = $0?.path }
        XCTAssertEqual(path1, path2)
    }

    func testDirectDataPathStillReturnsTheOriginalPathRegardless() {
        let source = TGSAnimatedStickerLocalFileSource(path: "/tmp/wave.tgs", cacheBaseDirectory: tempBaseDir)
        var captured: String?
        _ = source.directDataPath(attemptSynchronously: true) { captured = $0 }
        XCTAssertEqual(captured, "/tmp/wave.tgs")
    }
}

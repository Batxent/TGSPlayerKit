import Foundation
import XCTest
@testable import TGSPlayerKit

final class TGSCachedFramesPathTests: XCTestCase {
    func testSameInputsAlwaysHashToTheSamePath() {
        let baseDir = URL(fileURLWithPath: "/tmp/tgsc-test", isDirectory: true)
        let a = TGSCachedFramesPath.destination(baseDirectory: baseDir, cacheKey: "wave.tgs", width: 96, height: 96)
        let b = TGSCachedFramesPath.destination(baseDirectory: baseDir, cacheKey: "wave.tgs", width: 96, height: 96)
        XCTAssertEqual(a, b)
    }

    func testDifferentCacheKeysProduceDifferentPaths() {
        let baseDir = URL(fileURLWithPath: "/tmp/tgsc-test", isDirectory: true)
        let a = TGSCachedFramesPath.destination(baseDirectory: baseDir, cacheKey: "wave.tgs", width: 96, height: 96)
        let b = TGSCachedFramesPath.destination(baseDirectory: baseDir, cacheKey: "hello.tgs", width: 96, height: 96)
        XCTAssertNotEqual(a, b)
    }

    func testDifferentDimensionsProduceDifferentPaths() {
        let baseDir = URL(fileURLWithPath: "/tmp/tgsc-test", isDirectory: true)
        let a = TGSCachedFramesPath.destination(baseDirectory: baseDir, cacheKey: "wave.tgs", width: 96, height: 96)
        let b = TGSCachedFramesPath.destination(baseDirectory: baseDir, cacheKey: "wave.tgs", width: 96, height: 192)
        let c = TGSCachedFramesPath.destination(baseDirectory: baseDir, cacheKey: "wave.tgs", width: 192, height: 96)
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertNotEqual(b, c)
    }

    func testPathIsRootedInGivenBaseDirectory() {
        let baseDir = URL(fileURLWithPath: "/tmp/tgsc-test/foo", isDirectory: true)
        let dest = TGSCachedFramesPath.destination(baseDirectory: baseDir, cacheKey: "wave.tgs", width: 96, height: 96)
        XCTAssertEqual(dest.deletingLastPathComponent(), baseDir)
    }

    func testFilenameIsHexOnlyWithTgscExtension() {
        let baseDir = URL(fileURLWithPath: "/tmp/tgsc-test", isDirectory: true)
        let dest = TGSCachedFramesPath.destination(baseDirectory: baseDir, cacheKey: "wave.tgs", width: 96, height: 96)
        let name = dest.lastPathComponent
        XCTAssertTrue(name.hasSuffix(".tgsc"))
        let stem = String(name.dropLast(".tgsc".count))
        XCTAssertEqual(stem.count, 64, "SHA256 hex should be 64 chars (got \(stem.count))")
        XCTAssertTrue(stem.allSatisfy { $0.isHexDigit }, "Filename stem should be pure hex: \(stem)")
    }

    func testCacheKeyCanContainPathSeparatorsAndUnicodeWithoutBreakingFilenames() {
        // Cache keys are typically file paths or URLs that include `/` and may carry
        // non-ASCII characters. Hashing must absorb both safely.
        let baseDir = URL(fileURLWithPath: "/tmp/tgsc-test", isDirectory: true)
        let dest = TGSCachedFramesPath.destination(
            baseDirectory: baseDir,
            cacheKey: "/Users/whoever/Library/Caches/stickers/café.tgs",
            width: 96,
            height: 96
        )
        let name = dest.lastPathComponent
        XCTAssertFalse(name.contains("/"))
        XCTAssertTrue(name.allSatisfy { $0.isASCII })
    }

    func testEnsureDirectoryExistsCreatesMissingDirsAndIsIdempotent() throws {
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tgsc-test-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("nested", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDir.deletingLastPathComponent()) }

        XCTAssertFalse(FileManager.default.fileExists(atPath: baseDir.path))
        XCTAssertTrue(TGSCachedFramesPath.ensureDirectoryExists(baseDir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: baseDir.path))

        // Calling again is fine and still returns true.
        XCTAssertTrue(TGSCachedFramesPath.ensureDirectoryExists(baseDir))
    }
}

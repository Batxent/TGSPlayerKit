import Foundation
import XCTest
@testable import TGSPlayerKit

final class TGSAnimatedStickerCachedFrameSourceTests: XCTestCase {
    // MARK: - Round-trip

    func testRoundTripPreservesEveryPixelOfEveryFrame() throws {
        let width = 8
        let height = 4
        let frames = makeDistinctFrames(count: 5, width: width, height: height)
        let url = try writeCache(frames: frames, width: width, height: height, frameRate: 24)
        defer { removeTempFile(url) }

        let reader = try TGSAnimatedStickerCachedFrameSource(cachePath: url.path)
        XCTAssertEqual(reader.frameCount, 5)
        XCTAssertEqual(reader.frameRate, 24)
        XCTAssertEqual(reader.width, width)
        XCTAssertEqual(reader.height, height)
        XCTAssertEqual(reader.bytesPerRow, width * 4)

        for expectedIndex in 0..<5 {
            let frame = reader.takeFrame(draw: true)
            XCTAssertNotNil(frame)
            XCTAssertEqual(frame?.index, expectedIndex)
            XCTAssertEqual(frame?.totalFrames, 5)
            XCTAssertEqual(frame?.isLastFrame, expectedIndex == 4)
            XCTAssertEqual(frame?.data, frames[expectedIndex],
                           "Pixel data must round-trip exactly for frame \(expectedIndex)")
        }
    }

    // MARK: - Loop wrap

    func testLoopWrapRestoresFrameZeroAfterFullLap() throws {
        let frames = makeDistinctFrames(count: 3, width: 8, height: 4)
        let url = try writeCache(frames: frames, width: 8, height: 4, frameRate: 30)
        defer { removeTempFile(url) }

        let reader = try TGSAnimatedStickerCachedFrameSource(cachePath: url.path)
        // Drive a full lap (3 frames) — reader's internal cursor is now back at 0.
        for _ in 0..<3 {
            _ = reader.takeFrame(draw: true)
        }
        XCTAssertEqual(reader.frameIndex, 0)

        // The next take must produce frame 0 with the SAME bytes as on the first lap.
        // This is the test that catches an XOR-base bug at the loop boundary: if the
        // previousFrameBuffer isn't zeroed when index wraps, frame 0 will come out
        // XOR'd with whatever the last frame was.
        let wrapped = reader.takeFrame(draw: true)
        XCTAssertEqual(wrapped?.index, 0)
        XCTAssertEqual(wrapped?.data, frames[0])
    }

    // MARK: - Skip semantics

    func testSkipForwardLandsOnExactPixelBytes() throws {
        let frames = makeDistinctFrames(count: 6, width: 8, height: 4)
        let url = try writeCache(frames: frames, width: 8, height: 4, frameRate: 60)
        defer { removeTempFile(url) }

        let reader = try TGSAnimatedStickerCachedFrameSource(cachePath: url.path)
        reader.skipToFrameIndex(3)
        let frame = reader.takeFrame(draw: true)
        XCTAssertEqual(frame?.index, 3)
        XCTAssertEqual(frame?.data, frames[3])
    }

    func testSkipBackwardReplaysFromZero() throws {
        let frames = makeDistinctFrames(count: 6, width: 8, height: 4)
        let url = try writeCache(frames: frames, width: 8, height: 4, frameRate: 60)
        defer { removeTempFile(url) }

        let reader = try TGSAnimatedStickerCachedFrameSource(cachePath: url.path)
        // Advance to frame 4.
        for _ in 0..<5 {
            _ = reader.takeFrame(draw: true)
        }
        // Now seek backward to 2.
        reader.skipToFrameIndex(2)
        let frame = reader.takeFrame(draw: true)
        XCTAssertEqual(frame?.index, 2)
        XCTAssertEqual(frame?.data, frames[2])
    }

    func testSkipToEndLandsOnLastFrame() throws {
        let frames = makeDistinctFrames(count: 4, width: 8, height: 4)
        let url = try writeCache(frames: frames, width: 8, height: 4, frameRate: 30)
        defer { removeTempFile(url) }

        let reader = try TGSAnimatedStickerCachedFrameSource(cachePath: url.path)
        reader.skipToEnd()
        let frame = reader.takeFrame(draw: true)
        XCTAssertEqual(frame?.index, 3)
        XCTAssertTrue(frame?.isLastFrame == true)
        XCTAssertEqual(frame?.data, frames[3])
    }

    func testSkipToFrameIndexNormalizesNegativeAndOverflowValues() throws {
        let frames = makeDistinctFrames(count: 4, width: 8, height: 4)
        let url = try writeCache(frames: frames, width: 8, height: 4, frameRate: 30)
        defer { removeTempFile(url) }

        let reader = try TGSAnimatedStickerCachedFrameSource(cachePath: url.path)
        reader.skipToFrameIndex(-3)
        XCTAssertEqual(reader.takeFrame(draw: true)?.data, frames[1])

        reader.skipToFrameIndex(10) // 10 % 4 == 2
        XCTAssertEqual(reader.takeFrame(draw: true)?.data, frames[2])
    }

    // MARK: - draw: false keeps state coherent

    func testTakeFrameWithoutDrawingKeepsXORStateSoNextDrawMatches() throws {
        let frames = makeDistinctFrames(count: 5, width: 8, height: 4)
        let url = try writeCache(frames: frames, width: 8, height: 4, frameRate: 30)
        defer { removeTempFile(url) }

        let reader = try TGSAnimatedStickerCachedFrameSource(cachePath: url.path)
        // Drain two frames without drawing — mimics the coordinator's missed-tick
        // skip path. This is the test that catches a bug where `draw: false`
        // short-circuits the XOR update.
        _ = reader.takeFrame(draw: false)
        _ = reader.takeFrame(draw: false)
        let drawn = reader.takeFrame(draw: true)
        XCTAssertEqual(drawn?.index, 2)
        XCTAssertEqual(drawn?.data, frames[2])
    }

    // MARK: - Corrupt file handling

    func testReaderRejectsFileSmallerThanHeader() throws {
        let url = tempFileURL()
        try Data(count: 16).write(to: url)
        defer { removeTempFile(url) }
        XCTAssertThrowsError(try TGSAnimatedStickerCachedFrameSource(cachePath: url.path)) {
            XCTAssertEqual($0 as? TGSPlayerError, .cachedSourceInvalid)
        }
    }

    func testReaderRejectsWrongMagic() throws {
        let frames = makeDistinctFrames(count: 2, width: 8, height: 4)
        let url = try writeCache(frames: frames, width: 8, height: 4, frameRate: 30)
        defer { removeTempFile(url) }

        var bytes = try Data(contentsOf: url)
        bytes[0] = 0x00 // 'T' → 0x00
        try bytes.write(to: url)
        XCTAssertThrowsError(try TGSAnimatedStickerCachedFrameSource(cachePath: url.path)) {
            XCTAssertEqual($0 as? TGSPlayerError, .cachedSourceInvalid)
        }
    }

    func testReaderRejectsUnsupportedVersion() throws {
        let frames = makeDistinctFrames(count: 2, width: 8, height: 4)
        let url = try writeCache(frames: frames, width: 8, height: 4, frameRate: 30)
        defer { removeTempFile(url) }

        var bytes = try Data(contentsOf: url)
        bytes[4] = 0xFF // bump version to something we don't grok
        try bytes.write(to: url)
        XCTAssertThrowsError(try TGSAnimatedStickerCachedFrameSource(cachePath: url.path)) {
            XCTAssertEqual($0 as? TGSPlayerError, .cachedSourceInvalid)
        }
    }

    func testReaderRejectsOutOfBoundsFrameOffset() throws {
        let frames = makeDistinctFrames(count: 2, width: 8, height: 4)
        let url = try writeCache(frames: frames, width: 8, height: 4, frameRate: 30)
        defer { removeTempFile(url) }

        var bytes = try Data(contentsOf: url)
        // Patch first index entry's offset to a value well past EOF.
        let entryBase = 32 // header size
        bytes[entryBase + 0] = 0xFF
        bytes[entryBase + 1] = 0xFF
        bytes[entryBase + 2] = 0xFF
        bytes[entryBase + 3] = 0x7F
        try bytes.write(to: url)
        XCTAssertThrowsError(try TGSAnimatedStickerCachedFrameSource(cachePath: url.path)) {
            XCTAssertEqual($0 as? TGSPlayerError, .cachedSourceInvalid)
        }
    }

    // MARK: - Compression actually compresses

    func testIdenticalFramesCollapseUnderXORDeltaPlusLZFSE() throws {
        // 10 identical 32x32 RGBA frames — every delta after the first is all zeros,
        // which LZFSE collapses to a few bytes. A regression that broke the XOR delta
        // path (e.g. by writing raw frames) would inflate the file size by ~10x.
        let frame = Data(repeating: 0x42, count: 32 * 32 * 4)
        let frames = Array(repeating: frame, count: 10)
        let url = try writeCache(frames: frames, width: 32, height: 32, frameRate: 30)
        defer { removeTempFile(url) }

        let cachedBytes = try Data(contentsOf: url).count
        let rawBytes = 32 * 32 * 4 * 10
        XCTAssertLessThan(
            cachedBytes,
            rawBytes / 5,
            "XOR delta + LZFSE should compress 10 identical frames at least 5x (got \(cachedBytes) vs \(rawBytes) raw)"
        )
    }

    // MARK: - Writer input validation

    func testWriterRejectsSourceWithZeroFrames() throws {
        let source = FakeRGBASource(frameRate: 60, width: 8, height: 4, frames: [])
        let url = tempFileURL()
        defer { removeTempFile(url) }
        XCTAssertThrowsError(try TGSAnimatedStickerCacheWriter.write(source: source, to: url)) {
            XCTAssertEqual($0 as? TGSPlayerError, .cachedSourceProducedNoFrames)
        }
    }

    func testWriterRejectsSourceThatRunsOutMidStream() throws {
        // Claim frameCount = 5 but only deliver 2 actual frames.
        let frames = makeDistinctFrames(count: 2, width: 8, height: 4)
        let source = LyingFrameCountSource(
            frameRate: 30,
            claimedFrameCount: 5,
            width: 8,
            height: 4,
            frames: frames
        )
        let url = tempFileURL()
        defer { removeTempFile(url) }
        XCTAssertThrowsError(try TGSAnimatedStickerCacheWriter.write(source: source, to: url)) {
            XCTAssertEqual($0 as? TGSPlayerError, .cachedSourceProducedNoFrames)
        }
        // .tmp must have been cleaned up so a stale partial file can't poison reuse.
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("tmp").path))
    }

    // MARK: - Helpers

    private func makeDistinctFrames(count: Int, width: Int, height: Int) -> [Data] {
        let byteCount = width * height * 4
        return (0..<count).map { i in
            var data = Data(count: byteCount)
            for j in 0..<byteCount {
                // Distinct per frame and per byte; XOR delta will be non-trivial.
                data[j] = UInt8((i &* 31 &+ j &* 7) & 0xff)
            }
            return data
        }
    }

    private func writeCache(
        frames: [Data],
        width: Int,
        height: Int,
        frameRate: Int
    ) throws -> URL {
        let source = FakeRGBASource(
            frameRate: frameRate,
            width: width,
            height: height,
            frames: frames
        )
        let url = tempFileURL()
        try TGSAnimatedStickerCacheWriter.write(source: source, to: url)
        return url
    }

    private func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tgsc-test-\(UUID().uuidString).tgsc")
    }

    private func removeTempFile(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("tmp"))
    }
}

// MARK: - Test doubles

/// Bare-bones RGBA frame source that hands back pre-built `Data` buffers in order.
/// Mirrors the contract of `TGSAnimatedStickerDirectFrameSource` so the writer can be
/// driven without spinning up rlottie.
private final class FakeRGBASource: TGSAnimatedStickerFrameSource {
    let frameRate: Int
    let frameCount: Int
    let width: Int
    let height: Int
    let bytesPerRow: Int
    private let frames: [Data]
    private var cursor: Int = 0

    var frameIndex: Int { frameCount == 0 ? 0 : cursor % frameCount }

    init(frameRate: Int, width: Int, height: Int, frames: [Data]) {
        self.frameRate = frameRate
        self.frameCount = frames.count
        self.width = width
        self.height = height
        self.bytesPerRow = width * 4
        self.frames = frames
    }

    func takeFrame(draw: Bool) -> TGSAnimatedStickerFrame? {
        guard frameCount > 0 else { return nil }
        let index = cursor % frameCount
        cursor += 1
        guard draw else { return nil }
        return TGSAnimatedStickerFrame(
            data: frames[index],
            type: .argb,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            index: index,
            isLastFrame: index == frameCount - 1,
            totalFrames: frameCount
        )
    }

    func skipToEnd() {
        cursor = max(0, frameCount - 1)
    }

    func skipToFrameIndex(_ index: Int) {
        cursor = max(0, index)
    }
}

/// Reports `frameCount = claimedFrameCount` but only knows how to produce `frames.count`
/// real frames. Used to verify the writer handles "source ran dry early".
private final class LyingFrameCountSource: TGSAnimatedStickerFrameSource {
    let frameRate: Int
    let frameCount: Int
    let width: Int
    let height: Int
    let bytesPerRow: Int
    private let frames: [Data]
    private var cursor: Int = 0

    var frameIndex: Int { cursor }

    init(frameRate: Int, claimedFrameCount: Int, width: Int, height: Int, frames: [Data]) {
        self.frameRate = frameRate
        self.frameCount = claimedFrameCount
        self.width = width
        self.height = height
        self.bytesPerRow = width * 4
        self.frames = frames
    }

    func takeFrame(draw: Bool) -> TGSAnimatedStickerFrame? {
        guard cursor < frames.count else { return nil }
        let index = cursor
        cursor += 1
        guard draw else { return nil }
        return TGSAnimatedStickerFrame(
            data: frames[index],
            type: .argb,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            index: index,
            isLastFrame: index == frameCount - 1,
            totalFrames: frameCount
        )
    }

    func skipToEnd() {}
    func skipToFrameIndex(_ index: Int) { cursor = max(0, index) }
}

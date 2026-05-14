import XCTest
@testable import TGSPlayerKit

final class TelegramCompatibilityTests: XCTestCase {
    func testPlaybackModesMatchTelegramAnimatedStickerModes() {
        XCTAssertEqual(TGSAnimatedStickerPlaybackMode.once, .once)
        XCTAssertEqual(TGSAnimatedStickerPlaybackMode.count(2), .count(2))
        XCTAssertEqual(TGSAnimatedStickerPlaybackMode.loop, .loop)
        XCTAssertEqual(TGSAnimatedStickerPlaybackMode.still(.frameIndex(4)), .still(.frameIndex(4)))
    }

    func testVisibilityStateFollowsTelegramPlaybackGate() {
        var gate = TGSAnimatedStickerVisibilityGate()
        gate.autoplay = false
        gate.visibility = true
        gate.isDisplaying = false
        gate.overrideVisibility = false

        XCTAssertFalse(gate.shouldPlay)

        gate.overrideVisibility = true

        XCTAssertTrue(gate.shouldPlay)
    }

    func testFrameQueuePrefetchesOneFrameLikeTelegram() {
        let source = FakeFrameSource(frameCount: 3)
        let queue = TGSAnimatedStickerFrameQueue(length: 1, source: source)

        XCTAssertEqual(queue.take(draw: true)?.index, 0)
        queue.generateFramesIfNeeded()
        XCTAssertEqual(source.takeFrameCallCount, 2)
        XCTAssertEqual(queue.take(draw: true)?.index, 1)
    }

    func testUIKitRendererTreatsRLottieSurfaceAsLittleEndianARGB() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("Sources/TGSPlayerKit/TGSPlayerView.swift"))

        XCTAssertTrue(view.contains("CGImageAlphaInfo.premultipliedFirst"))
        XCTAssertTrue(view.contains("CGBitmapInfo.byteOrder32Little"))
    }
}

private final class FakeFrameSource: TGSAnimatedStickerFrameSource {
    let frameRate: Int = 60
    let frameCount: Int
    private(set) var frameIndex: Int = 0
    private(set) var takeFrameCallCount: Int = 0

    init(frameCount: Int) {
        self.frameCount = frameCount
    }

    func takeFrame(draw: Bool) -> TGSAnimatedStickerFrame? {
        takeFrameCallCount += 1
        let index = frameIndex
        frameIndex = (frameIndex + 1) % frameCount
        guard draw else {
            return nil
        }
        return TGSAnimatedStickerFrame(
            data: Data([UInt8(index)]),
            type: .argb,
            width: 1,
            height: 1,
            bytesPerRow: 4,
            index: index,
            isLastFrame: index == frameCount - 1,
            totalFrames: frameCount
        )
    }

    func skipToEnd() {
        frameIndex = frameCount - 1
    }

    func skipToFrameIndex(_ index: Int) {
        frameIndex = index
    }
}

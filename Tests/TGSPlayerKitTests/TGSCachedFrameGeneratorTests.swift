import CoreGraphics
import Foundation
import XCTest
@testable import TGSPlayerKit

final class TGSCachedFrameGeneratorTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tgsc-gen-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - End-to-end

    func testGeneratorRendersDirectFramesAndWritesCacheFileOpenableAsCachedSource() throws {
        let loader = CountingLoader(width: 16, height: 8, frameCount: 4, frameRate: 30)
        let cachePath = tempDir.appendingPathComponent("out.tgsc").path
        let exp = expectation(description: "cache written")
        var result: Result<URL, TGSPlayerError>?

        let testQueue = DispatchQueue(label: "test-callback")
        TGSCachedFrameGenerator.shared.generate(
            tgsData: gzippedEmptyJSON,
            cachePath: cachePath,
            cacheKey: "fixture-\(UUID().uuidString)",
            width: 16,
            height: 8,
            loader: loader,
            completionQueue: testQueue
        ) { r in
            result = r
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5.0)

        guard case let .success(url) = result else {
            return XCTFail("Expected success, got \(String(describing: result))")
        }
        XCTAssertEqual(url.path, cachePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cachePath))

        // The written cache must be openable and report the same metadata the loader
        // produced. If the writer / reader formats ever drift this is the canary.
        let reader = try TGSAnimatedStickerCachedFrameSource(cachePath: cachePath)
        XCTAssertEqual(reader.frameCount, 4)
        XCTAssertEqual(reader.frameRate, 30)
        XCTAssertEqual(reader.width, 16)
        XCTAssertEqual(reader.height, 8)
        for i in 0..<4 {
            let frame = reader.takeFrame(draw: true)
            XCTAssertEqual(frame?.index, i)
            XCTAssertEqual(frame?.data.count, 16 * 8 * 4)
        }
    }

    func testGeneratorReturnsSuccessImmediatelyWhenCacheFileAlreadyExists() throws {
        let cachePath = tempDir.appendingPathComponent("preexisting.tgsc").path
        // Plant any file at the destination — the generator should short-circuit
        // without invoking the loader at all.
        try Data([0x42]).write(to: URL(fileURLWithPath: cachePath))

        let loader = CountingLoader(width: 8, height: 8, frameCount: 1, frameRate: 30)
        let exp = expectation(description: "fast path")
        TGSCachedFrameGenerator.shared.generate(
            tgsData: gzippedEmptyJSON,
            cachePath: cachePath,
            cacheKey: "preexisting",
            width: 8,
            height: 8,
            loader: loader,
            completionQueue: DispatchQueue(label: "cb")
        ) { result in
            if case .success = result {
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(loader.loadCount, 0, "Pre-existing cache must NOT trigger a re-render")
    }

    // MARK: - Dedupe

    func testTwoConcurrentRequestsForSameCachePathRunOnlyOneGenerationAndFireBothCompletions() {
        // Use a dedicated generator with a custom serial queue so we control timing
        // and don't share state with other tests running in this suite.
        let queue = DispatchQueue(label: "dedupe-test", qos: .utility)
        let generator = TGSCachedFrameGenerator(workQueue: queue)

        let cachePath = tempDir.appendingPathComponent("dedupe.tgsc").path
        let loader = CountingLoader(width: 8, height: 8, frameCount: 2, frameRate: 30)
        let cbQueue = DispatchQueue(label: "dedupe-cb")
        let cacheKey = "dedupe-\(UUID().uuidString)"

        let exp1 = expectation(description: "completion 1")
        let exp2 = expectation(description: "completion 2")

        // Both calls happen back-to-back on the test thread, so they both hit the
        // generator's `inFlight` map registration before the workQueue picks up the
        // generation task. Result: one underlying render, two completions.
        generator.generate(
            tgsData: gzippedEmptyJSON,
            cachePath: cachePath,
            cacheKey: cacheKey,
            width: 8, height: 8,
            loader: loader,
            completionQueue: cbQueue
        ) { _ in exp1.fulfill() }

        generator.generate(
            tgsData: gzippedEmptyJSON,
            cachePath: cachePath,
            cacheKey: cacheKey,
            width: 8, height: 8,
            loader: loader,
            completionQueue: cbQueue
        ) { _ in exp2.fulfill() }

        wait(for: [exp1, exp2], timeout: 5.0)
        XCTAssertEqual(
            loader.loadCount,
            1,
            "Concurrent requests for the same path should dedupe at the in-flight map"
        )
    }

    func testCancellingOneHandlerOfADedupedRequestDoesNotStarveTheOther() {
        let queue = DispatchQueue(label: "cancel-test", qos: .utility)
        let generator = TGSCachedFrameGenerator(workQueue: queue)
        let cachePath = tempDir.appendingPathComponent("cancel.tgsc").path
        let loader = CountingLoader(width: 8, height: 8, frameCount: 1, frameRate: 30)
        let cbQueue = DispatchQueue(label: "cancel-cb")

        let exp1 = expectation(description: "remaining completion")
        exp1.assertForOverFulfill = true
        let cancelledExp = expectation(description: "cancelled completion")
        cancelledExp.isInverted = true

        // Block the worker so we can race a cancel against the in-progress task.
        // (Without the block, the generation might already have fired both
        // completions before our `cancel()` lands.)
        let releaseWorker = DispatchSemaphore(value: 0)
        let workerEntered = DispatchSemaphore(value: 0)
        queue.async {
            workerEntered.signal()
            releaseWorker.wait()
        }
        workerEntered.wait()

        let token = generator.generate(
            tgsData: gzippedEmptyJSON,
            cachePath: cachePath,
            cacheKey: "cancel-\(UUID().uuidString)",
            width: 8, height: 8,
            loader: loader,
            completionQueue: cbQueue
        ) { _ in cancelledExp.fulfill() }

        generator.generate(
            tgsData: gzippedEmptyJSON,
            cachePath: cachePath,
            cacheKey: "cancel-\(UUID().uuidString)",
            width: 8, height: 8,
            loader: loader,
            completionQueue: cbQueue
        ) { _ in exp1.fulfill() }

        token.cancel()
        releaseWorker.signal()

        // The inverted `cancelledExp` only succeeds by NOT firing, so we have to wait
        // the full timeout. Keep it tight so the suite stays fast.
        wait(for: [exp1, cancelledExp], timeout: 1.0)
    }

    // MARK: - Helpers

    /// Two-byte gzipped `{}` payload — same fixture the direct-source tests use.
    /// Sufficient for any loader that doesn't actually parse the Lottie JSON.
    private var gzippedEmptyJSON: Data {
        Data([
            31, 139, 8, 0, 109, 170, 4, 106, 0, 3, 171, 174, 5, 0, 67, 191,
            166, 163, 2, 0, 0, 0
        ])
    }
}

// MARK: - Test doubles

private final class CountingLoader: TGSLottieAnimationLoading {
    private(set) var loadCount = 0
    private let lock = NSLock()
    private let width: Int
    private let height: Int
    private let frameCount: Int
    private let frameRate: Int

    init(width: Int, height: Int, frameCount: Int, frameRate: Int) {
        self.width = width
        self.height = height
        self.frameCount = frameCount
        self.frameRate = frameRate
    }

    func loadAnimation(
        data: Data,
        fitzModifier: TGSLottieFitzModifier,
        colorReplacements: [UInt32: UInt32]?,
        cacheKey: String
    ) throws -> TGSLottieAnimationInstance {
        lock.lock(); loadCount += 1; lock.unlock()
        return FakeAnimation(width: width, height: height, frameCount: frameCount, frameRate: frameRate)
    }
}

private final class FakeAnimation: TGSLottieAnimationInstance {
    let frameCount: Int
    let frameRate: Int
    let dimensions: CGSize

    init(width: Int, height: Int, frameCount: Int, frameRate: Int) {
        self.frameCount = frameCount
        self.frameRate = frameRate
        self.dimensions = CGSize(width: width, height: height)
    }

    func renderFrame(index: Int, width: Int, height: Int, bytesPerRow: Int) throws -> Data {
        // Produce visibly distinct frames so the cache can't trivially compress them
        // to nothing and we exercise the LZFSE encode path with non-trivial inputs.
        let byteCount = bytesPerRow * height
        var data = Data(count: byteCount)
        data.withUnsafeMutableBytes { raw in
            let base = raw.assumingMemoryBound(to: UInt8.self)
            for i in 0..<byteCount {
                base[i] = UInt8((index &* 31 &+ i &* 7) & 0xff)
            }
        }
        return data
    }
}

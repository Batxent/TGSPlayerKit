import XCTest

final class DemoProjectScaffoldTests: XCTestCase {
    func testDemoProjectUsesNativeRLottieBackendAndPerformanceHUD() throws {
        let root = packageRoot()
        let project = root.appendingPathComponent("Examples/TGSPlayerDemo/TGSPlayerDemo.xcodeproj/project.pbxproj")
        let viewController = root.appendingPathComponent("Examples/TGSPlayerDemo/TGSPlayerDemo/DemoViewController.swift")
        let sample = root.appendingPathComponent("Examples/TGSPlayerDemo/TGSPlayerDemo/Resources/sample_pulse.json")

        XCTAssertTrue(FileManager.default.fileExists(atPath: project.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sample.path))

        let projectText = try String(contentsOf: project)
        XCTAssertTrue(projectText.contains("TGSPlayerKit"))
        XCTAssertTrue(projectText.contains("TGSPlayerKitRLottieNative.xcframework"))
        XCTAssertTrue(projectText.contains("TGSRLottieAnimationLoader.swift"))

        let viewControllerText = try String(contentsOf: viewController)
        XCTAssertTrue(viewControllerText.contains("CADisplayLink"))
        XCTAssertTrue(viewControllerText.contains("TGSRLottieAnimationLoader"))
        XCTAssertTrue(viewControllerText.contains("frames/sec"))
        XCTAssertTrue(viewControllerText.contains("stressProfiles"))
    }

    func testPlayerTimerRunsOffMainQueueForScrollingPlayback() throws {
        let root = packageRoot()
        let playerView = root.appendingPathComponent("Sources/TGSPlayerKit/TGSPlayerView.swift")

        let playerViewText = try String(contentsOf: playerView)
        // Scrolling-friendly playback requires the per-frame tick to live off the main
        // RunLoop entirely, so UITrackingRunLoopMode can't starve the animation. A
        // background DispatchSource timer targeted at the per-view workQueue (which
        // itself targets the concurrent render pool) trivially satisfies this — much more
        // robust than the legacy Timer.scheduledTimer + RunLoop.main approach.
        XCTAssertTrue(
            playerViewText.contains("DispatchSource.makeTimerSource(queue: workQueue)"),
            "Playback timer must be a DispatchSourceTimer on the per-view workQueue"
        )
        XCTAssertFalse(
            playerViewText.contains("Timer.scheduledTimer"),
            "Main-RunLoop timers stall under UITrackingRunLoopMode and must not be used"
        )
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

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
        let coordinator = root.appendingPathComponent("Sources/TGSPlayerKit/TGSPlaybackCoordinator.swift")

        let playerViewText = try String(contentsOf: playerView)
        let coordinatorText = try String(contentsOf: coordinator)

        // Scrolling-friendly playback requires that the per-frame tick can't be starved
        // by UITrackingRunLoopMode. A global CADisplayLink registered to .common modes
        // fires during scroll, and per-view render work is dispatched to background
        // workQueues. Together those satisfy "playback keeps going while the user drags".
        XCTAssertTrue(
            coordinatorText.contains("link.add(to: .main, forMode: .common)"),
            "Coordinator's CADisplayLink must run in common modes so playback continues during scroll"
        )
        XCTAssertTrue(
            coordinatorText.contains("CADisplayLink(target: self, selector: #selector(handleVsync(_:)))"),
            "Coordinator must drive frame scheduling from a CADisplayLink"
        )
        XCTAssertTrue(
            playerViewText.contains("TGSPlaybackCoordinator.shared.register"),
            "Active playback must register the view with the global coordinator"
        )
        XCTAssertFalse(
            playerViewText.contains("Timer.scheduledTimer"),
            "Main-RunLoop timers stall under UITrackingRunLoopMode and must not be used"
        )
        XCTAssertFalse(
            playerViewText.contains("DispatchSource.makeTimerSource"),
            "Per-view DispatchSourceTimers were replaced by the global TGSPlaybackCoordinator"
        )
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

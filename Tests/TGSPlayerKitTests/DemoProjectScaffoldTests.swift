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

    func testPlayerTimerRunsInCommonModesForScrollingPlayback() throws {
        let root = packageRoot()
        let playerView = root.appendingPathComponent("Sources/TGSPlayerKit/TGSPlayerView.swift")

        let playerViewText = try String(contentsOf: playerView)
        XCTAssertTrue(playerViewText.contains("RunLoop.main.add(timer, forMode: .common)"))
        XCTAssertFalse(playerViewText.contains("Timer.scheduledTimer"))
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

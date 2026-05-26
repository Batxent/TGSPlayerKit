import XCTest

final class DemoProjectScaffoldTests: XCTestCase {
    func testDemoProjectUsesNativeRLottieBackendAndGiftMessageFlow() throws {
        let root = packageRoot()
        let project = root.appendingPathComponent("Examples/TGSPlayerDemo/TGSPlayerDemo.xcodeproj/project.pbxproj")
        let viewController = root.appendingPathComponent("Examples/TGSPlayerDemo/TGSPlayerDemo/DemoViewController.swift")
        let sample = root.appendingPathComponent("Examples/TGSPlayerDemo/TGSPlayerDemo/Resources/sample_pulse.json")
        let tgsDirectory = root.appendingPathComponent("Examples/TGSPlayerDemo/TGSPlayerDemo/Resources/tgs")

        XCTAssertTrue(FileManager.default.fileExists(atPath: project.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sample.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tgsDirectory.path))

        let projectText = try String(contentsOf: project)
        XCTAssertTrue(projectText.contains("TGSPlayerKit"))
        XCTAssertTrue(projectText.contains("TGSPlayerKitRLottieNative.xcframework"))
        XCTAssertTrue(projectText.contains("TGSRLottieAnimationLoader.swift"))
        XCTAssertTrue(projectText.contains(".tgs in Resources"))

        let viewControllerText = try String(contentsOf: viewController)
        XCTAssertTrue(viewControllerText.contains("UITableView"))
        XCTAssertTrue(viewControllerText.contains("RoomMessageListView"))
        XCTAssertTrue(viewControllerText.contains("GiftPanelView"))
        XCTAssertTrue(viewControllerText.contains("ChatInputBarView"))
        XCTAssertTrue(viewControllerText.contains("inputBarView.onTapStickerButton"))
        XCTAssertTrue(viewControllerText.contains("toggleGiftPanel"))
        XCTAssertTrue(viewControllerText.contains("setGiftPanelVisible"))
        XCTAssertTrue(viewControllerText.contains("giftPanelVisible"))
        XCTAssertTrue(viewControllerText.contains("giftPanelView.isHidden = true"))
        XCTAssertTrue(viewControllerText.contains("sendSticker"))
        XCTAssertTrue(viewControllerText.contains("sendSticker(sticker, from: sourceFrame)"))
        XCTAssertTrue(viewControllerText.contains("playSendDropAnimation"))
        XCTAssertTrue(viewControllerText.contains("UIView.animateKeyframes"))
        XCTAssertTrue(viewControllerText.contains("Bundle.main.urls(forResourcesWithExtension: \"tgs\""))
        XCTAssertTrue(viewControllerText.contains("loadBundledTGSURLs"))
        XCTAssertTrue(viewControllerText.contains("nestedURLs + flatURLs"))
        XCTAssertFalse(viewControllerText.contains("subdirectory: \"tgs\")\n            ?? Bundle.main.urls"))
        XCTAssertTrue(viewControllerText.contains("TGSAnimatedStickerLocalFileSource"))
        XCTAssertTrue(viewControllerText.contains("TGSRLottieAnimationLoader"))
        XCTAssertTrue(viewControllerText.contains("private let playerView = TGSPlayerView()"))
        XCTAssertFalse(viewControllerText.contains("private let previewView = TGSStickerShimmerEffectView()"))
        XCTAssertFalse(viewControllerText.contains("DemoStickerCatalogPayload"))
        XCTAssertFalse(viewControllerText.contains("RemoteAnimatedStickerSource"))
    }

    func testDemoGiftPanelUsesLocalTGSDirectory() throws {
        let root = packageRoot()
        let tgsDirectory = root.appendingPathComponent("Examples/TGSPlayerDemo/TGSPlayerDemo/Resources/tgs")
        let filenames = try FileManager.default
            .contentsOfDirectory(atPath: tgsDirectory.path)
            .filter { $0.hasSuffix(".tgs") }

        XCTAssertGreaterThanOrEqual(filenames.count, 50)
        XCTAssertTrue(filenames.contains("55.tgs"))
        XCTAssertTrue(filenames.contains("276.tgs"))
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

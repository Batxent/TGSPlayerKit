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

    func testCoordinatorKeepsOriginalDefaultDisplayLinkFrameRate() throws {
        let root = packageRoot()
        let coordinator = root.appendingPathComponent("Sources/TGSPlayerKit/TGSPlaybackCoordinator.swift")
        let coordinatorText = try String(contentsOf: coordinator)

        XCTAssertTrue(
            coordinatorText.contains("targetFrameRate"),
            "Coordinator entries must remember the sticker FPS they were registered with"
        )
        XCTAssertTrue(
            coordinatorText.contains("updateDisplayLinkFrameRate()"),
            "Coordinator must refresh the global CADisplayLink FPS when active sticker FPS changes"
        )
        XCTAssertTrue(
            coordinatorText.contains("private let defaultDisplayLinkFrameRate = 60"),
            "The display link must keep the previous 60fps default"
        )
        XCTAssertTrue(
            coordinatorText.contains("entry.displayLinkFrameRate ?? max(defaultDisplayLinkFrameRate, entry.targetFrameRate)"),
            "Active sticker FPS below the default must not lower CADisplayLink FPS implicitly"
        )
        XCTAssertTrue(
            coordinatorText.contains("displayLink.preferredFrameRateRange = CAFrameRateRange(")
                && coordinatorText.contains("minimum: Float(targetFrameRate)")
                && coordinatorText.contains("maximum: Float(targetFrameRate)")
                && coordinatorText.contains("preferred: Float(targetFrameRate)"),
            "On iOS 15+, the display link should request the target FPS directly instead of a fixed 60/120Hz range"
        )
        XCTAssertTrue(
            coordinatorText.contains("displayLink.preferredFramesPerSecond = targetFrameRate"),
            "Before iOS 15, the display link should still request the target FPS through preferredFramesPerSecond"
        )
    }

    func testExplicitPlaybackFrameRateCanLowerDisplayLinkWithoutSlowingAnimation() throws {
        let root = packageRoot()
        let playerView = root.appendingPathComponent("Sources/TGSPlayerKit/TGSPlayerView.swift")
        let coordinator = root.appendingPathComponent("Sources/TGSPlayerKit/TGSPlaybackCoordinator.swift")

        let playerViewText = try String(contentsOf: playerView)
        let coordinatorText = try String(contentsOf: coordinator)

        XCTAssertTrue(
            playerViewText.contains("public var preferredPlaybackFrameRate: Int?"),
            "PlayerView needs a public explicit target FPS for integrators to lower TGS playback on low-end devices"
        )
        XCTAssertTrue(
            playerViewText.contains("displayLinkFrameRate: self.preferredPlaybackFrameRate"),
            "Explicit playback FPS must be passed to the coordinator as an explicit CADisplayLink target"
        )
        XCTAssertTrue(
            playerViewText.contains("playbackDisplayFrameIndex")
                && playerViewText.contains("reducedPlaybackSourceFrameIndex"),
            "Reduced FPS playback must map display ticks back to source frame indexes instead of slowing the animation"
        )
        XCTAssertTrue(
            coordinatorText.contains("displayLinkFrameRate: Int? = nil"),
            "Coordinator registration must distinguish default display link FPS from an explicit low-FPS request"
        )
        XCTAssertTrue(
            coordinatorText.contains("entry.displayLinkFrameRate ?? max(defaultDisplayLinkFrameRate, entry.targetFrameRate)"),
            "Only explicit low-FPS requests should lower the global display link below the original default"
        )
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

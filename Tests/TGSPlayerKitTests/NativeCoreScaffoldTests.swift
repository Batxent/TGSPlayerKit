import XCTest

final class NativeCoreScaffoldTests: XCTestCase {
    func testRLottieBridgePreservesTelegramNativeEntryPoints() throws {
        let root = packageRoot()
        let bridge = try String(contentsOf: root.appendingPathComponent("NativeCore/RLottieBinding/TGSLottieInstance.mm"))

        XCTAssertTrue(bridge.contains("rlottie::Animation::loadFromData"))
        XCTAssertTrue(bridge.contains("renderSync"))
        XCTAssertTrue(bridge.contains("width > 1536 || height > 1536"))
        XCTAssertTrue(bridge.contains("_frameRate > 360 || _animation->duration() > 9.0"))
    }

    func testRLottieBuildScriptCreatesXCFramework() throws {
        let root = packageRoot()
        let script = try String(contentsOf: root.appendingPathComponent("scripts/build-rlottie-xcframework.sh"))

        XCTAssertTrue(script.contains("TelegramMessenger/rlottie.git"))
        XCTAssertTrue(script.contains("xcodebuild -create-xcframework"))
        XCTAssertTrue(script.contains("rlottie.xcframework"))
        XCTAssertTrue(script.contains("TGSPlayerKitRLottieNative.xcframework"))
        XCTAssertTrue(script.contains("TGSPlayerKitRLottieNative.framework"))
        XCTAssertTrue(script.contains("TGSLottieInstance.mm"))
        XCTAssertTrue(script.contains("TGSPixmanNeonFallback.cpp"))
        XCTAssertTrue(script.contains("xcrun --sdk"))
        XCTAssertTrue(script.contains("libtool -static"))
        XCTAssertTrue(script.contains("librlottie.a"))
        XCTAssertTrue(script.contains("-framework"))
        XCTAssertTrue(script.contains("CMAKE_OSX_DEPLOYMENT_TARGET=13.0"))
        XCTAssertTrue(script.contains("CMAKE_POLICY_VERSION_MINIMUM=3.5"))
        XCTAssertTrue(script.contains("--target rlottie"))
        XCTAssertFalse(script.contains("--target install"))
        XCTAssertTrue(script.contains("OTHER_CPLUSPLUSFLAGS"))
        XCTAssertTrue(script.contains("Wno-error=shorten-64-to-32"))
        XCTAssertTrue(script.contains("Wno-error=sign-compare"))
    }

    func testBinaryReleasePackagingKeepsCorePackageIndependent() throws {
        let root = packageRoot()
        let manifest = try String(contentsOf: root.appendingPathComponent("Package.swift"))
        let releaseTemplate = try String(contentsOf: root.appendingPathComponent("Package.rlottie-binary.swift.template"))
        let releaseScript = try String(contentsOf: root.appendingPathComponent("scripts/prepare-binary-release.sh"))

        XCTAssertFalse(manifest.contains("binaryTarget("))
        XCTAssertFalse(manifest.contains("TGSPlayerKitRLottie"))

        XCTAssertTrue(releaseTemplate.contains("TGSPlayerKitRLottie"))
        XCTAssertTrue(releaseTemplate.contains("TGSPlayerKitRLottieNative"))
        XCTAssertFalse(releaseTemplate.contains(".binaryTarget(\n            name: \"rlottie\""))
        XCTAssertFalse(releaseTemplate.contains("__RLOTTIE_XCFRAMEWORK_URL__"))
        XCTAssertFalse(releaseTemplate.contains("__RLOTTIE_XCFRAMEWORK_CHECKSUM__"))
        XCTAssertTrue(releaseTemplate.contains("__NATIVE_XCFRAMEWORK_URL__"))
        XCTAssertTrue(releaseTemplate.contains("__NATIVE_XCFRAMEWORK_CHECKSUM__"))

        XCTAssertTrue(releaseScript.contains("swift package compute-checksum"))
        XCTAssertTrue(releaseScript.contains("TGSPlayerKitRLottieNative.xcframework.zip"))
        XCTAssertFalse(releaseScript.contains("rlottie.xcframework.zip"))
        XCTAssertTrue(releaseScript.contains("Package.rlottie-binary.swift.template"))
    }

    func testRLottieSwiftAdapterBridgesNativeInstanceIntoLoaderProtocol() throws {
        let root = packageRoot()
        let adapter = try String(contentsOf: root.appendingPathComponent("Sources/TGSPlayerKitRLottie/TGSRLottieAnimationLoader.swift"))

        XCTAssertTrue(adapter.contains("import TGSPlayerKit"))
        XCTAssertTrue(adapter.contains("import TGSPlayerKitRLottieNative"))
        XCTAssertTrue(adapter.contains("final class TGSRLottieAnimationLoader"))
        XCTAssertTrue(adapter.contains("TGSLottieAnimationLoading"))
        XCTAssertTrue(adapter.contains("TGSLottieInstance("))
        XCTAssertTrue(adapter.contains("with:"))
        XCTAssertTrue(adapter.contains("TGSLottieFitzModifier"))
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

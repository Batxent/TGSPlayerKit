# TGSPlayerKit

Telegram iOS compatible `.tgs` animated sticker player for Swift + UIKit, built around `rlottie` and without Texture / AsyncDisplayKit.

> Status: alpha. The Swift Package, Telegram-compatible playback types, frame queue, visibility gate, decoder limits, UIKit view scaffold, Objective-C++ `rlottie` bridge, and local xcframework build script are in place. The default package stays core-only; release builds expose native rendering through a SwiftPM binary target that contains Telegram `rlottie` plus the `TGSLottieInstance` bridge.

## Design Rule

This project follows Telegram iOS animated sticker architecture. The only intentional divergence is replacing Texture nodes with UIKit views/layers.

| Telegram iOS | TGSPlayerKit |
| --- | --- |
| `AnimatedStickerNodeSource` | `TGSAnimatedStickerSource` |
| `AnimatedStickerPlaybackMode` | `TGSAnimatedStickerPlaybackMode` |
| `AnimatedStickerFrameSource` | `TGSAnimatedStickerFrameSource` |
| `AnimatedStickerFrameQueue(length: 1)` | `TGSAnimatedStickerFrameQueue(length: 1)` |
| `DefaultAnimatedStickerNodeImpl` | `TGSPlayerView` |
| `LottieInstance` | `TGSLottieAnimationInstance` |
| `ASDisplayNode` | `UIView` / `CALayer` |

No global playback scheduler is used. Playback is view-local, timer-driven, and controlled by Telegram-style visibility state.

## Installation

Add the package to an iOS project with Swift Package Manager:

```swift
.package(url: "https://github.com/your-org/TGSPlayerKit.git", from: "0.1.0")
```

Then add `TGSPlayerKit` to your app target.

## Demo

The UIKit demo lives in `Examples/TGSPlayerDemo`. It links the local package plus the generated `TGSPlayerKitRLottieNative.xcframework`, then runs a 24 / 60 / 120 player stress grid with live FPS, visible-player count, frame callback throughput, and resident memory.

Build the native backend first:

```bash
RLOTTIE_SOURCE_DIR=/path/to/TelegramMessenger/rlottie scripts/build-rlottie-xcframework.sh
```

Then open `Examples/TGSPlayerDemo/TGSPlayerDemo.xcodeproj` and run the `TGSPlayerDemo` scheme on an iOS Simulator.

## Basic UIKit Usage

```swift
import TGSPlayerKit
import UIKit

final class StickerCell: UICollectionViewCell {
    private let playerView = TGSPlayerView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(playerView)
        playerView.frame = contentView.bounds
        playerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(path: String, size: CGSize) {
        playerView.setup(
            source: TGSAnimatedStickerLocalFileSource(path: path),
            width: Int(size.width),
            height: Int(size.height),
            playbackMode: .loop,
            mode: .direct(cachePathPrefix: nil)
        )
        playerView.visibility = window != nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        playerView.reset()
    }
}
```

## Public API Shape

```swift
public final class TGSPlayerView: UIView {
    public var automaticallyLoadFirstFrame: Bool
    public var automaticallyLoadLastFrame: Bool
    public var playToCompletionOnStop: Bool
    public var stopAtNearestLoop: Bool

    public var started: () -> Void
    public var completed: (Bool) -> Void
    public var frameUpdated: (Int, Int) -> Void
    public var isPlayingChanged: (Bool) -> Void

    public var autoplay: Bool
    public var visibility: Bool
    public var overrideVisibility: Bool

    public func setup(
        source: TGSAnimatedStickerSource,
        width: Int,
        height: Int,
        playbackMode: TGSAnimatedStickerPlaybackMode,
        mode: TGSAnimatedStickerMode
    )

    public func reset()
    public func playOnce()
    public func playLoop()
    public func play(firstFrame: Bool, fromIndex: Int?)
    public func pause()
    public func stop()
    public func seekTo(_ position: TGSAnimatedStickerPlaybackPosition)
    public func playIfNeeded() -> Bool
    public func updateLayout(size: CGSize)
    public func setOverlayColor(_ color: UIColor?, replace: Bool, animated: Bool)
}
```

Native rendering follows Telegram's `LottieInstance` shape:

```swift
public protocol TGSLottieAnimationInstance: AnyObject {
    var frameCount: Int { get }
    var frameRate: Int { get }
    var dimensions: CGSize { get }

    func renderFrame(index: Int, width: Int, height: Int, bytesPerRow: Int) throws -> Data
}
```

## Current Milestones

- Done: Swift Package manifest.
- Done: Telegram-compatible source, playback mode, frame, frame source, frame queue, and visibility gate types.
- Done: direct frame source abstraction over a `rlottie` loader.
- Done: Telegram-shaped Objective-C++ `TGSLottieInstance` bridge under `NativeCore/RLottieBinding`.
- Done: `scripts/build-rlottie-xcframework.sh` for building Telegram's `rlottie` fork into `NativeCore/Artifacts/rlottie.xcframework`.
- Done: decoder limits and gzip decode path.
- Done: byte-counted LRU frame cache.
- Done: UIKit `TGSPlayerView` scaffold replacing Texture node semantics.
- Done: SwiftPM binary release template for `TGSPlayerKitRLottieNative.xcframework`.
- Done: iOS demo app with native `rlottie` playback and stress metrics.
- Next: Telegram-compatible cached frame source.

## Building rlottie

The default SwiftPM target does not compile native C++, so the package remains usable before the binary artifact exists.

To build the native artifact locally:

```bash
mkdir -p Vendor
git clone https://github.com/TelegramMessenger/rlottie.git Vendor/rlottie
scripts/build-rlottie-xcframework.sh
```

The script writes:

```text
NativeCore/Artifacts/rlottie.xcframework
NativeCore/Artifacts/TGSPlayerKitRLottieNative.xcframework
```

`rlottie.xcframework` is kept as the raw upstream build artifact. `TGSPlayerKitRLottieNative.xcframework` is the SwiftPM-facing binary target; it combines Telegram `rlottie` with the Objective-C++ bridge so app targets do not compile C++.

Prepare release files after building:

```bash
RELEASE_URL_BASE=https://github.com/your-org/TGSPlayerKit/releases/download/0.1.0 scripts/prepare-binary-release.sh
```

The release script writes `.build/binary-release/TGSPlayerKitRLottieNative.xcframework.zip` and a generated `Package.swift` with the binary checksum.

## Development

Run tests:

```bash
swift test
```

Check whitespace before sending a PR:

```bash
git diff --check
```

## Design

The technical design lives in [rlottie-tgs-player-design.md](rlottie-tgs-player-design.md). It documents the Telegram iOS implementation map and the UIKit replacement rules.

## License

TGSPlayerKit is available under the MIT license. `rlottie` is not vendored in this repository yet; see [NOTICE](NOTICE) for third-party dependency notes.

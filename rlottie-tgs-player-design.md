# rlottie TGS UIKit Player Technical Design

## Design Baseline

The implementation baseline for this project is not to redesign a "reasonable TGS
player." Instead, it follows Telegram iOS animated sticker behavior and only
replaces Texture / AsyncDisplayKit with UIKit / CALayer.

In other words:

- Replace `ASDisplayNode` with `UIView` or `CALayer`.
- Replace `didEnterHierarchy` / `didExitHierarchy` with `didMoveToWindow` or a
  UIKit hierarchy tracking layer.
- Replace `addSubnode` with `addSubview` / `layer.addSublayer`.
- Replace `ASDisplayNode.contents` with `CALayer.contents` or an internal
  `UIImageView.image`.
- Do not introduce Texture, but keep Telegram semantics for source, frame source,
  frame queue, playback mode, visibility gate, renderer pool, and direct/cached
  mode.

The "global playback scheduler" from the old plan is no longer a design direction.
In Telegram iOS, each animated sticker view/node owns its own playback timer, and
that timer is controlled by visibility and playback state.

## Telegram iOS Alignment Table

| Telegram iOS | UIKit Version |
| --- | --- |
| `AnimatedStickerNodeSource` | `TGSAnimatedStickerSource` |
| `AnimatedStickerMode.cached/direct` | `TGSAnimatedStickerMode.cached/direct` |
| `AnimatedStickerPlaybackMode` | `TGSAnimatedStickerPlaybackMode` |
| `AnimatedStickerPlaybackPosition` | `TGSAnimatedStickerPlaybackPosition` |
| `AnimatedStickerFrame` | `TGSAnimatedStickerFrame` |
| `AnimatedStickerFrameSource` | `TGSAnimatedStickerFrameSource` |
| `AnimatedStickerFrameQueue(length: 1)` | `TGSAnimatedStickerFrameQueue(length: 1)` |
| `DefaultAnimatedStickerNodeImpl` | `TGSPlayerView` |
| `DirectAnimatedStickerNode` | Can later be a lightweight direct-only `UIView` variant |
| `LottieInstance` Objective-C++ bridge | `TGSLottieAnimationInstance` / `TGSLottieAnimationLoading` |
| `SoftwareAnimationRenderer` | UIKit software renderer |
| `CompressedAnimationRenderer` | Optional Metal renderer, implemented in later phases |
| `StickerShimmerEffectNode` | `TGSStickerShimmerEffectView` |
| `ShimmerEffectForegroundNode` | Horizontal sweeping `CAGradientLayer` inside `TGSStickerShimmerEffectView` |
| Telegram sticker thumbnail SVG | `TGSStickerSilhouette.svgData(_:)` + `TGSSVGPathParser` |

## Overall Architecture

```text
TGSPlayerKit
├── NativeCore
│   ├── rlottie.xcframework
│   ├── TGSLottieInstance.h
│   └── TGSLottieInstance.mm
├── Core
│   ├── TGSAnimatedStickerSource
│   ├── TGSAnimatedStickerFrameSource
│   ├── TGSAnimatedStickerFrameQueue
│   ├── TGSDecoder
│   ├── TGSLottieAnimationLoading
│   └── TGSFrameCache
└── UI
    ├── TGSPlayerView
    ├── TGSAnimationRenderer
    └── TGSAnimatedStickerVisibilityGate
```

The core playback pipeline must stay aligned with Telegram:

```text
setup(source, width, height, playbackMode, mode)
  -> source.directDataPath or source.cachedDataPath
  -> direct: mappedRead data
  -> gzip decompression, direct path limit same as Telegram: 8 MB
  -> LottieInstance(data, fitzModifier, colorReplacements, cacheKey)
  -> read frameCount / frameRate / dimensions
  -> AnimatedStickerFrameSource
  -> AnimatedStickerFrameQueue(length: 1)
  -> Timer(1 / frameRate)
  -> frameQueue.take(draw: true)
  -> renderer.render(frame)
  -> submit UIImage / CALayer contents on main thread
```

## Source Design

Follow Telegram source boundaries: the player should not know the business asset
system directly. It only depends on the source returning a direct path or cached
path.

```swift
public protocol TGSAnimatedStickerSource {
    var isVideo: Bool { get }

    func cachedDataPath(
        width: Int,
        height: Int,
        completion: @escaping ((path: String, complete: Bool)?) -> Void
    ) -> TGSCancellable

    func directDataPath(
        attemptSynchronously: Bool,
        completion: @escaping (String?) -> Void
    ) -> TGSCancellable
}
```

The open-source library can provide three sources:

- `TGSAnimatedStickerLocalFileSource`
- `TGSAnimatedStickerDataSource`
- `TGSAnimatedStickerURLSource`

But all of them must be adapted to Telegram-style direct/cached path semantics,
instead of letting the UI layer read business models directly.

## Playback Mode

Playback mode must align with Telegram:

```swift
public enum TGSAnimatedStickerPlaybackMode {
    case once
    case count(Int)
    case loop
    case still(TGSAnimatedStickerPlaybackPosition)
}

public enum TGSAnimatedStickerPlaybackPosition {
    case start
    case end
    case timestamp(Double)
    case frameIndex(Int)
}
```

Behavior requirements:

- `.once` stops at the last frame and calls `completed(true)`.
- `.count(n)` stops after `n` completed loops.
- `.loop` calls `completed(false)` at each end frame and continues playing.
- `.still(.start/.end/.timestamp/.frameIndex)` renders only the target frame.
- `stopAtNearestLoop` stops at the next loop boundary.

## Visibility Gate

Telegram playback gating is determined by `visibility`, hierarchy presence, and
`overrideVisibility`.

The UIKit version uses:

```swift
shouldPlay = visibility && (isDisplaying || overrideVisibility)
```

When `autoplay == true`, the view can actively play without external visibility
input.

Texture's `AnimatedStickerNodeDisplayEvents` is replaced in UIKit by:

- Minimal version: `didMoveToWindow`.
- Stricter version: a dedicated `HierarchyTrackingLayer` that triggers on
  enter/leave window.

## Frame Source

### Direct Frame Source

The direct path aligns with Telegram's `AnimatedStickerDirectFrameSource`:

- Store `data`, `width`, `height`, `bytesPerRow`, and `currentFrame`.
- gzip decompression equivalent to `TGGUnzipData(data, 8 * 1024 * 1024) ?? data`.
- Source creation fails if `LottieInstance` fails to load.
- `frameCount = max(1, animation.frameCount)`.
- `frameRate = max(1, animation.frameRate)`.
- Each `takeFrame(draw:)` computes `currentFrame % frameCount` first, then
  increments.
- When `draw == false`, only advance the frame index without generating a bitmap.
- When `draw == true`, render with rlottie into an ARGB buffer.

### Cached Frame Source

The cached path must follow Telegram cache formats, not a custom incompatible one.

Telegram currently has two related paths:

- `AnimatedStickerCachedFrameSource`: read frame table, LZFSE decompress, then
  restore with XOR delta.
- `AnimationCache` / `DCTAnimationCacheImpl` / `SubcodecAnimationCacheImpl`:
  writer stores frames into reusable cache, then multi animation renderer reads it.

Phase 1 in open-source can implement only direct mode, but the public API must keep
`.cached`. Once cached mode is implemented, file format, frame progression, and
first-frame reading semantics must align with Telegram.

## Frame Queue

`TGSAnimatedStickerFrameQueue` keeps Telegram's length-1 model:

- `take(draw:)`: when queue is empty, fetch one frame from source, then pop the
  first frame.
- `generateFramesIfNeeded()`: prefetch next frame when queue is empty.
- No multi-frame accumulation and no large queue for "smoothness."

This design is better than large buffering for cell reuse and fast cancellation.

## Native Bridge

The Objective-C++ bridge aligns with Telegram's `LottieInstance`:

```objc
@interface TGSLottieInstance : NSObject

@property (nonatomic, readonly) int32_t frameCount;
@property (nonatomic, readonly) int32_t frameRate;
@property (nonatomic, readonly) CGSize dimensions;

- (nullable instancetype)initWithData:(NSData *)data
                         fitzModifier:(TGSLottieFitzModifier)fitzModifier
                    colorReplacements:(NSDictionary *)colorReplacements
                              cacheKey:(NSString *)cacheKey;

- (void)renderFrameWithIndex:(int32_t)index
                        into:(uint8_t *)buffer
                       width:(int32_t)width
                      height:(int32_t)height
                 bytesPerRow:(int32_t)bytesPerRow;

@end
```

This repository already includes the bridge and local artifact build script:

```text
NativeCore/RLottieBinding/TGSLottieInstance.h
NativeCore/RLottieBinding/TGSLottieInstance.mm
NativeCore/RLottieBinding/module.modulemap
scripts/build-rlottie-xcframework.sh
```

By default, SwiftPM targets do not compile this part, because an open-source repo
must still be cloneable, testable, and CI-friendly without native artifacts. The
release path uses binary targets:

- `NativeCore/Artifacts/rlottie.xcframework`: raw static library artifact from
  Telegram fork.
- `NativeCore/Artifacts/TGSPlayerKitRLottieNative.xcframework`: framework-style
  binary target for SwiftPM consumers, internally merging `rlottie` static library
  and `TGSLottieInstance` bridge.

SwiftPM native target is not selected here: it would force consumers to compile
Telegram `rlottie` locally with CMake/Xcode C++ configuration, and that install
cost, CI uncertainty, and compile time are not suitable for the default GitHub
open-source path.

Implementation constraints:

- `.mm` internally owns `std::unique_ptr<rlottie::Animation>`.
- Use `rlottie::Animation::loadFromData(...)`.
- `frameCount` and `frameRate` must be at least 1.
- Dimensions must be at least 1x1.
- Follow Telegram bridge safety limits: dimensions <= 1536x1536, frameRate <= 360,
  duration <= 9 seconds.
- TGS business constraints (512x512 / 3 seconds) can be validated at upper layers,
  while native bridge first follows Telegram iOS compatibility boundaries.
- `renderFrame` uses `rlottie::Surface` and `renderSync`.

## Silhouette + Shimmer Placeholder

Before the first sticker frame arrives, Telegram iOS shows a "silhouette + horizontal
shimmer" placeholder animation, implemented as `StickerShimmerEffectNode` +
`ShimmerEffectForegroundNode`. The UIKit version strictly aligns with this behavior:

```text
TGSStickerShimmerEffectView
├── containerLayer (mask = maskLayer)
│   ├── backgroundLayer (CAShapeLayer, fill = foregroundColor)
│   └── shimmerLayer  (CAGradientLayer, [clear, shimmeringColor, clear], horizontal sweep)
└── maskLayer (CAShapeLayer with silhouette path or contents = silhouette image)
```

Silhouette input is abstracted by `TGSStickerSilhouetteShape`:

- `.svgData(Data)`: parse SVG in-process using internal `TGSSVGPathParser`, with no
  third-party dependency. Supports full command set `M m L l H h V v C c S s Q q T t
  Z z A a`; arcs use SVG 1.1 compliant arc-to-cubic segmented approximation (each
  segment <= pi/2). If `viewBox` is missing, fallback to `width/height`, then
  `path.boundingBox`.
- `.image(UIImage)`: use image alpha channel as mask (aligned with Telegram iOS
  `placeholderImage` behavior).
- `.path(CGPath, viewBox:)`: if caller already has `CGPath`, use it directly to
  avoid duplicate parsing.

Shimmer behavior aligned with Telegram iOS:

- Horizontal direction: `startPoint = (0, 0.5)`, `endPoint = (1, 0.5)`,
  `locations = [0, 0.5, 1]`.
- Colors: `[clear, shimmeringColor, clear]`, default
  `shimmeringColor = white alpha 0.55`.
- Animation: `transform.translation.x` from `-width` to `width`, infinite repeat,
  `easeInEaseOut`, default `duration = 1.3s`.
- Attach animation only while view is in window; stop automatically when removed.
- Mask uses aspect-fit to place viewBox at the center of view bounds, ensuring the
  shimmer is visible only inside silhouette region.

`TGSPlayerView` integration rules:

- Silhouette view is always added above `imageView` as the top-most subview.
- After assigning `silhouette`, it becomes visible immediately and calls
  `startAnimating`; set `showsSilhouetteUntilFirstFrame = false` to disable
  immediately.
- When the real first frame (`submitFrame(_:)`) arrives, fade out with
  `silhouetteFadeOutDuration` (default `0.25s`) through alpha transition, then
  `stopAnimating` + `isHidden = true`.
- `reset()` / `prepareForReuse()` clear first-frame state so silhouette appears
  again on cell reuse, matching Telegram iOS `AnimatedStickerNode.reset` semantics.

No extra render thread or global shimmer scheduler is introduced: each
`TGSStickerShimmerEffectView` is driven by local Core Animation implicit animations,
which follows the project principle of "view-local, no global scheduler."

## Renderer

UIKit first implements the equivalent of Telegram `SoftwareAnimationRenderer`:

- `.argb`: directly produce `CGImage` / `UIImage`.
- `.yuva`: add `YUVA -> RGBA` conversion after cached mode lands.
- `.dct`: add after Metal/DCT cache implementation.
- Overlay color is implemented via template image or a separate overlay image view.
- Frame submission happens on the main thread.

The Metal path corresponding to `CompressedAnimationRenderer` can be Phase 3, but it
must not change direct frame source and playback mode semantics in advance.

## UIKit API

`TGSPlayerView` aligns with Telegram node API:

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

Extra convenience APIs such as `setSource(_:)` and `renderFirstFrame()` may remain,
but they must not become the core architecture path.

## Texture-Free Replacement Rules

| Texture Style | UIKit Replacement |
| --- | --- |
| `ASDisplayNode` | `UIView` |
| `ASDisplayNode(viewBlock:)` | lazy `UIView` / subclass |
| `addSubnode` | `addSubview` |
| `removeFromSupernode` | `removeFromSuperview` |
| `node.contents` | `view.layer.contents` |
| `isInHierarchy` | `window != nil` or hierarchy tracking layer |
| node renderer pool | view renderer pool |

Beyond this, do not change Telegram playback semantics.

## Testing Strategy

Must cover:

- Playback mode enum compatibility with Telegram.
- Visibility gate behavior compatibility.
- Frame queue length-1 prefetch compatibility.
- Direct frame source frame index progression and loop behavior.
- `skipToEnd` / `skipToFrameIndex`.
- gzip decompression size limit.
- Invalid lottie data must not crash.
- `prepareForReuse` / `reset` cancel source and timer.
- UIKit target builds successfully on iOS simulator.
- SVG path parser covers `M/L/H/V/C/S/Q/T/Z/A` commands and failure paths for
  missing viewBox / invalid XML / missing path.
- `TGSStickerShimmerEffectView` `start/stopAnimating`, style updates, and image/svg
  inputs.
- `TGSPlayerView` silhouette visibility lifecycle: hidden by default, visible with
  shimmer after assignment, fades out after first frame, reappears after `reset`,
  and hides immediately when `showsSilhouetteUntilFirstFrame = false`.

## Phased Implementation

### Phase 1: Telegram Semantics Skeleton

- SwiftPM project.
- Telegram-compatible public types.
- UIKit `TGSPlayerView` replaces `DefaultAnimatedStickerNodeImpl`.
- Direct frame source protocol and tests.
- README explicitly states: "No Texture, but follows Telegram iOS playback model."

### Phase 2: rlottie Bridge

- `NativeCore/Artifacts/rlottie.xcframework` has been built via
  `scripts/build-rlottie-xcframework.sh`.
- `TGSLottieInstance.h/mm` is in place, preserving Telegram `LottieInstance`
  native entry shape.
- Select SwiftPM native target or binary target for release packaging.
- Direct mode truly renders `.tgs`.
- iOS example app plays local `.tgs`.

### Phase 3: Cache and Renderer

- Implement Telegram-compatible cached frame source.
- Add YUVA/DCT renderer.
- Optional Metal renderer.
- Long-list example and performance data.

### Phase 4: Open-Source Release Quality

- API docs.
- Example app.
- CI covers SwiftPM tests and iOS simulator build.
- License / NOTICE / benchmark reports.

## References

- Telegram iOS `AnimatedStickerNode`
- Telegram iOS `AnimatedStickerFrameSource`
- Telegram iOS `LottieInstance`
- Telegram iOS `LottieAnimationCache`
- Telegram animated sticker format documentation

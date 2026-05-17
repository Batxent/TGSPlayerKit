# rlottie TGS UIKit 播放器技术设计

## 设计基准

本项目的实现基准不是重新设计一个“合理的 TGS 播放器”，而是遵守
Telegram iOS 的 animated sticker 实现，只把 Texture / AsyncDisplayKit
替换为 UIKit / CALayer。

也就是说：

- `ASDisplayNode` 替换为 `UIView` 或 `CALayer`。
- `didEnterHierarchy` / `didExitHierarchy` 替换为 `didMoveToWindow` 或
  UIKit 版 hierarchy tracking layer。
- `addSubnode` 替换为 `addSubview` / `layer.addSublayer`。
- `ASDisplayNode.contents` 替换为 `CALayer.contents` 或内部 `UIImageView.image`。
- 不引入 Texture，但保留 Telegram 的 source、frame source、frame queue、
  playback mode、visibility gate、renderer pool、direct/cached mode 语义。

旧方案里的“全局播放调度器”不再作为设计方向。Telegram iOS 的主实现是每个
animated sticker view/node 自己持有播放 timer，timer 由可见性和播放状态控制。

## Telegram iOS 对齐表

| Telegram iOS | UIKit 版本 |
| --- | --- |
| `AnimatedStickerNodeSource` | `TGSAnimatedStickerSource` |
| `AnimatedStickerMode.cached/direct` | `TGSAnimatedStickerMode.cached/direct` |
| `AnimatedStickerPlaybackMode` | `TGSAnimatedStickerPlaybackMode` |
| `AnimatedStickerPlaybackPosition` | `TGSAnimatedStickerPlaybackPosition` |
| `AnimatedStickerFrame` | `TGSAnimatedStickerFrame` |
| `AnimatedStickerFrameSource` | `TGSAnimatedStickerFrameSource` |
| `AnimatedStickerFrameQueue(length: 1)` | `TGSAnimatedStickerFrameQueue(length: 1)` |
| `DefaultAnimatedStickerNodeImpl` | `TGSPlayerView` |
| `DirectAnimatedStickerNode` | 后续可作为轻量 direct-only `UIView` 变体 |
| `LottieInstance` Objective-C++ bridge | `TGSLottieAnimationInstance` / `TGSLottieAnimationLoading` |
| `SoftwareAnimationRenderer` | UIKit software renderer |
| `CompressedAnimationRenderer` | 可选 Metal renderer，后续阶段实现 |
| `StickerShimmerEffectNode` | `TGSStickerShimmerEffectView` |
| `ShimmerEffectForegroundNode` | `TGSStickerShimmerEffectView` 内部的 `CAGradientLayer` 横向 sweep |
| Telegram sticker thumbnail SVG | `TGSStickerSilhouette.svgData(_:)` + `TGSSVGPathParser` |

## 总体架构

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

核心播放链路必须保持 Telegram 的方向：

```text
setup(source, width, height, playbackMode, mode)
  -> source.directDataPath 或 source.cachedDataPath
  -> direct: mappedRead data
  -> gzip 解压，direct 路径上限跟 Telegram：8 MB
  -> LottieInstance(data, fitzModifier, colorReplacements, cacheKey)
  -> 读取 frameCount / frameRate / dimensions
  -> AnimatedStickerFrameSource
  -> AnimatedStickerFrameQueue(length: 1)
  -> Timer(1 / frameRate)
  -> frameQueue.take(draw: true)
  -> renderer.render(frame)
  -> 主线程提交 UIImage / CALayer contents
```

## Source 设计

遵守 Telegram 的 source 边界：播放器不直接知道业务资源系统，只依赖 source
返回 direct path 或 cached path。

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

开源库可以提供三种 source：

- `TGSAnimatedStickerLocalFileSource`
- `TGSAnimatedStickerDataSource`
- `TGSAnimatedStickerURLSource`

但最终都要适配成 Telegram 同款 direct/cached path 语义，而不是让 UI 层读取业务模型。

## Playback Mode

Playback mode 必须与 Telegram 对齐：

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

行为要求：

- `.once` 播放到最后一帧后停止并回调 completed(true)。
- `.count(n)` 完成 n 次 loop 后停止。
- `.loop` 每次到最后一帧回调 completed(false)，继续播放。
- `.still(.start/.end/.timestamp/.frameIndex)` 只渲染目标帧。
- `stopAtNearestLoop` 在下一次 loop 边界停止。

## Visibility Gate

Telegram 的播放开关由 `visibility`、是否在 hierarchy、`overrideVisibility` 共同决定。

UIKit 版本使用：

```swift
shouldPlay = visibility && (isDisplaying || overrideVisibility)
```

当 `autoplay == true` 时，view 可以绕过外部 visibility 输入主动播放。

Texture 的 `AnimatedStickerNodeDisplayEvents` 在 UIKit 中替换为：

- 最小版本：`didMoveToWindow`。
- 更严格版本：独立 `HierarchyTrackingLayer`，进入/离开 window 时触发。

## Frame Source

### Direct Frame Source

Direct path 与 Telegram 的 `AnimatedStickerDirectFrameSource` 对齐：

- 保存 `data`、`width`、`height`、`bytesPerRow`、`currentFrame`。
- gzip 解压：`TGGUnzipData(data, 8 * 1024 * 1024) ?? data` 的等价实现。
- `LottieInstance` 加载失败则 source 创建失败。
- `frameCount = max(1, animation.frameCount)`。
- `frameRate = max(1, animation.frameRate)`。
- 每次 `takeFrame(draw:)` 都先计算 `currentFrame % frameCount`，然后递增。
- `draw == false` 时只前进帧，不生成 bitmap。
- `draw == true` 时调用 rlottie render 到 ARGB buffer。

### Cached Frame Source

Cached path 必须遵守 Telegram 的缓存格式，而不是自定义一套不兼容格式。

Telegram 现在有两条相关路线：

- `AnimatedStickerCachedFrameSource`：读取 frame table，LZFSE 解压，再用 XOR delta 还原。
- `AnimationCache` / `DCTAnimationCacheImpl` / `SubcodecAnimationCacheImpl`：
  用 writer 把帧写入可复用缓存，再由 multi animation renderer 读取。

开源第一阶段可以只实现 direct mode，但 public API 必须保留 `.cached`。一旦实现
cached mode，文件格式、帧推进、first-frame 读取语义必须对齐 Telegram。

## Frame Queue

`TGSAnimatedStickerFrameQueue` 保持 Telegram 的 length 1 模型：

- `take(draw:)`：队列为空时从 source 取一帧，然后弹出第一帧。
- `generateFramesIfNeeded()`：队列为空时预取下一帧。
- 不做多帧堆积，不引入“为了流畅度”的大队列。

这个设计比大缓存更适合 cell 复用和快速取消。

## Native Bridge

Objective-C++ bridge 对齐 Telegram 的 `LottieInstance`：

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

当前仓库已落地 bridge 和本地 artifact 构建脚本：

```text
NativeCore/RLottieBinding/TGSLottieInstance.h
NativeCore/RLottieBinding/TGSLottieInstance.mm
NativeCore/RLottieBinding/module.modulemap
scripts/build-rlottie-xcframework.sh
```

默认 SwiftPM target 不编译这部分，原因是 open-source repo 在没有 native artifact
时仍必须能被 clone、test、CI。发布版本使用 binary target：

- `NativeCore/Artifacts/rlottie.xcframework`：Telegram fork 的原始静态库 artifact。
- `NativeCore/Artifacts/TGSPlayerKitRLottieNative.xcframework`：SwiftPM 对外消费的
  framework-style binary target，内部合并 `rlottie` 静态库和 `TGSLottieInstance` bridge。

这里不选 SwiftPM native target：native target 会要求使用方本地编译 Telegram `rlottie`
和 CMake/Xcode C++ 配置，安装成本、CI 不确定性、编译时间都不适合 GitHub 开源库默认路径。

实现约束：

- `.mm` 内部持有 `std::unique_ptr<rlottie::Animation>`。
- 使用 `rlottie::Animation::loadFromData(...)`。
- `frameCount`、`frameRate` 至少为 1。
- dimensions 至少为 1x1。
- 遵守 Telegram bridge 的安全上限：dimensions 不超过 1536x1536，
  frameRate 不超过 360，duration 不超过 9 秒。
- TGS 业务约束 512x512 / 3 秒可以在更上层校验，但 native bridge 先按
  Telegram iOS 的兼容边界处理。
- `renderFrame` 用 `rlottie::Surface` 和 `renderSync`。

## Silhouette + Shimmer Placeholder

Telegram iOS 在贴纸首帧抵达前用一段“剪影 + 横向 shimmer”的占位动画，对应实现是
`StickerShimmerEffectNode` + `ShimmerEffectForegroundNode`。UIKit 版严格对齐这一行为：

```text
TGSStickerShimmerEffectView
├── containerLayer (mask = maskLayer)
│   ├── backgroundLayer (CAShapeLayer, fill = foregroundColor)
│   └── shimmerLayer  (CAGradientLayer, [clear, shimmeringColor, clear], 横向 sweep)
└── maskLayer (CAShapeLayer with silhouette path 或 contents = silhouette image)
```

剪影输入由 `TGSStickerSilhouetteShape` 抽象：

- `.svgData(Data)`：用项目内 `TGSSVGPathParser` 在进程内解析 SVG，无第三方依赖。
  支持 `M m L l H h V v C c S s Q q T t Z z A a` 全套命令；arc 用 SVG 1.1 规范的
  弧→三次贝塞尔分段近似（每段 ≤ π/2）。viewBox 缺失时回退到 `width/height`，再退到
  `path.boundingBox`。
- `.image(UIImage)`：把 image 的 alpha 通道当作 mask（与 Telegram iOS 接受
  `placeholderImage` 的形式一致）。
- `.path(CGPath, viewBox:)`：调用方已有 `CGPath` 时直接走这一条路径，避免重复解析。

shimmer 行为对齐 Telegram iOS：

- 横向方向：`startPoint = (0, 0.5)`、`endPoint = (1, 0.5)`、`locations = [0, 0.5, 1]`。
- 颜色：`[clear, shimmeringColor, clear]`，默认 `shimmeringColor = white α=0.55`。
- 动画：`transform.translation.x` 从 `-width` 到 `width`，repeat infinity，
  `easeInEaseOut`，默认 `duration = 1.3s`。
- 只在视图位于 window 时挂动画，离开 window 自动停。
- mask 用 `aspect-fit` 把 viewBox 置于 view bounds 中心，保证 shimmer 仅在
  剪影区域内可见。

`TGSPlayerView` 集成规则：

- 剪影视图始终被加在 imageView 之上、是子视图最顶层。
- 赋值 `silhouette` 后立即可见并 `startAnimating`；`showsSilhouetteUntilFirstFrame = false`
  可立即关闭。
- 真正首帧（`submitFrame(_:)`）到达时，用 `silhouetteFadeOutDuration`（默认 `0.25s`）
  做 alpha 过渡淡出，然后 `stopAnimating` + `isHidden = true`。
- `reset()` / `prepareForReuse()` 清掉首帧标记，cell 复用时剪影会重新出现，
  这一点与 Telegram iOS `AnimatedStickerNode.reset` 的语义相同。

不引入额外的渲染线程或全局 shimmer 调度器：每个 `TGSStickerShimmerEffectView`
自己用 Core Animation 的隐式动画驱动，符合“view-local、无全局调度器”这一项目原则。

## Renderer

UIKit 版本先实现 Telegram `SoftwareAnimationRenderer` 的等价物：

- `.argb`：直接生成 `CGImage` / `UIImage`。
- `.yuva`：cached mode 实现后补 `YUVA -> RGBA` 转换。
- `.dct`：Metal/DCT cache 实现后补。
- overlay color 用 template image 或独立 overlay image view 实现。
- frame 提交发生在主线程。

`CompressedAnimationRenderer` 对应的 Metal path 可以作为 Phase 3，但不能提前改变
direct frame source 和 playback mode 语义。

## UIKit API

`TGSPlayerView` 对齐 Telegram node API：

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

可以额外保留 `setSource(_:)`、`renderFirstFrame()` 这类 convenience API，但不能让它们
成为真实架构主线。

## 不引入 Texture 的替换规则

| Texture 写法 | UIKit 替换 |
| --- | --- |
| `ASDisplayNode` | `UIView` |
| `ASDisplayNode(viewBlock:)` | lazy `UIView` / 子类 |
| `addSubnode` | `addSubview` |
| `removeFromSupernode` | `removeFromSuperview` |
| `node.contents` | `view.layer.contents` |
| `isInHierarchy` | `window != nil` 或 hierarchy tracking layer |
| node renderer pool | view renderer pool |

除此之外，不额外改 Telegram 的播放语义。

## 测试策略

必须覆盖：

- playback mode 枚举与 Telegram 一致。
- visibility gate 行为一致。
- frame queue length 1 预取一致。
- direct frame source 的 frame index 递增和 loop。
- `skipToEnd` / `skipToFrameIndex`。
- gzip 解压上限。
- invalid lottie data 不 crash。
- `prepareForReuse` / `reset` 取消 source 和 timer。
- UIKit 目标在 iOS simulator 编译通过。
- SVG path parser 覆盖 `M/L/H/V/C/S/Q/T/Z/A` 命令以及 viewBox 缺失/非法 XML/缺 path
  的失败路径。
- `TGSStickerShimmerEffectView` 的 `start/stopAnimating`、style 更新、image/svg 输入。
- `TGSPlayerView` 的剪影显隐：默认隐藏、赋值后显示并 shimmer、首帧后淡出、
  `reset` 后再次显示、`showsSilhouetteUntilFirstFrame = false` 立即隐藏。

## 分阶段实施

### Phase 1：Telegram 语义骨架

- SwiftPM 工程。
- Telegram-compatible public types。
- UIKit `TGSPlayerView` 替换 `DefaultAnimatedStickerNodeImpl`。
- Direct frame source 协议和测试。
- README 明确“不引入 Texture，但遵守 Telegram iOS playback model”。

### Phase 2：rlottie bridge

- 已使用 `scripts/build-rlottie-xcframework.sh` 编译
  `NativeCore/Artifacts/rlottie.xcframework`。
- 已落地 `TGSLottieInstance.h/mm`，保持 Telegram `LottieInstance` 的 native 入口形状。
- 选择 SwiftPM native target 或 binary target 作为发布包装。
- direct mode 真正渲染 `.tgs`。
- iOS example app 播放本地 `.tgs`。

### Phase 3：缓存和 renderer

- 实现 Telegram-compatible cached frame source。
- 补 YUVA/DCT renderer。
- 可选 Metal renderer。
- long-list 示例和性能数据。

### Phase 4：开源发布质量

- API docs。
- Example app。
- CI 覆盖 SwiftPM test 和 iOS simulator build。
- License / NOTICE / benchmark 报告。

## 参考

- Telegram iOS `AnimatedStickerNode`
- Telegram iOS `AnimatedStickerFrameSource`
- Telegram iOS `LottieInstance`
- Telegram iOS `LottieAnimationCache`
- Telegram animated sticker format documentation

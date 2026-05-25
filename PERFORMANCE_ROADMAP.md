# TGSPlayerKit 性能优化路线图

这份文档记录 TGSPlayerKit 在**已完成主体优化之后**仍可继续推进的性能改进项。
每一项标注了**收益预估**、**工作量**、**风险**与**前置条件**，按"投入产出比"排序。

---

## 已完成（背景）

| 类别 | 工作 |
|---|---|
| **并发** | 单串行队列 → 每 view 串行 + 全局并发 `renderPool` |
| **时钟** | per-view `DispatchSourceTimer` → 全局 `TGSPlaybackCoordinator` + `CADisplayLink`，单 `CATransaction` 批量提交 |
| **内存** | `Data(count:)` 零填充 → 直接分配的 raw buffer + `Data(bytesNoCopy:)` |
| **图层** | silhouette / imageView 懒创建（长列表大量 cell 不必要的图层树成本归零） |
| **race-safety** | 锁保护的 generation token，cell 复用时丢弃过期工作 |
| **decode** | gzip 解码预 reserve capacity 减少 reallocation |
| **缓存（重头）** | XOR-delta + LZFSE 的 `.tgsc` 格式 + reader/writer + 后台 generator + `.cached` 模式端到端 wiring |

**当前热路径单帧成本对照：**

| 路径 | 单帧成本 | 是否触发 rlottie |
|---|---|---|
| `.direct` | ~2-5ms（rlottie renderSync） | 是 |
| `.cached`（命中） | **~50µs**（mmap + LZFSE + XOR） | 否 |
| `.cached`（首次） | 同 `.direct`，但后台异步写缓存 | 是（一次性） |

---

## P0：高收益、路径清晰

### 1. CVPixelBuffer Pool + IOSurface 直挂 `layer.contents`

**现状**：每帧 `Data` → `CGImage(provider:...)` → `layer.contents = cgImage`。Core Animation 把 CGImage 的像素**复制到 IOSurface**给 render server 上屏。

**改进**：rlottie / cached source 直接渲染进 IOSurface-backed `CVPixelBuffer`，`layer.contents = pixelBuffer`（或 `.takeRetainedValue()` 的 `IOSurface`）。零拷贝送到 GPU。配合 `CVPixelBufferPool` 跨帧复用 buffer，避免 malloc/free 抖动。

- **收益**：96×96 节省约 36KB/帧 的拷贝（~3µs），192×192 约 12µs。看起来不多，但 30 个视图 × 60fps = **5400 次/秒**，累计 CPU 节省可观。**真正大头是 GPU**：少一次 IOSurface 上传等于少一次 render server 的内存带宽消耗。
- **工作量**：中等（2-3 天）。需要：
  1. 在 `TGSAnimatedStickerCachedFrameSource` / `TGSAnimatedStickerDirectFrameSource` 之外加一个并行 API 走 `CVPixelBuffer`
  2. 一个 `TGSPixelBufferPool`（包 `CVPixelBufferPool` + LRU 退化为简单 fixed-size pool）
  3. `TGSPlayerView` 配置开关 `usesPixelBufferPool: Bool`
- **风险**：
  - rlottie 当前 API 把像素写进调用方传入的 buffer，需要确认它能写进 IOSurface-backed buffer 的 baseAddress（应该可以，IOSurface 给出连续 RGBA 内存）。
  - `CVPixelBufferPool` 的 buffer 数量需要调优——太少导致 frame queue 等 buffer，太多浪费内存。
  - 不同 `(width, height)` 不能共享 pool，长列表里出现混合尺寸时 pool 数量膨胀。
- **前置**：无。

---

### 2. 预生成 API（`prewarmCache`）

**现状**：第一次播缓存缺失时 fallback 到 direct，后台异步写 cache。但**第一次播**仍然慢。如果用户的使用场景是"我刚下载了 100 个贴纸，希望进表情面板就是 60fps"，那这条路径还不够。

**改进**：公开一个 API：

```swift
public extension TGSPlayerKit {
    /// Fire-and-forget background pre-generation. Returns immediately.
    static func prewarmCache(
        source: TGSAnimatedStickerSource,
        width: Int,
        height: Int,
        loader: TGSLottieAnimationLoading
    )
}
```

底层直接调 `TGSCachedFrameGenerator.shared.generate(...)`。App 在贴纸包下载完成时、或表情面板出现前 100ms 预热，第一次播就是 ~50µs/帧。

- **收益**：消除"第一次播慢"的体感问题。对 UX 影响大于纯性能数字。
- **工作量**：**低**（半天）。基础设施都在了，就是一个公开 API + 文档。
- **风险**：调用方滥用导致同时生成几百个 cache → CPU 烫手。**需要在 `TGSCachedFrameGenerator` 里加 max in-flight 限制**（目前是 serial queue，已经天然限流，但批量预热可能要一个"低优先级 + 可暂停"队列）。
- **前置**：无。

---

### 3. OSSignpost 仪器化

**现状**：性能问题靠猜。

**改进**：在关键路径插 `os_signpost`：

```swift
let signposter = OSSignposter(subsystem: "com.tgsplayerkit", category: "render")
let state = signposter.beginInterval("rlottie-render", id: id)
defer { signposter.endInterval("rlottie-render", state) }
```

埋点处：
- `rlottie::Animation::renderSync` 调用
- LZFSE decompress + XOR loop
- `TGSCachedFrameGenerator.runGeneration`
- 每 vsync `applyAllPendingCommits`（coordinator）
- 帧提交到 layer.contents

- **收益**：**不直接提速，但让后续每个优化决策有数据支撑**。Instruments 的 Points of Interest track 立刻可视化整条管线，瓶颈在哪一眼看清。
- **工作量**：**低**（半天）。
- **风险**：无。`os_signpost` 在没有捕获时是 nop。
- **前置**：无。

---

## P1：中等收益或更大工作量

### 4. FrameQueue length=2 双缓冲（隐藏 LZFSE 解码延迟）

**现状**：`TGSAnimatedStickerFrameQueue(length: 1, source: ...)`。每个 vsync 工作：拿当前帧 → 同步解码下一帧（这是 `generateFramesIfNeeded` 但 length=1 时其实不预取）。
代码里已经留了注释：
> `// With queue length 1 there is no next-frame prefetch; keep the call for when length grows.`

**改进**：把 length 改成 2，每次 take 后立即在 workQueue 上**预解码下一帧**。这样下一个 vsync 来时帧已经准备好，只剩 `layer.contents = ...`。

- **收益**：cached 模式下边际收益小（~50µs 已经很快），**direct 模式下显著**——能把 2-5ms 的 rlottie render 完全藏在前一帧的展示期间。对 `.direct` 长列表能改善 30%+ 的 worst-case 帧时间。
- **工作量**：中（1-2 天）。Coordinator 已经按 vsync 驱动，需要让"render"和"present"两阶段错开一帧。会改 `TGSPlaybackCoordinator.ViewEntry` 的 pending commit 模型。
- **风险**：
  - 帧延迟+1（用户看到的帧落后 vsync 一拍）。对 60fps 是 16.7ms 延迟，对 30fps sticker 是 33ms。可感知但很轻微。
  - First-frame eager 路径要避免双缓冲带来的多渲染一帧。
- **前置**：建议先做 P0.3（os_signpost）量化收益。

---

### 5. 磁盘缓存 LRU 清理

**现状**：缓存写进 `~/Library/Caches/TGSPlayerKit/cached-frames/` 后**永不清理**。iOS 会在存储压力下整目录 purge，但不可预测。

**改进**：`TGSCachedFrameDirectoryManager`：
- 启动时（或第一次访问 directory 时）扫描目录总大小
- 配置预算（默认 100MB）
- 超预算时按 `mtime`（或更精确的 `atime`）LRU 删除直到回到 80% 预算
- 删除过程在 background utility queue，不阻塞主线程

可选：`TGSPlayerConfiguration.cacheBudgetBytes: Int?`。

- **收益**：长期使用稳定性。不删的话用户存储被吃掉，iOS 突然 purge 会一次性删光，用户体验雪崩。
- **工作量**：中（1-2 天，加测试）。
- **风险**：扫描整个目录在贴纸量大（>1000）时 IO 成本。可缓存 manifest 文件记录 `(filename, size, lastAccess)`。
- **前置**：无。

---

### 6. 性能度量 API

**现状**：调用方不知道自己的 player 是否健康。

**改进**：
```swift
public struct TGSPerformanceMetrics {
    public let cacheHitRate: Double            // .cached 模式命中率
    public let avgDecodeTimeMs: Double         // 最近 N 帧
    public let droppedFrames: Int              // 累计跳过的帧数
    public let timeToFirstFrameMs: Double      // setup → 首帧上屏
}

extension TGSPlayerView {
    public var metrics: TGSPerformanceMetrics { ... }
}
```

可以全局也可以 per-view。Per-view 更有用：能定位"哪个贴纸在拖后腿"。

- **收益**：本身不提速，但帮助使用方和我们诊断真实场景问题。
- **工作量**：低-中（1 天）。
- **风险**：度量本身有成本，要确保关闭 metrics 时是 nop。
- **前置**：建议跟 P0.3 (os_signpost) 一起做。

---

### 7. ProMotion 自适应帧率 CADisplayLink

**现状**：`CADisplayLink` 默认按 native vsync（120Hz on ProMotion）触发。对 30fps 的 sticker 我们每两 vsync 才出一新帧，靠 `missedTicks` 跳帧逻辑处理。

**改进**：根据当前正在播放的 sticker 的真实 fps 设置 `preferredFrameRateRange`：

```swift
displayLink.preferredFrameRateRange = CAFrameRateRange(
    minimum: Float(targetFps),
    maximum: Float(targetFps),
    preferred: Float(targetFps)
)
```

当不同 fps 的 sticker 同屏时取 max（最高 fps 的那个驱动节奏，其余靠 skip 节流）。

- **收益**：ProMotion 设备上少 50% 的 vsync callback CPU。在 iPhone 15 Pro 长列表里直接体现为电池更耐用。
- **工作量**：低（半天）。
- **风险**：API 在 iOS 15+ 才稳定（`CAFrameRateRange`）。需要 `if #available` 分支。
- **前置**：无。

---

### 8. `.tgs` 内容 hash 进 cacheKey

**现状**：cacheKey 默认是文件 path。如果 path 上的文件**内容更新了**（贴纸 author 更新了动画），cache 还是旧的，永远不会刷新。

**改进**：两种方案：

**方案 A（保守）**：在 cache 文件 header 加 sourceHash（4-8 字节 .tgs 文件的 SHA256 前缀），reader 启动时比对，不匹配则视为无效，触发重写。

**方案 B（激进）**：把 .tgs 文件的内容 hash 拼进 cacheKey，不同内容自然落在不同 cache 文件。

A 简单但旧 cache 不会被清理（依赖 P1.5 LRU）；B 清爽但破坏"同 path 同 cache"的去重直觉。

- **收益**：避免"用户看到的是旧动画"的诡异 bug。
- **工作量**：低（A 半天，B 1 天）。
- **风险**：B 方案要求 source 在 cachedDataPath 时知道文件内容 hash → 需要先读一次文件计算 hash → 抵消了 cachedDataPath 的同步性。建议 A。
- **前置**：建议跟 P1.5 一起做。

---

### 9. 视觉回归测试 + 性能基准

**现状**：62 个单元测试覆盖功能正确性，但没有：
- "渲染 fixture .tgs，对比 direct 和 cached 像素完全一致"
- "rlottie 单帧渲染 us / cached 单帧解码 us / 长列表模拟 60s fps" 的基准

**改进**：
- `Tests/TGSPlayerKitVisualTests/` 加一个真实 `.tgs` fixture（用 Telegram 公开贴纸或自己做一个），对比 direct 和 cached 走通端到端
- `Tests/TGSPlayerKitBenchmarks/` 用 XCTPerformance 跑：
  - 单帧 cached 解码
  - 单帧 direct 渲染
  - 50 个 view × 5 秒滚动（模拟列表）

测试用 `measure(metrics: [...])` 跟踪 CPU + 内存。CI 上对比基线，回归直接 fail。

- **收益**：每个 PR 自动验证性能没退化。
- **工作量**：中-高（2-3 天，包括 fixture 准备和 CI 集成）。
- **风险**：性能基准在 CI runner 上不稳定（容器、热节流）。要用相对比例而不是绝对时间作为断言基准。
- **前置**：无。

---

## P2：锦上添花 / 投机性

### 10. Native Metal renderer

**现状**：`TGSNativeRendering` protocol 存在，但 `TGSUnavailableNativeRenderer` 是个占位。

**改进**：实现一个 Metal-based renderer，把 Lottie scene graph 转 GPU 指令（路径 → triangulate → vertex/fragment shader），跳过 CPU 栅格化。

- **收益**：对**高度动态、不可缓存**的 sticker（用户 live editing、变量驱动的 sticker）才有意义。对静态可缓存的 sticker，cached source 已经把 CPU 成本压到几乎为 0，Metal 不会更快。
- **工作量**：**高**（数周）。Lottie 的渲染模型（嵌套 mask、shape modifier、trim path、gradient）映射到 GPU 不简单。
- **风险**：实现复杂度极高，bug 多。可能跑不赢 rlottie + cached 组合。
- **前置**：先确认有真实需求。**当前优先级低**。

---

### 11. CALayer-only API（跳过 UIView）

**现状**：`TGSPlayerView: UIView`。每个 cell 一个 UIView，带来 hit-test、autolayout、accessibility 等开销。

**改进**：抽出 `TGSPlayerLayer: CALayer`，`TGSPlayerView` 只是个壳子持有 layer。需要纯渲染（不要交互、不要响应链）的用例直接用 layer。

- **收益**：每个 cell 约几 KB 内存 + UIView 注册/注销时的少量 CPU。长列表里有意义。
- **工作量**：中（2 天）。要重构现在的 UIView 上挂的 silhouette/imageView。
- **风险**：API 表面翻倍，文档/测试也要翻倍。
- **前置**：先用 Instruments 看看 UIView overhead 是否真的是 hotspot。

---

### 12. 远程 source + 网络缓存

**现状**：`TGSAnimatedStickerLocalFileSource` 只能本地文件。

**改进**：`TGSAnimatedStickerRemoteSource`：
- HTTP fetch `.tgs` → 写到 `~/Library/Caches/TGSPlayerKit/tgs-blobs/` → 之后等同 local
- 304 Not Modified / ETag 支持
- 下载失败的指数退避

- **收益**：开箱即用。
- **工作量**：中-高（3-5 天）。HTTP 缓存语义、并发下载、disk LRU 都要处理。
- **风险**：与具体业务的 CDN / auth 模型耦合。可能更适合**让调用方自己实现** TGSAnimatedStickerSource，我们只提供示例。
- **前置**：业务真实需求驱动。

---

### 13. 流式解码

**现状**：`.tgs` 文件下载完成后才开始解码 + 渲染。

**改进**：流式 gzip → 流式 JSON parser → 边接收边解析 → 第一个 keyframe 到达就可以渲染。

- **收益**：网络慢时减少"等待白屏"时间。
- **工作量**：**高**。需要替换 `JSONSerialization`、写一个 streaming JSON parser、改 rlottie 的接口（rlottie 假设输入是完整 JSON）。
- **风险**：rlottie 不支持流式输入是硬限制。
- **前置**：跟 #12 一起做才有意义。

---

### 14. `madvise(WILLNEED)` prefetch

**现状**：cache 文件 mmap'd，frame 数据按需 page-fault 拉入物理内存。

**改进**：每次 takeFrame 后，对**下一帧的字节区间**调用 `madvise(WILLNEED)`，让内核预读那几个 page。

- **收益**：纯磁盘 IO 优化。SSD 已经很快，**iOS 上几乎看不出差别**（实际 cache 文件小于一个 page，大部分情况已经全在内存）。
- **工作量**：低（半天）。
- **风险**：iOS 对 `madvise` 的支持有限，可能是 nop。
- **前置**：建议跳过，除非看到 cache 文件 page fault 是热点。

---

### 15. 共享 rlottie LottieInstance / model cache

**现状**：rlottie 内部的 `LOTModelCache` 默认开启，按文件路径/JSON 缓存解析后的 model。我们之前尝试过共享 `LottieInstance` 但回滚了（实例有可变渲染状态，跨 view 不安全）。

**改进**：验证 rlottie LOTModelCache 在我们使用模式下是否命中（同 cacheKey 多次 load 是否只解析一次 JSON）。如果没命中，在 Swift 侧加一个轻 wrapper：缓存 `(cacheKey → parsed JSON Data)`，N 个 view load 同一 sticker 时省 N-1 次 gzip + JSON 解析。

- **收益**：长列表初始化时间减少。N=30 个相同 sticker view 时，从 30 次 gzip+parse 降到 1 次。
- **工作量**：低-中（1 天，含验证 rlottie 内部 cache）。
- **风险**：rlottie 的 cache 行为版本相关，要验证版本。
- **前置**：用 Instruments 看是否真的有重复 parse。

---

## 测试与度量

### 16. 长跑稳定性测试

- `XCUITest` 脚本：100 个 view 的列表，连续滚动 60 秒
- 监控：fps（>55 阈值）、内存增长（应趋于稳定）、CPU thermal state、无 crash
- CI 上 nightly run

### 17. 端到端真实 `.tgs` fixture

- 选 3-5 个代表性 `.tgs`（简单/复杂/超大）放进 `Tests/Fixtures/`
- 跑 direct → cache → reload → compare pixel-perfect

---

## 文档

### 18. 集成方性能指南

写一篇 `docs/integration-guide.md`：
- "总是用 `.cached` 模式"
- "贴纸下载完即调用 `prewarmCache`"
- "配置 `cacheBudgetBytes`"
- "调试 fps 用 `metrics.droppedFrames` 或 Instruments + os_signpost"

### 19. Telegram AnimatedStickerNode 迁移指南

API 对照表 + 行为差异说明，便于现有 Telegram-iOS 用户切换。

---

## 优先级建议

如果只能再做 3 件事：

1. **#3 OSSignpost** —— 不是真正的优化，但能让后续每个决定有数据支撑。**先做这个**。
2. **#1 CVPixelBuffer + IOSurface** —— 当前管线唯一剩下的"每帧像素拷贝"路径。
3. **#2 prewarmCache** —— 改变首次播体感，工作量极小。

如果时间充裕，再做 #5（LRU 清理）和 #9（性能基准）—— 这两个是生产稳定性的基础。

剩下的 P2 都属于"等遇到问题再做"的范畴。

---

## 不建议做（投入产出比差）

- **重写 rlottie**：项目当前用 rlottie 的部分已经被 `.cached` 模式绕过了大部分热路径，重写 ROI 极低。
- **Metal 全自研渲染**：见 #10。
- **GPU 上做 LZFSE**：LZFSE 是 CPU 字节流算法，GPU 上效率反而差。
- **缩小 cache 文件格式**：目前 LZFSE + XOR delta 已经接近"压缩极限"，再压只能换更慢的算法。

---

*最后更新：2026-05-26（commit `97ca26b`，`.cached` 模式端到端 wiring 完成后）*

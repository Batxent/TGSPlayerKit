# TGSPlayerKit Performance Roadmap

This document tracks further performance work for TGSPlayerKit **after the main optimizations are in place**.
Each item notes **expected benefit**, **effort**, **risk**, and **prerequisites**, ordered by return on effort.

---

## Done (context)

| Area | Work |
|---|---|
| **Concurrency** | Single serial queue → per-view serial + global concurrent `renderPool` |
| **Clocking** | Per-view `DispatchSourceTimer` → global `TGSPlaybackCoordinator` + `CADisplayLink`, batched commits in one `CATransaction` |
| **Memory** | `Data(count:)` zero-fill → raw buffer + `Data(bytesNoCopy:)` |
| **Layers** | Lazy silhouette / imageView (long lists: avoid unnecessary layer-tree cost in many cells) |
| **Race safety** | Lock-protected generation token; stale work dropped on cell reuse |
| **Decode** | gzip decode pre-reserves capacity to cut reallocations |
| **Caching (major)** | XOR-delta + LZFSE `.tgsc` format + reader/writer + background generator + end-to-end `.cached` wiring |

**Current hot-path per-frame cost:**

| Path | Per-frame cost | rlottie invoked? |
|---|---|---|
| `.direct` | ~2–5 ms (rlottie `renderSync`) | Yes |
| `.cached` (hit) | **~50 µs** (mmap + LZFSE + XOR) | No |
| `.cached` (first play) | Same as `.direct`, cache written async in background | Yes (one-time) |

---

## P0: High payoff, clear path

### 1. CVPixelBuffer pool + IOSurface directly on `layer.contents`

**Today:** Each frame `Data` → `CGImage(provider:...)` → `layer.contents = cgImage`. Core Animation **copies** CGImage pixels **into an IOSurface** for the render server.

**Change:** Render rlottie / cached sources straight into IOSurface-backed `CVPixelBuffer`, set `layer.contents = pixelBuffer` (or retained `IOSurface`). Zero-copy path to the GPU. Pair with `CVPixelBufferPool` to reuse buffers across frames and avoid malloc/free churn.

- **Benefit:** At 96×96 save ~36 KB/frame copy (~3 µs); at 192×192 ~12 µs. Small per frame, but 30 views × 60 fps = **5400 ops/s**, meaningful CPU savings. **The bigger win is GPU:** one fewer IOSurface upload means less memory bandwidth on the render server.
- **Effort:** Medium (2–3 days). Needs:
  1. A parallel API on top of `TGSAnimatedStickerCachedFrameSource` / `TGSAnimatedStickerDirectFrameSource` using `CVPixelBuffer`
  2. `TGSPixelBufferPool` (wrap `CVPixelBufferPool` + simple fixed-size pool instead of heavy LRU)
  3. `TGSPlayerView` flag `usesPixelBufferPool: Bool`
- **Risk:**
  - rlottie writes into caller-provided buffers; confirm IOSurface-backed `baseAddress` works (likely yes—contiguous RGBA).
  - Pool size tuning—too few buffers stall the frame queue; too many waste memory.
  - Mixed `(width, height)` cannot share one pool; long lists with mixed sizes multiply pools.
- **Prerequisites:** None.

---

### 2. Pregeneration API (`prewarmCache`)

**Today:** On first play with a cache miss we fall back to direct and write cache in the background, but **first play** is still slow. If the scenario is “I just downloaded 100 stickers and want 60 fps in the panel,” this is not enough.

**Change:** Public API:

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

Calls `TGSCachedFrameGenerator.shared.generate(...)` underneath. App warms after pack download or ~100 ms before the panel appears; first play becomes ~50 µs/frame.

- **Benefit:** Removes “first play feels slow.” UX impact beats raw numbers.
- **Effort:** **Low** (half day). Infra exists; it is a public API + docs.
- **Risk:** Abuse (hundreds of concurrent generations) heats CPU. **Add max in-flight in `TGSCachedFrameGenerator`** (serial queue already throttles; bulk prewarm may need a low-priority, pausable queue).
- **Prerequisites:** None.

---

### 3. OSSignpost instrumentation

**Today:** Performance work is guesswork.

**Change:** Add `os_signpost` on critical paths:

```swift
let signposter = OSSignposter(subsystem: "com.tgsplayerkit", category: "render")
let state = signposter.beginInterval("rlottie-render", id: id)
defer { signposter.endInterval("rlottie-render", state) }
```

Places to instrument:
- `rlottie::Animation::renderSync`
- LZFSE decompress + XOR loop
- `TGSCachedFrameGenerator.runGeneration`
- Each vsync `applyAllPendingCommits` (coordinator)
- Frame commit to `layer.contents`

- **Benefit:** **Does not speed up code directly, but backs every later decision with data.** Instruments Points of Interest shows the full pipeline at a glance.
- **Effort:** **Low** (half day).
- **Risk:** None—`os_signpost` is a no-op when not recording.
- **Prerequisites:** None.

---

## P1: Medium payoff or larger effort

### 4. FrameQueue length=2 double buffering (hide LZFSE decode latency)

**Today:** `TGSAnimatedStickerFrameQueue(length: 1, source: ...)`. Each vsync: take current frame → synchronously decode next (`generateFramesIfNeeded`; with length 1 there is effectively no prefetch).
Existing comment:
> `// With queue length 1 there is no next-frame prefetch; keep the call for when length grows.`

**Change:** Set length to 2; after each take, **prefetch the next frame** on the work queue so the next vsync only assigns `layer.contents`.

- **Benefit:** Small marginal gain for cached (~50 µs already fast); **large for direct**—hide 2–5 ms rlottie inside the previous frame’s display window. Can improve worst-case frame time 30%+ for `.direct` long lists.
- **Effort:** Medium (1–2 days). Coordinator is vsync-driven; render vs present must slip by one frame; updates `TGSPlaybackCoordinator.ViewEntry` pending-commit model.
- **Risk:**
  - +1 frame latency (one tick behind vsync). ~16.7 ms at 60 fps, ~33 ms at 30 fps sticker—slight but noticeable.
  - First-frame eager path must avoid an extra render from double buffering.
- **Prerequisites:** Prefer P0.3 (os_signpost) first to quantify.

---

### 5. On-disk cache LRU eviction

**Today:** Caches under `~/Library/Caches/TGSPlayerKit/cached-frames/` **never** shrink. iOS may purge the whole directory under pressure—unpredictable.

**Change:** `TGSCachedFrameDirectoryManager`:
- On launch (or first directory access) scan total size
- Configurable budget (default 100 MB)
- When over budget, LRU by `mtime` (or finer `atime`) until back to 80% of budget
- Deletes on a background utility queue, not main thread

Optional: `TGSPlayerConfiguration.cacheBudgetBytes: Int?`.

- **Benefit:** Long-term stability; without eviction users lose disk space; sudden iOS purge is a bad UX cliff.
- **Effort:** Medium (1–2 days + tests).
- **Risk:** Full-directory scan I/O when sticker count is huge (>1000). Optional manifest `(filename, size, lastAccess)`.
- **Prerequisites:** None.

---

### 6. Performance metrics API

**Today:** Integrators cannot tell if a player is healthy.

**Change:**
```swift
public struct TGSPerformanceMetrics {
    public let cacheHitRate: Double            // `.cached` hit rate
    public let avgDecodeTimeMs: Double         // last N frames
    public let droppedFrames: Int              // cumulative skipped frames
    public let timeToFirstFrameMs: Double      // setup → first frame on screen
}

extension TGSPlayerView {
    public var metrics: TGSPerformanceMetrics { ... }
}
```

Global or per-view; per-view helps find “which sticker is slow.”

- **Benefit:** Does not speed up code, but helps integrators and us diagnose real scenarios.
- **Effort:** Low–medium (1 day).
- **Risk:** Metrics have cost; ensure disabled path is a no-op.
- **Prerequisites:** Best paired with P0.3 (os_signpost).

---

### 7. ProMotion-aware `CADisplayLink` frame rate

**Today:** `CADisplayLink` fires at native vsync (120 Hz on ProMotion). For 30 fps stickers we emit a new frame every other vsync via `missedTicks` skipping.

**Change:** Set `preferredFrameRateRange` from the sticker’s real fps:

```swift
displayLink.preferredFrameRateRange = CAFrameRateRange(
    minimum: Float(targetFps),
    maximum: Float(targetFps),
    preferred: Float(targetFps)
)
```

When multiple fps values are on screen, use max (highest fps drives; others skip).

- **Benefit:** ~50% fewer vsync callbacks on ProMotion—better battery on e.g. iPhone 15 Pro long lists.
- **Effort:** Low (half day).
- **Risk:** `CAFrameRateRange` needs `if #available` (stable iOS 15+).
- **Prerequisites:** None.

---

### 8. Put `.tgs` content hash into cacheKey

**Today:** cacheKey defaults to file path. If **file contents change** at that path (author updates animation), cache stays stale forever.

**Change:** Two options:

**Option A (conservative):** Add `sourceHash` (4–8 byte SHA256 prefix of `.tgs`) in cache header; reader invalidates and rewrites on mismatch.

**Option B (aggressive):** Append content hash to cacheKey so different contents get different cache files.

A is simple but old caches linger until P1.5 LRU; B is clean but breaks “same path → same cache” intuition.

- **Benefit:** Avoids “user still sees old animation” bugs.
- **Effort:** Low (A: half day; B: 1 day).
- **Risk:** B needs content hash when using `cachedDataPath` → extra read → hurts sync story. Prefer A.
- **Prerequisites:** Best with P1.5.

---

### 9. Visual regression + performance baselines

**Today:** 62 unit tests cover correctness, but not:
- “Render fixture `.tgs`; direct vs cached pixels match exactly”
- Benchmarks for “rlottie per-frame µs / cached decode µs / 60 s simulated list scroll fps”

**Benchmark plan:** Three-tier plan reviewed and documented in
[`docs/performance/benchmark-plan.md`](docs/performance/benchmark-plan.md):
Tier A = TGSPlayerKit micro-benchmarks; Tier B = Hawa signposts; Tier C = deferred scripted scenarios.

**Change:**
- `Tests/TGSPlayerKitVisualTests/` with a real `.tgs` fixture (Telegram public pack or custom), end-to-end direct vs cached pixel compare
- `Tests/TGSPlayerKitBenchmarks/` with XCTest performance:
  - Single-frame cached decode
  - Single-frame direct render
  - 50 views × 5 s scroll (list simulation)

Use `measure(metrics: [...])` for CPU + memory; CI compares baselines and fails on regression.

- **Benefit:** Every PR catches performance regressions automatically.
- **Effort:** Medium–high (2–3 days incl. fixtures + CI).
- **Risk:** CI runners are noisy (containers, thermal). Gate on ratios, not absolute times.
- **Prerequisites:** None.

---

## P2: Nice-to-have / speculative

### 10. Native Metal renderer

**Today:** `TGSNativeRendering` exists; `TGSUnavailableNativeRenderer` is a stub.

**Change:** Metal renderer translating Lottie scene graph to GPU work (paths → triangulate → shaders), skipping CPU rasterization.

- **Benefit:** Only for **highly dynamic, uncacheable** stickers (live editing, variable-driven). For static cacheable stickers, cached source already drives CPU near zero; Metal will not beat it.
- **Effort:** **High** (weeks). Masks, modifiers, trim paths, gradients are hard on GPU.
- **Risk:** Very complex, bug-prone; may still lose to rlottie + cached.
- **Prerequisites:** Confirm real product need. **Low priority today.**

---

### 11. CALayer-only API (skip `UIView`)

**Today:** `TGSPlayerView` is a `UIView` per cell—hit testing, Auto Layout, accessibility overhead.

**Change:** Extract `TGSPlayerLayer: CALayer`; `TGSPlayerView` becomes a thin shell. Pure rendering (no interaction, no responder chain) uses the layer directly.

- **Benefit:** A few KB per cell + small UIView registration CPU; matters in long lists.
- **Effort:** Medium (~2 days); refactor silhouette/imageView on `UIView`.
- **Risk:** API surface doubles; docs/tests double.
- **Prerequisites:** Confirm UIView overhead is a hotspot in Instruments.

---

### 12. Remote source + HTTP cache

**Today:** `TGSAnimatedStickerLocalFileSource` is local files only.

**Change:** `TGSAnimatedStickerRemoteSource`:
- HTTP fetch `.tgs` → `~/Library/Caches/TGSPlayerKit/tgs-blobs/` → then same as local
- 304 / ETag
- Exponential backoff on failure

- **Benefit:** Batteries-included remote loading.
- **Effort:** Medium–high (3–5 days): HTTP semantics, concurrent downloads, disk LRU.
- **Risk:** Couples to CDN/auth per app; often better to **let integrators implement** `TGSAnimatedStickerSource` and ship an example.
- **Prerequisites:** Driven by product need.

---

### 13. Streaming decode

**Today:** Decode + render start only after `.tgs` download completes.

**Change:** Streaming gzip → streaming JSON → parse while receiving → render at first keyframe.

- **Benefit:** Less “white screen wait” on slow networks.
- **Effort:** **High**: replace `JSONSerialization`, build streaming parser, change rlottie contract (expects full JSON).
- **Risk:** rlottie cannot stream input—hard limit.
- **Prerequisites:** Pair with #12 if pursued.

---

### 14. `madvise(WILLNEED)` prefetch

**Today:** Cache file is mmap’d; frame bytes fault in on demand.

**Change:** After each `takeFrame`, `madvise(WILLNEED)` on the **next frame’s byte range**.

- **Benefit:** Pure disk I/O tweak. SSDs are fast; **hard to see on iOS** (small cache files often fit in one page already).
- **Effort:** Low (half day).
- **Risk:** `madvise` may be a no-op on iOS.
- **Prerequisites:** Skip unless page faults show up as a hotspot.

---

### 15. Shared rlottie `LottieInstance` / model cache

**Today:** rlottie’s `LOTModelCache` is on by default (path/JSON keyed). We tried sharing `LottieInstance` and rolled back (mutable render state—not safe across views).

**Change:** Verify `LOTModelCache` hits for our usage (same cacheKey loads parse JSON once). If not, a thin Swift cache `(cacheKey → parsed JSON Data)` so N views for one sticker pay one gzip+parse.

- **Benefit:** Faster list init; N=30 identical views drop from 30× parse to 1×.
- **Effort:** Low–medium (1 day + rlottie verification).
- **Risk:** Cache behavior varies by rlottie version.
- **Prerequisites:** Instruments to confirm duplicate parse is real.

---

## Testing and measurement

### 16. Long-run stability test

- `XCUITest`: list of 100 views, scroll 60 s continuously
- Watch: fps (>55 threshold), memory plateau, CPU thermal state, no crashes
- Nightly on CI

### 17. End-to-end real `.tgs` fixtures

- Pick 3–5 representative `.tgs` (simple / complex / large) under `Tests/Fixtures/`
- Run direct → cache → reload → pixel-perfect compare

---

## Documentation

### 18. Integrator performance guide

Add `docs/integration-guide.md`:
- “Prefer `.cached` mode”
- “Call `prewarmCache` after sticker download”
- “Configure `cacheBudgetBytes`”
- “Debug fps with `metrics.droppedFrames` or Instruments + os_signpost”

### 19. Telegram `AnimatedStickerNode` migration guide

API mapping + behavior differences for Telegram-iOS adopters.

---

## Priority guidance

If only three more things ship:

1. **#3 OSSignpost** — not a speedup, but data for every later call. **Do this first.**
2. **#1 CVPixelBuffer + IOSurface** — last major “per-frame pixel copy” in the pipeline.
3. **#2 prewarmCache** — fixes first-play feel for minimal effort.

If time remains, add #5 (LRU eviction) and #9 (benchmarks)—production stability foundations.

Remaining P2 is “when pain appears.”

---

## Not recommended (poor ROI)

- **Rewrite rlottie:** `.cached` already bypasses most hot paths; rewrite ROI is tiny.
- **Full custom Metal renderer:** see #10.
- **LZFSE on GPU:** LZFSE is a CPU byte-stream codec; GPU would be worse.
- **Shrink cache format further:** LZFSE + XOR delta is already near practical limits; more compression means slower codecs.

---

*Last updated: 2026-05-26 (commit `97ca26b`, after `.cached` end-to-end wiring landed)*

# TGSPlayerKit Benchmark Plan

> Status: reviewed proposal. This document records the layered benchmark strategy after P0/P1 performance work, and constraints that must be confirmed before each layer ships.

## Goals

The benchmark system must answer three questions separately; do not mix signals in one metric:

1. Inside TGSPlayerKit: how much faster `.cached` is than `.direct`, and per-frame cost vs cache generation cost separately.
2. Hawa app hot paths: whether main-thread wall time and frame drops improve for panel open, cell bind, sending stickers, and public chat scrolling.
3. PR regression: whether the next commit can produce a stable baseline diff, e.g. `+5%` or `-10%`.

The plan therefore splits into three tiers. Each tier can be implemented, run, and adopted independently.

## Review conclusions

The three-tier split is correct, but these assumptions must be corrected before the original proposal lands:

| Topic | Review | Decision |
|---|---|---|
| Native benchmark path | Default `Package.swift` is core-only and does not expose `TGSPlayerKitRLottie` or `TGSPlayerKitRLottieNative`. A true rlottie `.direct` benchmark cannot run with default `swift test` alone. | Tier A must first define a native-enabled execution path: benchmark-specific manifest, Xcode scheme, or local manifest switch via binary template. |
| `swift test` output | `swift test` is fine for local smoke checks, but for structured measurement JSON in CI, prefer `xcodebuild test` producing `.xcresult`. | Document both modes: `swift test` for quick stdout during development; `xcodebuild test -resultBundlePath` for baseline collection. |
| Fixture licensing | Pulling one file from a public Telegram sticker pack does not mean it can be vendored in the repo. | `sample.tgs` must be self-made, explicitly licensed, or carry a clear open license, with provenance in `NOTICE` or a fixture license file. |
| Memory metric | `XCTMemoryMetric` is useful, but absolute memory on shared runners is noisy. | Initially observe memory only; do not gate CI on absolute memory thresholds; prefer gating cached/direct ratio and wall-time regression. |
| Hawa signpost | Hawa file paths and business selectors are not in this repo. | Tier B is an integration plan for the Hawa iOS repo; it does not block TGSPlayerKit micro-benchmarks. |
| Tier C automation | Full scenario automation needs real devices, stable scenario entry points, and trace parsing. | Defer Tier C until Tier A metric names and Tier B signpost names stabilize. |

## Tier A: TGSPlayerKit micro-benchmarks

### Purpose

Measure TGSPlayerKit algorithm cost only, without Hawa UI, UIKit scrolling, or business state:

- `.direct` rlottie per-frame render;
- `.cached` hit per-frame decode;
- `.tgsc` cache generation;
- mmap cold start plus first frame.

This tier should be as deterministic as possible: good for local repeats and for CI to publish non-blocking benchmark artifacts.

### Prerequisites

- One real `.tgs` fixture, about 30–50 frames, ideally under 30 KB on disk.
- Fixture provenance must be auditable:
  - Preferred: self-made fixture shipped under the project license;
  - Acceptable: external open-license fixture with license and attribution;
  - Not acceptable: unclearly licensed public pack art.
- Native rlottie available:
  - Default `Package.swift` alone is not enough;
  - Benchmark runs must explicitly enable `TGSPlayerKitRLottie` and the native xcframework.

### Suggested layout

```text
Tests/TGSPlayerKitBenchmarks/
  Fixtures/
    sample.tgs
    sample.tgs.license.md
  DirectFrameDecodeBenchmark.swift
  CachedFrameDecodeBenchmark.swift
  CacheGenerationBenchmark.swift
  CacheMmapColdStartBenchmark.swift
  BenchmarkFixture.swift
```

Only wire the benchmark test target into the manifest after the native artifact path is fixed. If the default manifest stays core-only, do not force every contributor to build C++/rlottie for `swift test`; benchmarks can use a dedicated manifest or Xcode scheme.

### What to measure

| Suite | Measures | Answers | Initial target |
|---|---|---|---|
| `DirectFrameDecodeBenchmark` | 1000× `TGSAnimatedStickerDirectFrameSource.takeFrame(draw: true)` under native rlottie | How expensive direct is per frame | Baseline ~2–5 ms/frame |
| `CachedFrameDecodeBenchmark` | 1000× `TGSAnimatedStickerCachedFrameSource.takeFrame(draw: true)` from a prebuilt `.tgsc` | How cheap cached hits are | Aim ≤100 µs/frame |
| `CacheGenerationBenchmark` | Full `TGSAnimatedStickerCacheWriter.write(source:to:)` on a 240×240 fixture | How expensive first cache build is | ~30 frames under 300 ms |
| `CacheMmapColdStartBenchmark` | `TGSAnimatedStickerCachedFrameSource(cachePath:)` init plus first frame | Whether mmap + first frame fits UI-visible budget | Under 5 ms |
| `CachedVsDirectMemoryBenchmark` | `XCTMemoryMetric` on direct vs cached paths | Whether cached saves memory meaningfully | Observe only; no absolute threshold gate yet |

### Execution modes

Developer smoke mode:

```bash
swift test --filter TGSPlayerKitBenchmarks
```

This command is valid only once the benchmark target has a native-enabled package path. It is useful for quick stdout, not the sole source for structured baselines.

Structured collection mode:

```bash
xcodebuild test \
  -scheme TGSPlayerKitBenchmarks \
  -destination 'platform=macOS' \
  -resultBundlePath .build/perf/TGSPlayerKitBenchmarks.xcresult
```

Prefer this when you need baseline diffs, because `.xcresult` can be parsed to measurement JSON with `xcresulttool`.

### CI strategy

Phase 1: publish benchmarks only; do not block PRs:

- Pin macOS runner type;
- Export metric JSON as a CI artifact;
- Compare each suite’s median and cached/direct ratio against the latest baseline;
- Warning only at first; no fail gates.

After several stable rounds, add gates. Prefer relative gates, not cross-machine absolute time:

- Cached per-frame at least 10× faster than direct;
- Cache cold start regresses no more than 10% vs same-runner baseline;
- Cache generation regresses no more than 15% vs same-runner baseline.

## Tier B: Hawa hot-path signposts

### Purpose

Measure real business paths in Instruments instead of eyeballing. This tier belongs in the Hawa iOS repo because files, selectors, and scenario entry points are app-owned.

### Central registry

Add in the Hawa iOS repo:

```swift
@objcMembers
public final class HAPerfSignpost {
    public static let stickerPanel = OSLog(subsystem: "com.hawa.perf", category: "sticker-panel")
    public static let publicChat = OSLog(subsystem: "com.hawa.perf", category: "public-chat")
    public static let stickerSend = OSLog(subsystem: "com.hawa.perf", category: "sticker-send")
    public static let tgsRender = OSLog(subsystem: "com.hawa.perf", category: "tgs-render")
}
```

Implement with `#if DEBUG` for real signposts and a no-op stub in Release so production does not pay extra call cost.

### Instrumented spans

| Span | Start | End | Maps to optimization |
|---|---|---|---|
| `panel.open` | Enter `startEditTextWithStickerPanelFromEntryEmoji` | First sticker cell first frame | Cached + hot-cache prewarm |
| `cell.bind.sticker` | Enter `HAPublicStickerMessageCell.setMessage` | Method return | Hot-cache + active-player pause |
| `sticker.send.tap_to_input_reset` | Sticker tap or `sendCurrentText` | Optimistic input reset done | Optimistic send reset |
| `sticker.send.tap_to_fly_start` | Sticker tap | `runPublicStickerSendAnimation...` liftoff | Event-driven fly animation |
| `tgs.first_frame` | `TGSPlayerView.setup` | `tgsPlayerViewDidLoadFirstFrame` | Cached hit/miss first frame |
| `chat.scroll.session` | `scrollViewWillBeginDragging` | `scrollViewDidEndDecelerating` | Active player count and scroll hitches |

### Instruments template

Suggested path in the Hawa iOS repo:

```text
tools/perf-bench/HawaPerf.tracetemplate
```

The template should include:

- `os_signpost` / Points of Interest;
- Time Profiler;
- Hitches;
- Animation Hitches.

Manual test flow: install a DEBUG build on device, record the same gestures, then compare p50/p95 per signpost span in the trace.

## Tier C: scripted scenario regression

### Purpose

Turn “open panel 20 times / scroll 200 sticker messages / burst-send 10 stickers” into one command that records a trace and outputs a baseline diff.

### Defer until

Do not implement Tier C until:

- Tier A suite names and JSON output are stable;
- Tier B signpost names are stable;
- Hawa exposes a deterministic scenario entry, e.g. `-HAPerfScenario panel-open`, or a confirmed on-device UI-driver path.

### Suggested shape

```text
tools/perf-bench/
  record-hawa-scenario.swift
  parse-trace.py
  baseline.json
  reports/
```

A Swift CLI can call `xctrace record --template HawaPerf --time-limit 20s`. A parser script turns trace into CSV and diffs against `baseline.json`.

This tier is not in the first wave: Hawa SDK and device-only dependencies make simulator automation unreliable.

## Recommended rollout order

1. Tier A first, but only after native benchmark path and `sample.tgs` licensing are settled.
2. Tier B in the Hawa iOS repo so on-device manual runs yield p50/p95 trace data.
3. Defer Tier C until scenarios, signpost names, and on-device automation entry are stable.

## Open items

| Item | Owner | Blocks |
|---|---|---|
| Choose and license `sample.tgs` | TGSPlayerKit maintainer | Tier A |
| Decide native benchmark execution path | TGSPlayerKit maintainer | Tier A |
| Benchmarks: warning-only vs CI gate | TGSPlayerKit maintainer | Tier A CI |
| Confirm Hawa signpost file paths and selectors | Hawa iOS maintainer | Tier B |
| Provide Hawa scenario entry or UI-driver path | Hawa iOS maintainer | Tier C |

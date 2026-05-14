# TGSPlayerKit Open Source Baseline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the current design note into a credible Swift Package repository for a Telegram iOS compatible UIKit TGS player powered by a future rlottie native backend.

**Architecture:** The first implementation follows Telegram iOS animated sticker structure while replacing Texture nodes with UIKit views/layers. Tests cover decoding limits, Telegram-compatible playback modes, visibility gating, length-1 frame queue prefetching, LRU eviction, source identity, and player state transitions so native integration can be added without changing public API.

**Tech Stack:** Swift Package Manager, Swift 5.9, UIKit, Foundation, XCTest, GitHub Actions.

---

## File Map

- Create `Package.swift`: SwiftPM manifest for `TGSPlayerKit` and tests.
- Create `Sources/TGSPlayerKit/*.swift`: Telegram-compatible public API, frame source/frame queue/cache/decoder, UIKit view, native renderer protocol.
- Create `Tests/TGSPlayerKitTests/*.swift`: behavior tests for core logic and view state.
- Create `.github/workflows/ci.yml`: macOS SwiftPM test workflow.
- Create `README.md`, `LICENSE`, `NOTICE`, `CONTRIBUTING.md`, `SECURITY.md`, `.gitignore`: open-source repo surface.
- Keep `rlottie-tgs-player-design.md`: design document remains as technical context.

## Task 1: Package and Public API

**Files:**
- Create: `Package.swift`
- Create: `Sources/TGSPlayerKit/TGSSource.swift`
- Create: `Sources/TGSPlayerKit/TGSPlayerConfiguration.swift`
- Create: `Sources/TGSPlayerKit/TGSPlayerError.swift`
- Test: `Tests/TGSPlayerKitTests/TGSSourceTests.swift`

- [ ] **Step 1: Write source identity tests**

```swift
func testDataSourceUsesExplicitCacheKey() {
    let source = TGSSource.data(Data([0x1f, 0x8b]), cacheKey: "sticker/wave")
    XCTAssertEqual(source.cacheKey, "sticker/wave")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TGSSourceTests`
Expected: fail because `TGSSource` is not defined.

- [ ] **Step 3: Implement the minimal public types**

Define `TGSSource`, `TGSPlayerConfiguration`, `TGSAnimatedStickerPlaybackMode`, `TGSAnimatedStickerMode`, `TGSPlayerError`.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TGSSourceTests`
Expected: pass.

## Task 2: Decoder and Limits

**Files:**
- Create: `Sources/TGSPlayerKit/TGSDecoder.swift`
- Test: `Tests/TGSPlayerKitTests/TGSDecoderTests.swift`

- [ ] **Step 1: Write decoder tests**

```swift
func testPlainJSONIsAcceptedForFixtureAndPreviewUse() throws {
    let data = #"{"v":"5.7.4","w":512,"h":512,"fr":60,"op":180}"#.data(using: .utf8)!
    let decoder = TGSDecoder()
    let json = try decoder.decode(data)
    XCTAssertTrue(String(decoding: json, as: UTF8.self).contains(#""w":512"#))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TGSDecoderTests`
Expected: fail because `TGSDecoder` is not defined.

- [ ] **Step 3: Implement decoder limits**

Accept plain JSON for tests and debug fixtures, reject oversized compressed or decoded payloads, and return `gzipDecodeFailed` for unknown binary data. Leave gzip expansion behind a small internal method so native zlib integration can replace it later.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TGSDecoderTests`
Expected: pass.

## Task 3: Cache and Telegram Frame Queue

**Files:**
- Create: `Sources/TGSPlayerKit/TGSFrameCache.swift`
- Create: `Sources/TGSPlayerKit/TGSAnimatedStickerTypes.swift`
- Test: `Tests/TGSPlayerKitTests/TGSFrameCacheTests.swift`
- Test: `Tests/TGSPlayerKitTests/TelegramCompatibilityTests.swift`

- [ ] **Step 1: Write eviction and frame-mapping tests**

```swift
func testFrameCacheEvictsLeastRecentlyUsedEntryWhenByteLimitIsExceeded() {
    let cache = TGSFrameCache(byteLimit: 8)
    cache.insert(Data(repeating: 1, count: 4), for: TGSFrameCache.Key(cacheKey: "a", frameIndex: 0, pixelSize: .init(width: 1, height: 1)))
    cache.insert(Data(repeating: 2, count: 8), for: TGSFrameCache.Key(cacheKey: "b", frameIndex: 0, pixelSize: .init(width: 1, height: 2)))
    XCTAssertNil(cache.value(for: TGSFrameCache.Key(cacheKey: "a", frameIndex: 0, pixelSize: .init(width: 1, height: 1))))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TGSFrameCacheTests`
Expected: fail because `TGSFrameCache` is not defined.

- [ ] **Step 3: Implement cache, playback modes, visibility gate, and frame queue**

Add byte-counted LRU storage plus Telegram-compatible playback mode enums, visibility gate, and `TGSAnimatedStickerFrameQueue(length: 1)`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TGSFrameCacheTests && swift test --filter TelegramCompatibilityTests`
Expected: pass.

## Task 4: UIKit Player Scaffold

**Files:**
- Create: `Sources/TGSPlayerKit/TGSPlayerView.swift`
- Create: `Sources/TGSPlayerKit/TGSNativeRenderer.swift`
- Test: `Tests/TGSPlayerKitTests/TGSPlayerViewTests.swift`

- [ ] **Step 1: Write player state tests**

```swift
func testPrepareForReuseClearsSourceAndStopsPlayback() {
    let player = TGSPlayerView()
    player.setSource(.data(Data("{}".utf8), cacheKey: "sample"))
    player.play()
    player.prepareForReuse()
    XCTAssertNil(player.source)
    XCTAssertEqual(player.state, .idle)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TGSPlayerViewTests`
Expected: fail because `TGSPlayerView` is not defined.

- [ ] **Step 3: Implement UIKit scaffold**

Implement a `UIView` subclass with Telegram node-equivalent playback methods, visibility handling, delegate/callback hooks, and `CALayer.contents` / `UIImageView` submission. The first release does not render real rlottie frames until a native renderer is provided.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TGSPlayerViewTests`
Expected: pass on macOS with iOS-compatible SwiftPM settings.

## Task 5: Open-Source Surface

**Files:**
- Create: `README.md`
- Create: `LICENSE`
- Create: `NOTICE`
- Create: `CONTRIBUTING.md`
- Create: `SECURITY.md`
- Create: `.github/workflows/ci.yml`
- Create: `.gitignore`

- [ ] **Step 1: Add README with honest status**

Document the project as an alpha Swift/UIKit TGS player core, clearly stating that rlottie native rendering is the next milestone and not bundled yet.

- [ ] **Step 2: Add community files**

Use MIT license, third-party notice for rlottie, contribution flow, security reporting, and macOS SwiftPM CI.

- [ ] **Step 3: Verify repository checks**

Run: `swift test`
Expected: all tests pass.

Run: `git diff --check`
Expected: no whitespace errors.

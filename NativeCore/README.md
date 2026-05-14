# NativeCore

This directory contains the `rlottie` bridge that matches Telegram iOS' `LottieInstance` shape.

It is not compiled by the default SwiftPM target. The Swift package stays buildable before native artifacts are generated or downloaded. Release builds use a SwiftPM binary target for the native backend.

Current native pieces:

- `RLottieBinding/TGSLottieInstance.h`
- `RLottieBinding/TGSLottieInstance.mm`
- `RLottieBinding/module.modulemap`
- `../scripts/build-rlottie-xcframework.sh`
- `../Package.rlottie-binary.swift.template`

The bridge intentionally preserves Telegram's native limits:

- dimensions <= 1536x1536
- frameRate <= 360
- duration <= 9 seconds
- frameCount and frameRate clamped to at least 1

Use `scripts/build-rlottie-xcframework.sh` to produce local xcframework artifacts:

- `Artifacts/rlottie.xcframework`: raw Telegram `rlottie`.
- `Artifacts/TGSPlayerKitRLottieNative.xcframework`: SwiftPM-facing framework binary that combines `rlottie` and `TGSLottieInstance`.

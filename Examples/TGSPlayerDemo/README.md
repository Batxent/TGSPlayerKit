# TGSPlayerDemo

UIKit demo app for local performance testing.

This project is for contributors working from a source checkout. End users should install the release product through SwiftPM and should not build `rlottie` themselves.

Before opening the project, build the native backend from the repository root:

```bash
RLOTTIE_SOURCE_DIR=/path/to/TelegramMessenger/rlottie scripts/build-rlottie-xcframework.sh
```

Then open:

```text
Examples/TGSPlayerDemo/TGSPlayerDemo.xcodeproj
```

The demo links the local `TGSPlayerKit` package, the generated `TGSPlayerKitRLottieNative.xcframework`, and the Swift adapter source. It shows a grid stress test with live FPS and frame callback counters.

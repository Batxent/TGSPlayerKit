# TGSPlayerDemo

UIKit demo app for local performance testing.

Before opening the project, build the native backend:

```bash
RLOTTIE_SOURCE_DIR=/path/to/TelegramMessenger/rlottie scripts/build-rlottie-xcframework.sh
```

Then open:

```text
Examples/TGSPlayerDemo/TGSPlayerDemo.xcodeproj
```

The demo links the local `TGSPlayerKit` package, the generated `TGSPlayerKitRLottieNative.xcframework`, and the Swift adapter source. It shows a grid stress test with live FPS and frame callback counters.

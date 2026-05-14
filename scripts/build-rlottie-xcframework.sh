#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RLOTTIE_SOURCE_DIR="${RLOTTIE_SOURCE_DIR:-"$ROOT_DIR/Vendor/rlottie"}"
BUILD_DIR="${BUILD_DIR:-"$ROOT_DIR/.build/rlottie"}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-"$ROOT_DIR/NativeCore/Artifacts"}"
OUTPUT_XCFRAMEWORK="$ARTIFACTS_DIR/rlottie.xcframework"
NATIVE_OUTPUT_XCFRAMEWORK="$ARTIFACTS_DIR/TGSPlayerKitRLottieNative.xcframework"
RLOTTIE_XCODE_CXX_FLAGS="\$(inherited) -Wno-error=shorten-64-to-32 -Wno-error=sign-compare"

if [[ ! -f "$RLOTTIE_SOURCE_DIR/CMakeLists.txt" ]]; then
  cat >&2 <<EOF
rlottie source not found at:
  $RLOTTIE_SOURCE_DIR

Clone Telegram's fork first:
  mkdir -p "$ROOT_DIR/Vendor"
  git clone https://github.com/TelegramMessenger/rlottie.git "$RLOTTIE_SOURCE_DIR"
EOF
  exit 1
fi

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required tool: $1" >&2
    exit 1
  fi
}

require_tool cmake
require_tool xcodebuild

build_static_library() {
  local sdk="$1"
  local architectures="$2"
  local build_path="$BUILD_DIR/$sdk"
  local headers_path="$build_path/headers"

  cmake -S "$RLOTTIE_SOURCE_DIR" -B "$build_path" -G Xcode \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$sdk" \
    -DCMAKE_OSX_ARCHITECTURES="$architectures" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DBUILD_SHARED_LIBS=OFF \
    -DLOTTIE_MODULE=OFF \
    -DLOTTIE_THREAD=ON \
    -DLOTTIE_CACHE=ON \
    -DLOTTIE_TEST=OFF

  cmake --build "$build_path" --config Release --target rlottie -- \
    OTHER_CPLUSPLUSFLAGS="$RLOTTIE_XCODE_CXX_FLAGS"

  rm -rf "$headers_path"
  mkdir -p "$headers_path"
  cp "$RLOTTIE_SOURCE_DIR/inc/rlottie.h" "$headers_path/"
  cp "$RLOTTIE_SOURCE_DIR/inc/rlottie_capi.h" "$headers_path/"
  cp "$RLOTTIE_SOURCE_DIR/inc/rlottiecommon.h" "$headers_path/"
}

build_native_bridge_static_library() {
  local sdk="$1"
  local architectures="$2"
  local deployment_target_flag="$3"
  local build_path="$BUILD_DIR/native/$sdk"
  local objects_path="$build_path/objects"
  local library_path="$build_path/libTGSPlayerKitRLottieNative.a"
  local bridge_library_path="$build_path/libTGSPlayerKitRLottieBridge.a"
  local framework_path="$build_path/TGSPlayerKitRLottieNative.framework"
  local rlottie_library_path="$BUILD_DIR/$sdk/Release-$sdk/librlottie.a"
  local sdk_path
  local arch_libraries=()

  sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"

  rm -rf "$build_path"
  mkdir -p "$objects_path"

  IFS=';' read -r -a arch_array <<< "$architectures"
  for arch in "${arch_array[@]}"; do
    local object_path="$objects_path/TGSLottieInstance-$arch.o"
    local fallback_object_path="$objects_path/TGSPixmanNeonFallback-$arch.o"
    local arch_library_path="$objects_path/libTGSPlayerKitRLottieNative-$arch.a"

    xcrun --sdk "$sdk" clang++ \
      -std=c++14 \
      -fobjc-arc \
      -fmodules \
      -fvisibility=hidden \
      -fno-exceptions \
      -fno-rtti \
      -isysroot "$sdk_path" \
      -arch "$arch" \
      "$deployment_target_flag" \
      -I"$RLOTTIE_SOURCE_DIR/inc" \
      -I"$ROOT_DIR/NativeCore/RLottieBinding" \
      -c "$ROOT_DIR/NativeCore/RLottieBinding/TGSLottieInstance.mm" \
      -o "$object_path"

    xcrun --sdk "$sdk" clang++ \
      -std=c++14 \
      -fvisibility=hidden \
      -fno-exceptions \
      -fno-rtti \
      -isysroot "$sdk_path" \
      -arch "$arch" \
      "$deployment_target_flag" \
      -c "$ROOT_DIR/NativeCore/RLottieBinding/TGSPixmanNeonFallback.cpp" \
      -o "$fallback_object_path"

    xcrun --sdk "$sdk" libtool -static -o "$arch_library_path" "$object_path" "$fallback_object_path"
    arch_libraries+=("$arch_library_path")
  done

  if [[ "${#arch_libraries[@]}" -eq 1 ]]; then
    cp "${arch_libraries[0]}" "$bridge_library_path"
  else
    xcrun lipo -create "${arch_libraries[@]}" -output "$bridge_library_path"
  fi

  xcrun libtool -static -o "$library_path" "$bridge_library_path" "$rlottie_library_path"

  mkdir -p "$framework_path/Headers" "$framework_path/Modules"
  cp "$library_path" "$framework_path/TGSPlayerKitRLottieNative"
  cp "$ROOT_DIR/NativeCore/RLottieBinding/TGSLottieInstance.h" "$framework_path/Headers/"
  cp "$ROOT_DIR/NativeCore/RLottieBinding/module.modulemap" "$framework_path/Modules/"
}

rm -rf "$BUILD_DIR" "$OUTPUT_XCFRAMEWORK" "$NATIVE_OUTPUT_XCFRAMEWORK"
mkdir -p "$ARTIFACTS_DIR"

build_static_library iphoneos arm64
build_static_library iphonesimulator "arm64;x86_64"
build_native_bridge_static_library iphoneos arm64 -mios-version-min=13.0
build_native_bridge_static_library iphonesimulator "arm64;x86_64" -mios-simulator-version-min=13.0

xcodebuild -create-xcframework \
  -library "$BUILD_DIR/iphoneos/Release-iphoneos/librlottie.a" \
  -headers "$BUILD_DIR/iphoneos/headers" \
  -library "$BUILD_DIR/iphonesimulator/Release-iphonesimulator/librlottie.a" \
  -headers "$BUILD_DIR/iphonesimulator/headers" \
  -output "$OUTPUT_XCFRAMEWORK"

xcodebuild -create-xcframework \
  -framework "$BUILD_DIR/native/iphoneos/TGSPlayerKitRLottieNative.framework" \
  -framework "$BUILD_DIR/native/iphonesimulator/TGSPlayerKitRLottieNative.framework" \
  -output "$NATIVE_OUTPUT_XCFRAMEWORK"

echo "Created $OUTPUT_XCFRAMEWORK"
echo "Created $NATIVE_OUTPUT_XCFRAMEWORK"

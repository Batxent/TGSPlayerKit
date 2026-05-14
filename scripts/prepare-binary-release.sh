#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-"$ROOT_DIR/NativeCore/Artifacts"}"
OUTPUT_DIR="${OUTPUT_DIR:-"$ROOT_DIR/.build/binary-release"}"
RELEASE_URL_BASE="${RELEASE_URL_BASE:-"${1:-}"}"

if [[ -z "$RELEASE_URL_BASE" ]]; then
  cat >&2 <<EOF
Usage:
  RELEASE_URL_BASE=https://github.com/your-org/TGSPlayerKit/releases/download/0.1.0 scripts/prepare-binary-release.sh

The URL base should be the final GitHub Release download prefix.
EOF
  exit 1
fi

require_artifact() {
  if [[ ! -d "$1" ]]; then
    echo "Missing artifact: $1" >&2
    echo "Run scripts/build-rlottie-xcframework.sh first." >&2
    exit 1
  fi
}

require_artifact "$ARTIFACTS_DIR/TGSPlayerKitRLottieNative.xcframework"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

native_zip="$OUTPUT_DIR/TGSPlayerKitRLottieNative.xcframework.zip"

ditto -c -k --sequesterRsrc --keepParent "$ARTIFACTS_DIR/TGSPlayerKitRLottieNative.xcframework" "$native_zip"

native_checksum="$(swift package compute-checksum "$native_zip")"

sed \
  -e "s#__NATIVE_XCFRAMEWORK_URL__#$RELEASE_URL_BASE/TGSPlayerKitRLottieNative.xcframework.zip#g" \
  -e "s#__NATIVE_XCFRAMEWORK_CHECKSUM__#$native_checksum#g" \
  "$ROOT_DIR/Package.rlottie-binary.swift.template" > "$OUTPUT_DIR/Package.swift"

cat <<EOF
Prepared binary release files:
  $native_zip
  $OUTPUT_DIR/Package.swift

Checksums:
  TGSPlayerKitRLottieNative: $native_checksum
EOF

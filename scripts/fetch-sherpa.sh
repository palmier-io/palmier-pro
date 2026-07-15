#!/bin/bash
# Fetches the sherpa-onnx macOS xcframework + onnxruntime static lib and assembles
# Vendor/sherpa-onnx.xcframework (git-excluded: the merged lib exceeds GitHub's 100MB cap).
# Run once after cloning, before `swift build`.
set -euo pipefail

SHERPA_VERSION="1.13.4"
ORT_VERSION="1.27.0"
ORT_SHA256="6794da8dd86d0b83b453e7968771cddfb3004e3db4cda5cea6d4111a616f49cb"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor"
FRAMEWORK="$VENDOR/sherpa-onnx.xcframework"

if [ -f "$FRAMEWORK/macos-arm64_x86_64/libsherpa-onnx.a" ]; then
  echo "==> $FRAMEWORK already present; delete it to re-fetch"
  exit 0
fi

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

echo "==> Downloading sherpa-onnx v$SHERPA_VERSION xcframework"
curl -sL -o "$STAGING/sherpa.tar.bz2" \
  "https://github.com/k2-fsa/sherpa-onnx/releases/download/v$SHERPA_VERSION/sherpa-onnx-v$SHERPA_VERSION-macos-xcframework-static.tar.bz2"
tar -xjf "$STAGING/sherpa.tar.bz2" -C "$STAGING"

echo "==> Downloading onnxruntime $ORT_VERSION static lib"
curl -sL -o "$STAGING/ort.zip" \
  "https://github.com/csukuangfj/onnxruntime-libs/releases/download/v$ORT_VERSION/onnxruntime-osx-universal2-static_lib-$ORT_VERSION.zip"
echo "$ORT_SHA256  $STAGING/ort.zip" | shasum -a 256 -c -
unzip -q "$STAGING/ort.zip" -d "$STAGING"

echo "==> Merging static libraries"
FW_SRC="$STAGING/sherpa-onnx-v$SHERPA_VERSION-macos-xcframework-static/sherpa-onnx.xcframework"
LIB_DIR="$FW_SRC/macos-arm64_x86_64"
libtool -static -o "$LIB_DIR/libsherpa-combined.a" \
  "$LIB_DIR/libsherpa-onnx.a" \
  "$STAGING/onnxruntime-osx-universal2-static_lib-$ORT_VERSION/lib/libonnxruntime.a" 2> >(grep -v "has no symbols" >&2 || true)
mv "$LIB_DIR/libsherpa-combined.a" "$LIB_DIR/libsherpa-onnx.a"

cat > "$LIB_DIR/Headers/module.modulemap" <<'EOF'
module CSherpaOnnx {
    header "sherpa-onnx/c-api/c-api.h"
    export *
}
EOF

mkdir -p "$VENDOR"
rm -rf "$FRAMEWORK"
mv "$FW_SRC" "$FRAMEWORK"
echo "==> Done: $FRAMEWORK"

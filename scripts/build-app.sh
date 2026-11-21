#!/usr/bin/env bash
# Builds a universal (arm64 + x86_64), ad-hoc signed ClaudeUsageMonitor.app and a zip of it.
# Must run on macOS with Xcode / Command Line Tools installed.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.0.0-dev}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
OUT="build"
APP="$OUT/ClaudeUsageMonitor.app"
ARCHS=(--arch arm64 --arch x86_64)

echo "==> Building release binary ($VERSION, build $BUILD_NUMBER)"
swift build -c release "${ARCHS[@]}"
BIN_DIR="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ClaudeUsageMonitor" "$APP/Contents/MacOS/ClaudeUsageMonitor"
sed -e "s/__VERSION__/${VERSION}/" -e "s/__BUILD__/${BUILD_NUMBER}/" \
    packaging/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"
lipo -info "$APP/Contents/MacOS/ClaudeUsageMonitor"

echo "==> Ad-hoc signing"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --verbose=2 "$APP"

echo "==> Zipping"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/ClaudeUsageMonitor.zip"
ls -lh "$OUT/ClaudeUsageMonitor.zip"

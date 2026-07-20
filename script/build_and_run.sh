#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="ChengGao"
DISPLAY_NAME="澄稿"
BUNDLE_ID="com.itou.chenggao"
MIN_SYSTEM_VERSION="26.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
BUILD_NUMBER="$(tr -d '[:space:]' < "$ROOT_DIR/BUILD_NUMBER")"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$DISPLAY_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_RESOURCES="$APP_CONTENTS/Resources"
WHISPER_MODEL="$ROOT_DIR/Models/ggml-small-q5_1.bin"
WHISPER_FRAMEWORK="$ROOT_DIR/Frameworks/whisper.xcframework/macos-arm64_x86_64/whisper.framework"
LOCAL_LICENSES="$ROOT_DIR/Licenses"
APP_ICON="$ROOT_DIR/Assets/AppIcon.icns"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

cd "$ROOT_DIR"
swift build -c release \
  -Xswiftc -warnings-as-errors \
  -Xswiftc -gnone \
  -Xswiftc -file-prefix-map \
  -Xswiftc "$ROOT_DIR=."
BUILD_BINARY="$(swift build -c release --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

# A distributable app must never retain package-manager paths from the build Mac.
# CSQLite links against the SQLite library supplied by the macOS SDK.
if otool -L "$APP_BINARY" | grep -Eq '/opt/homebrew/|/usr/local/(opt|Cellar)/'; then
  echo "错误：主程序仍包含开发机包管理器动态库路径，拒绝打包。" >&2
  otool -L "$APP_BINARY" >&2
  exit 1
fi

# Never ship the development build or a binary that exposes this checkout.
# Besides leaking the builder's directory, debug artifacts have different
# optimization and runtime characteristics from the copy users receive.
if grep -aqE '/Users/[^/]+/.+/(Sources|Tests)/|\.build/.+/debug/' "$APP_BINARY"; then
  echo "错误：主程序仍包含开发机源码或调试构建路径，拒绝打包。" >&2
  exit 1
fi

if [[ -f "$WHISPER_MODEL" ]]; then
  mkdir -p "$APP_RESOURCES/Models"
  cp "$WHISPER_MODEL" "$APP_RESOURCES/Models/"
fi

if [[ -d "$WHISPER_FRAMEWORK" ]]; then
  mkdir -p "$APP_CONTENTS/Frameworks"
  cp -R "$WHISPER_FRAMEWORK" "$APP_CONTENTS/Frameworks/"
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BINARY" 2>/dev/null || true
fi

if [[ -d "$LOCAL_LICENSES" ]]; then
  mkdir -p "$APP_RESOURCES/Licenses"
  cp -R "$LOCAL_LICENSES/." "$APP_RESOURCES/Licenses/"
fi

if [[ -f "$APP_ICON" ]]; then
  cp "$APP_ICON" "$APP_RESOURCES/AppIcon.icns"
fi

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$DISPLAY_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$DISPLAY_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

# Bind the final Info.plist and embedded framework to an ad-hoc local signature.
# Hardened Runtime is intentionally added only by package_release.sh together
# with a Developer ID identity. Ad-hoc nested code has no common Team ID, so
# enabling library validation here would make the app fail while loading whisper.
if [[ -d "$APP_CONTENTS/Frameworks/whisper.framework" ]]; then
  codesign --force --sign - --timestamp=none "$APP_CONTENTS/Frameworks/whisper.framework"
fi
codesign --force --deep --sign - --timestamp=none "$APP_BUNDLE"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 2
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  --package|package)
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--package]" >&2
    exit 2
    ;;
esac

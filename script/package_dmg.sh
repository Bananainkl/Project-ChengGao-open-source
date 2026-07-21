#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
BUILD_NUMBER="$(tr -d '[:space:]' < "$ROOT_DIR/BUILD_NUMBER")"
APP="$ROOT_DIR/dist/澄稿.app"
DMG="$ROOT_DIR/dist/ChengGao-$VERSION-macOS-arm64.dmg"
CHECKSUM="$DMG.sha256"
STAGING="$ROOT_DIR/dist/.dmg-staging"
USER_GUIDE="$ROOT_DIR/docs/请先阅读-安装与使用说明.txt"

cleanup() {
  rm -rf "$STAGING"
}
trap cleanup EXIT

"$ROOT_DIR/script/build_and_run.sh" --package

ACTUAL_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ACTUAL_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
if [[ "$ACTUAL_VERSION" != "$VERSION" || "$ACTUAL_BUILD" != "$BUILD_NUMBER" ]]; then
  echo "应用版本与 VERSION/BUILD_NUMBER 不一致，停止打包。" >&2
  exit 3
fi

codesign --verify --deep --strict --verbose=2 "$APP"

if [[ ! -s "$USER_GUIDE" ]]; then
  echo "缺少安装与使用说明，停止打包：$USER_GUIDE" >&2
  exit 3
fi

rm -rf "$STAGING"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/澄稿.app"
ditto "$USER_GUIDE" "$STAGING/请先阅读｜安装与使用说明.txt"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG" "$CHECKSUM"
hdiutil create \
  -volname "澄稿 $VERSION" \
  -srcfolder "$STAGING" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  "$DMG"

hdiutil verify "$DMG"
(
  cd "$ROOT_DIR/dist"
  shasum -a 256 "$(basename "$DMG")"
) > "$CHECKSUM"

echo "$DMG"
echo "$CHECKSUM"

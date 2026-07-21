#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
BUILD_NUMBER="$(tr -d '[:space:]' < "$ROOT_DIR/BUILD_NUMBER")"
APP="$ROOT_DIR/dist/澄稿.app"
ARCHIVE="$ROOT_DIR/dist/ChengGao-$VERSION-macOS-arm64.zip"
DMG="$ROOT_DIR/dist/ChengGao-$VERSION-macOS-arm64.dmg"
STAGING="$ROOT_DIR/dist/.notary-dmg-staging"
IDENTITY="${CHENGGAO_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${CHENGGAO_NOTARY_PROFILE:-}"
USER_GUIDE="$ROOT_DIR/docs/请先阅读-安装与使用说明.txt"

if [[ -z "$IDENTITY" ]]; then
  echo "请设置 CHENGGAO_SIGN_IDENTITY，例如 Developer ID Application: Name (TEAMID)。" >&2
  exit 2
fi

if ! security find-identity -v -p codesigning | grep -Fq "\"$IDENTITY\""; then
  echo "钥匙串中没有找到指定的 Developer ID Application 证书。" >&2
  exit 2
fi

if [[ -z "$NOTARY_PROFILE" ]]; then
  echo "请设置 CHENGGAO_NOTARY_PROFILE，指向已由 notarytool store-credentials 保存的钥匙串配置。" >&2
  exit 2
fi

if ! grep -Fq "## $VERSION ($BUILD_NUMBER)" "$ROOT_DIR/CHANGELOG.md"; then
  echo "CHANGELOG.md 中缺少 $VERSION ($BUILD_NUMBER) 的更新记录，停止发布。" >&2
  exit 2
fi

if [[ ! -s "$USER_GUIDE" ]]; then
  echo "缺少安装与使用说明，停止发布：$USER_GUIDE" >&2
  exit 2
fi

cleanup() { rm -rf "$STAGING"; }
trap cleanup EXIT

(cd "$ROOT_DIR" && swift test -Xswiftc -warnings-as-errors)
"$ROOT_DIR/script/build_and_run.sh" --package

# Sign every nested Mach-O first. The outer app is signed last without --deep,
# so Hardened Runtime and the Developer ID Team ID are consistent throughout.
if [[ -d "$APP/Contents/Frameworks/whisper.framework" ]]; then
  codesign --force --options runtime --timestamp --sign "$IDENTITY" \
    "$APP/Contents/Frameworks/whisper.framework"
fi
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --verbose=4 "$APP" 2>&1 | grep -Fq "flags=0x10000(runtime)"

rm -f "$ARCHIVE"
ditto -c -k --keepParent "$APP" "$ARCHIVE"
xcrun notarytool submit "$ARCHIVE" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vv --type execute "$APP"

# Recreate the ZIP after stapling so the distributed copy contains the ticket.
rm -f "$ARCHIVE"
ditto -c -k --keepParent "$APP" "$ARCHIVE"
shasum -a 256 "$ARCHIVE"

rm -rf "$STAGING"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/澄稿.app"
ditto "$USER_GUIDE" "$STAGING/请先阅读｜安装与使用说明.txt"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG" "$DMG.sha256"
hdiutil create -volname "澄稿 $VERSION" -srcfolder "$STAGING" -format UDZO \
  -imagekey zlib-level=9 -ov "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl -a -vv --type open --context context:primary-signature "$DMG"
hdiutil verify "$DMG"
shasum -a 256 "$DMG" > "$DMG.sha256"

echo "$ARCHIVE"
echo "$DMG"

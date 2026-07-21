#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
BUILD_NUMBER="$(tr -d '[:space:]' < "$ROOT_DIR/BUILD_NUMBER")"
SOURCE_DMG="${1:-$ROOT_DIR/dist/澄稿-$VERSION-macOS-arm64.dmg}"
INSTALL_DIR="${CHENGGAO_INSTALL_DIR:-/Applications}"
INSTALLED_APP="$INSTALL_DIR/澄稿.app"
STAGING_APP="$INSTALL_DIR/.澄稿.installing.app"
BACKUP_APP="$INSTALL_DIR/.澄稿.previous.app"
MOUNT_DIR="$(mktemp -d /private/tmp/chenggao-install.XXXXXX)"
MOUNTED=0

cleanup() {
  if [[ "$MOUNTED" == "1" ]]; then
    hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
  fi
  rmdir "$MOUNT_DIR" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if [[ ! -f "$SOURCE_DMG" ]]; then
  echo "找不到 $SOURCE_DMG，请先运行 package_dmg.sh。" >&2
  exit 2
fi

hdiutil verify "$SOURCE_DMG" >/dev/null
hdiutil attach "$SOURCE_DMG" -nobrowse -readonly -mountpoint "$MOUNT_DIR" >/dev/null
MOUNTED=1
SOURCE_APP="$MOUNT_DIR/澄稿.app"
if [[ ! -d "$SOURCE_APP" || ! -s "$MOUNT_DIR/请先阅读｜安装与使用说明.txt" ]]; then
  echo "DMG 缺少澄稿.app 或安装与使用说明，拒绝安装。" >&2
  exit 2
fi

SOURCE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE_APP/Contents/Info.plist")"
SOURCE_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$SOURCE_APP/Contents/Info.plist")"
if [[ "$SOURCE_VERSION" != "$VERSION" || "$SOURCE_BUILD" != "$BUILD_NUMBER" ]]; then
  echo "待安装应用不是当前版本 $VERSION ($BUILD_NUMBER)。" >&2
  exit 3
fi

pkill -x ChengGao >/dev/null 2>&1 || true
rm -rf "$STAGING_APP" "$BACKUP_APP"
ditto "$SOURCE_APP" "$STAGING_APP"
codesign --verify --deep --strict --verbose=2 "$STAGING_APP"

if [[ -d "$INSTALLED_APP" ]]; then
  mv "$INSTALLED_APP" "$BACKUP_APP"
fi

if ! mv "$STAGING_APP" "$INSTALLED_APP"; then
  [[ -d "$BACKUP_APP" ]] && mv "$BACKUP_APP" "$INSTALLED_APP"
  exit 4
fi

/usr/bin/open -n "$INSTALLED_APP"
sleep 3
if ! pgrep -f "$INSTALLED_APP/Contents/MacOS/ChengGao" >/dev/null; then
  rm -rf "$INSTALLED_APP"
  [[ -d "$BACKUP_APP" ]] && mv "$BACKUP_APP" "$INSTALLED_APP"
  echo "新版本启动失败，已恢复上一版本。" >&2
  exit 5
fi

rm -rf "$BACKUP_APP"
echo "已从 DMG 安装并启动澄稿 $VERSION ($BUILD_NUMBER)：$INSTALLED_APP"

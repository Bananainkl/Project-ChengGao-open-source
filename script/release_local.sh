#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
BUILD_NUMBER="$(tr -d '[:space:]' < "$ROOT_DIR/BUILD_NUMBER")"

if ! grep -Fq "## $VERSION ($BUILD_NUMBER)" "$ROOT_DIR/CHANGELOG.md"; then
  echo "CHANGELOG.md 中缺少 $VERSION ($BUILD_NUMBER) 的更新记录，停止发布。" >&2
  exit 2
fi

(cd "$ROOT_DIR" && swift test -Xswiftc -warnings-as-errors)
"$ROOT_DIR/script/package_dmg.sh"
"$ROOT_DIR/script/install_local.sh" "$ROOT_DIR/dist/澄稿-$VERSION-macOS-arm64.dmg"

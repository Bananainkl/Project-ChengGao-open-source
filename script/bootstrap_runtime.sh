#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WHISPER_TAG="v1.9.1"
WHISPER_ARCHIVE="whisper-${WHISPER_TAG}-xcframework.zip"
WHISPER_URL="https://github.com/ggml-org/whisper.cpp/releases/download/${WHISPER_TAG}/whisper-${WHISPER_TAG}-xcframework.zip"
WHISPER_SHA256="8c3ecbe73f48b0cb9318fc3058264f951ab336fd530e82c4ccdd2298d1311a4c"
WHISPER_MODEL_FILENAME="ggml-small-q5_1.bin"
WHISPER_MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${WHISPER_MODEL_FILENAME}"
WHISPER_MODEL_SHA256="ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb"
WHISPER_LICENSE_URL="https://raw.githubusercontent.com/ggml-org/whisper.cpp/${WHISPER_TAG}/LICENSE"
WHISPER_LICENSE_SHA256="94f29bbed6a22c35b992c5c6ebf0e7c92f13b836b90f36f461c9cf2f0f1d010d"

CACHE_DIR="$ROOT_DIR/.build/bootstrap-cache"
WHISPER_ARCHIVE_PATH="$CACHE_DIR/$WHISPER_ARCHIVE"
WHISPER_FRAMEWORK_PATH="$ROOT_DIR/Frameworks/whisper.xcframework"
WHISPER_MODEL_PATH="$ROOT_DIR/Models/$WHISPER_MODEL_FILENAME"
WHISPER_LICENSE_PATH="$ROOT_DIR/Licenses/whisper.cpp-LICENSE.txt"

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "当前引导脚本只支持 Apple Silicon；Intel 运行时需要单独打包。" >&2
  exit 2
fi

mkdir -p "$CACHE_DIR" "$ROOT_DIR/Models" "$ROOT_DIR/Licenses" "$ROOT_DIR/Frameworks"

verify_sha() {
  local file="$1"
  local expected="$2"
  local actual
  actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    echo "校验失败：$file" >&2
    echo "expected: $expected" >&2
    echo "actual:   $actual" >&2
    exit 1
  fi
}

if [[ ! -d "$WHISPER_FRAMEWORK_PATH" ]]; then
  if [[ ! -f "$WHISPER_ARCHIVE_PATH" ]]; then
    curl -fL --retry 3 --progress-bar -o "$WHISPER_ARCHIVE_PATH" "$WHISPER_URL"
  fi
  verify_sha "$WHISPER_ARCHIVE_PATH" "$WHISPER_SHA256"
  WHISPER_UNPACKED="$CACHE_DIR/whisper-unpacked"
  rm -rf "$WHISPER_UNPACKED" "$WHISPER_FRAMEWORK_PATH"
  mkdir -p "$WHISPER_UNPACKED"
  unzip -q "$WHISPER_ARCHIVE_PATH" -d "$WHISPER_UNPACKED"
  xcodebuild -create-xcframework \
    -framework "$WHISPER_UNPACKED/build-apple/whisper.xcframework/macos-arm64_x86_64/whisper.framework" \
    -output "$WHISPER_FRAMEWORK_PATH"
fi

if [[ ! -f "$WHISPER_MODEL_PATH" ]]; then
  curl -fL --retry 3 --progress-bar -o "$WHISPER_MODEL_PATH.partial" "$WHISPER_MODEL_URL"
  mv "$WHISPER_MODEL_PATH.partial" "$WHISPER_MODEL_PATH"
fi
verify_sha "$WHISPER_MODEL_PATH" "$WHISPER_MODEL_SHA256"

if [[ ! -f "$WHISPER_LICENSE_PATH" ]]; then
  curl -fL --retry 3 --progress-bar -o "$WHISPER_LICENSE_PATH" "$WHISPER_LICENSE_URL"
fi
verify_sha "$WHISPER_LICENSE_PATH" "$WHISPER_LICENSE_SHA256"

echo "语音识别框架：$WHISPER_FRAMEWORK_PATH"
echo "语音识别模型：$WHISPER_MODEL_PATH"

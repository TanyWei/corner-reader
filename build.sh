#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="${CORNER_READER_DIST_DIR:-$PROJECT_DIR/dist}"
APP_NAME="角落阅读"
APP_PATH="$DIST_DIR/$APP_NAME.app"

if [[ "${1:-}" == "--test" ]]; then
  TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/corner-reader-tests.XXXXXX")"
  trap 'rm -rf "$TEST_DIR"' EXIT
  xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$TEST_DIR/ModuleCache" \
    "$PROJECT_DIR/Sources/ReaderCore.swift" \
    "$PROJECT_DIR/Tests/ReaderCoreTests.swift" \
    -o "$TEST_DIR/ReaderCoreTests"
  "$TEST_DIR/ReaderCoreTests"
  xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$TEST_DIR/ModuleCache" \
    "$PROJECT_DIR/Sources/ReaderCore.swift" \
    "$PROJECT_DIR/Sources/ReaderTextWindow.swift" \
    "$PROJECT_DIR/Tests/ReaderTextWindowTests.swift" \
    -o "$TEST_DIR/ReaderTextWindowTests"
  "$TEST_DIR/ReaderTextWindowTests"
  exit 0
fi

if [[ $# -gt 0 ]]; then
  printf '用法：%s [--test]\n' "$0" >&2
  exit 2
fi

mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
xcrun swiftc -swift-version 5 -O -module-cache-path "$DIST_DIR/.module-cache" \
  -target "$(uname -m)-apple-macosx13.0" \
  -framework AppKit -framework QuartzCore \
  "$PROJECT_DIR"/Sources/*.swift \
  -o "$APP_PATH/Contents/MacOS/CornerReader"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
for resource in "$PROJECT_DIR"/Resources/*; do
  [[ "$(basename "$resource")" == "Info.plist" ]] && continue
  cp -R "$resource" "$APP_PATH/Contents/Resources/"
done
codesign --force --deep --sign - "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$DIST_DIR/$APP_NAME-Mac.zip"
printf '\n已生成：\n%s\n%s\n' "$APP_PATH" "$DIST_DIR/$APP_NAME-Mac.zip"

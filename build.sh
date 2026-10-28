#!/bin/bash
# 编译 NotifSound.app（无需 Xcode，Command Line Tools 的 swiftc 即可）
set -euo pipefail

cd "$(dirname "$0")"

APP="build/NotifSound.app"
BIN="$APP/Contents/MacOS/NotifSound"

mkdir -p "$APP/Contents/MacOS"

swiftc -O Sources/main.swift -o "$BIN" \
  -framework Cocoa -framework ApplicationServices

cp Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "built: $APP"

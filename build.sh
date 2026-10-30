#!/bin/bash
# Build TimerBar.app from main.swift. Requires Xcode Command Line Tools only.
set -euo pipefail
cd "$(dirname "$0")"

APP="TimerBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cp Info.plist "$APP/Contents/Info.plist"

swiftc -O -swift-version 5 main.swift \
    -o "$APP/Contents/MacOS/TimerBar" \
    -framework AppKit

# Ad-hoc sign so macOS treats it as a stable app identity.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Built: $PWD/$APP"

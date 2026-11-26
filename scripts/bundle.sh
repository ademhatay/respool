#!/bin/zsh
# Builds Respool and wraps the binary in an app bundle at build/Respool.app.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
APP="build/Respool.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Respool "$APP/Contents/MacOS/Respool"
cp Support/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "$PWD/$APP"

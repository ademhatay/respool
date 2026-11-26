#!/bin/zsh
# Builds Raf and wraps the binary in an app bundle at build/Raf.app.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
APP="build/Raf.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Raf "$APP/Contents/MacOS/Raf"
cp Support/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "$PWD/$APP"

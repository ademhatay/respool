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
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Signed for this Mac only, unless RESPOOL_SIGN_IDENTITY names a certificate. A Developer ID
# certificate gets the hardened runtime and a timestamp, which notarization asks for.
IDENTITY="${RESPOOL_SIGN_IDENTITY:--}"
if [ "$IDENTITY" = "-" ]; then
    codesign --force --sign - "$APP" >/dev/null 2>&1
elif [[ "$IDENTITY" == Developer\ ID* ]]; then
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
else
    codesign --force --sign "$IDENTITY" "$APP" >/dev/null 2>&1
fi
echo "$PWD/$APP"

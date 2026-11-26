#!/bin/zsh
# Builds Respool, installs it to /Applications and starts it.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=/Applications/Respool.app
BINARY="$APP/Contents/MacOS/Respool"

# A rebuilt app has a new signature, which drops its login item. Remember it to restore it.
LOGIN_ITEM=""
if [ -x "$BINARY" ]; then LOGIN_ITEM=$("$BINARY" --login-item status 2>/dev/null || true); fi

./scripts/bundle.sh >/dev/null
pkill -f "Respool.app/Contents/MacOS/Respool" 2>/dev/null || true
sleep 1
rm -rf "$APP"
cp -R build/Respool.app "$APP"
if [ "$LOGIN_ITEM" = "login item enabled" ]; then "$BINARY" --login-item on >/dev/null; fi
open "$APP"
echo "$APP"

#!/bin/zsh
# Builds Respool, installs it to /Applications and starts it.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/bundle.sh >/dev/null
pkill -f "Respool.app/Contents/MacOS/Respool" 2>/dev/null || true
sleep 1
rm -rf /Applications/Respool.app
cp -R build/Respool.app /Applications/Respool.app
open /Applications/Respool.app
echo "/Applications/Respool.app"

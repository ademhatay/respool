#!/bin/zsh
# Builds Raf, installs it to /Applications and starts it.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/bundle.sh >/dev/null
pkill -f "Raf.app/Contents/MacOS/Raf" 2>/dev/null || true
sleep 1
rm -rf /Applications/Raf.app
cp -R build/Raf.app /Applications/Raf.app
open /Applications/Raf.app
echo "/Applications/Raf.app"

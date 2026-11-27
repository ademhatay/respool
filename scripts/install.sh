#!/bin/zsh
# Builds Respool, installs it to /Applications and starts it.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=/Applications/Respool.app
BINARY="$APP/Contents/MacOS/Respool"

# A rebuilt app has a new signature, which drops its login item. Remember it to restore it.
LOGIN_ITEM=""
if [ -x "$BINARY" ]; then LOGIN_ITEM=$("$BINARY" --login-item status 2>/dev/null || true); fi

# Signed with your own Apple Development certificate when this Mac has one, so that macOS keeps
# the permissions given to the app (Accessibility, automation) from one build to the next. The
# certificate stays on this Mac: nothing about it is written into the repository. A personal
# team's certificate is preferred over a company's; RESPOOL_SIGN_IDENTITY picks one by hand.
if [ -z "${RESPOOL_SIGN_IDENTITY:-}" ]; then
    FIRST=""
    PERSONAL=""
    for HASH in $(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | awk '{print $2}'); do
        [ -z "$FIRST" ] && FIRST="$HASH"
        SUBJECT=$(security find-certificate -a -Z -p 2>/dev/null \
            | awk -v hash="$HASH" '/SHA-1 hash:/ {keep = ($3 == hash)} keep' \
            | openssl x509 -noout -subject -nameopt multiline 2>/dev/null)
        NAME=$(echo "$SUBJECT" | sed -n 's/.*commonName *= *Apple Development: \(.*\) (.*/\1/p')
        ORG=$(echo "$SUBJECT" | sed -n 's/.*organizationName *= *//p')
        # A personal team is named after its owner.
        if [ -n "$NAME" ] && [ "$NAME" = "$ORG" ]; then PERSONAL="$HASH"; break; fi
    done
    CHOSEN="${PERSONAL:-$FIRST}"
    if [ -n "$CHOSEN" ]; then export RESPOOL_SIGN_IDENTITY="$CHOSEN"; fi
fi
./scripts/bundle.sh >/dev/null
pkill -f "Respool.app/Contents/MacOS/Respool" 2>/dev/null || true
sleep 1
rm -rf "$APP"
cp -R build/Respool.app "$APP"
if [ "$LOGIN_ITEM" = "login item enabled" ]; then "$BINARY" --login-item on >/dev/null; fi
open "$APP"
echo "$APP"

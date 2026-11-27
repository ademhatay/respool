#!/bin/zsh
# Builds a copy of Respool that other Macs will open without a warning: signed with a
# Developer ID certificate, notarized by Apple, and zipped at build/Respool.zip.
#
#   RESPOOL_SIGN_IDENTITY   the certificate, e.g. "Developer ID Application: Your Name (TEAMID)"
#   RESPOOL_NOTARY_PROFILE  a notarytool keychain profile, made once with
#                           xcrun notarytool store-credentials <profile>
set -euo pipefail
cd "$(dirname "$0")/.."

: "${RESPOOL_SIGN_IDENTITY:?set RESPOOL_SIGN_IDENTITY to a Developer ID Application certificate}"
: "${RESPOOL_NOTARY_PROFILE:?set RESPOOL_NOTARY_PROFILE to a notarytool keychain profile}"

./scripts/bundle.sh >/dev/null
APP="build/Respool.app"
ZIP="build/Respool.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$RESPOOL_NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
# The zip is made again so that it carries the stapled ticket.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "$PWD/$ZIP"

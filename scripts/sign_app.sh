#!/bin/bash
# Sign SideScreen.app. Sparkle's nested helpers first, then the framework, then
# the app (`codesign --deep` is deprecated and gets the order wrong).
#
#   scripts/sign_app.sh SideScreen.app <identity>   # name or SHA-1 of a code-signing identity
#   scripts/sign_app.sh SideScreen.app -            # ad-hoc
#
# The fork signs with its self-signed "SideScreen Fork Code Signing" identity
# (scripts/setup_fork_signing.sh): a stable certificate keeps macOS's Screen
# Recording / Accessibility grants across updates, and Sparkle requires updates
# to be signed by the same identity as the running app. Only Apple-issued
# Developer ID identities get a secure timestamp. SIDESCREEN_SIGN_KEYCHAIN
# selects a keychain (CI imports the identity into a temporary one).
set -euo pipefail

APP="${1:?usage: sign_app.sh <SideScreen.app> <identity|->}"
IDENTITY="${2:?usage: sign_app.sh <SideScreen.app> <identity|->}"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENTITLEMENTS="$ROOT_DIR/MacHost/SideScreen.entitlements"

FLAGS=(--force --options runtime)
case "$IDENTITY" in
  "Developer ID"*) FLAGS+=(--timestamp) ;;
  *) FLAGS+=(--timestamp=none) ;;
esac
if [ -n "${SIDESCREEN_SIGN_KEYCHAIN:-}" ]; then
  FLAGS+=(--keychain "$SIDESCREEN_SIGN_KEYCHAIN")
fi

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE" ]; then
  codesign "${FLAGS[@]}" --sign "$IDENTITY" "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
  codesign "${FLAGS[@]}" --sign "$IDENTITY" --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
  codesign "${FLAGS[@]}" --sign "$IDENTITY" "$SPARKLE/Versions/B/Autoupdate"
  codesign "${FLAGS[@]}" --sign "$IDENTITY" "$SPARKLE/Versions/B/Updater.app"
  codesign "${FLAGS[@]}" --sign "$IDENTITY" "$SPARKLE"
fi

codesign "${FLAGS[@]}" --sign "$IDENTITY" --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --strict --verbose=2 "$APP"
codesign -d -r- "$APP" 2>&1 | grep designated || true

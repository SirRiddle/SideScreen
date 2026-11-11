#!/bin/bash
# DMG with the app and an /Applications symlink.
#   scripts/make_dmg.sh <SideScreen.app> <out.dmg>
set -euo pipefail
APP="${1:?usage: make_dmg.sh <app> <out.dmg>}"
DMG="${2:?usage: make_dmg.sh <app> <out.dmg>}"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Side Screen" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "  ✓ DMG: $DMG"

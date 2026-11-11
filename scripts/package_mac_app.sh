#!/bin/bash
# Assemble SideScreen.app from a release build: universal binary, Sparkle.framework,
# icon and Info.plist (with the fork's Sparkle feed and EdDSA public key). The one
# bundle layout shared by build_mac.sh, the Build macOS test artifact and Release.
#
#   scripts/package_mac_app.sh <SideScreen binary> <Sparkle.framework> <version> <out .app>
set -euo pipefail

BINARY="${1:?usage: package_mac_app.sh <binary> <Sparkle.framework> <version> <out.app>}"
SPARKLE="${2:?usage}"
VERSION="${3:?usage}"
APP_DIR="${4:?usage}"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Sparkle feed: appcast.xml attached to this fork's latest GitHub release.
FEED_URL="${SIDESCREEN_FEED_URL:-https://github.com/SirRiddle/SideScreen/releases/latest/download/appcast.xml}"
# Public half of the fork's EdDSA key (scripts/setup_fork_signing.sh). Updates
# whose appcast signature doesn't verify against it are refused.
PUBLIC_ED_KEY="d/u3Ely2URcL1m1evtAnw9sG0ehi8zbHnt0YPHHhklk="

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Frameworks"
cp "$BINARY" "$APP_DIR/Contents/MacOS/SideScreen"
cp -R "$SPARKLE" "$APP_DIR/Contents/Frameworks/"
if [ -f "$ROOT_DIR/MacHost/Resources/AppIcon.icns" ]; then
  cp "$ROOT_DIR/MacHost/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/"
fi

cat > "$APP_DIR/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>SideScreen</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.sidescreen.app</string>
    <key>CFBundleName</key>
    <string>Side Screen</string>
    <key>CFBundleDisplayName</key>
    <string>Side Screen</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <false/>
    <key>SUFeedURL</key>
    <string>${FEED_URL}</string>
    <key>SUPublicEDKey</key>
    <string>${PUBLIC_ED_KEY}</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Side Screen needs screen recording access to capture your virtual display and stream it to your Android device.</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Side Screen needs Local Network access so your Android tablet can connect to the Mac over WiFi for wireless mode. Without this, only USB-tethered connections work.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_sidescreen._tcp</string>
    </array>
</dict>
</plist>
PLIST
echo "  ✓ Packaged $APP_DIR ($VERSION)"

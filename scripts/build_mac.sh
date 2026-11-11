#!/bin/bash
set -e

# Get absolute path to root directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Read version
VERSION=$(cat "$ROOT_DIR/VERSION" | tr -d '[:space:]')
echo "Building version $VERSION..."

cd "$ROOT_DIR/MacHost"

# Kill running instance
echo "Stopping running Side Screen..."
pkill -f SideScreen 2>/dev/null || true
sleep 0.5

# Clean old build
echo "Cleaning old build..."
rm -rf .build

# Build fresh (Universal Binary: arm64 + x86_64)
echo "Building macOS Host (arm64)..."
swift build -c release --arch arm64

echo "Building macOS Host (x86_64)..."
swift build -c release --arch x86_64

echo "Creating Universal Binary..."
ARM_BIN="$(swift build -c release --arch arm64 --show-bin-path)"
X86_BIN="$(swift build -c release --arch x86_64 --show-bin-path)"
mkdir -p ".build/release-universal"
lipo -create "$ARM_BIN/SideScreen" "$X86_BIN/SideScreen" -output .build/release-universal/SideScreen
SPARKLE="$ARM_BIN/Sparkle.framework"
[ -d "$SPARKLE" ] || SPARKLE="$PWD/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"

# .app bundle (binary, Sparkle, icon, Info.plist) — shared with CI
APP_DIR="$ROOT_DIR/SideScreen.app"
echo "Creating app bundle..."
"$ROOT_DIR/scripts/package_mac_app.sh" .build/release-universal/SideScreen "$SPARKLE" "$VERSION" "$APP_DIR"

# Sign with the fork's stable identity when it is in the keychain
# (scripts/setup_fork_signing.sh), so permission grants survive rebuilds.
# SIDESCREEN_SIGN_IDENTITY overrides; otherwise ad-hoc.
IDENTITY="${SIDESCREEN_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] && security find-identity -p codesigning 2>/dev/null | grep -q "SideScreen Fork Code Signing"; then
    IDENTITY="SideScreen Fork Code Signing"
fi
echo "Code signing (${IDENTITY:-ad-hoc})..."
"$ROOT_DIR/scripts/sign_app.sh" "$APP_DIR" "${IDENTITY:--}"
echo "  ✓ App signed"

echo ""
echo "Build successful!"
echo ""
echo "App: $APP_DIR"
echo "To run: open $APP_DIR"

# Create DMG with Applications symlink
echo ""
echo "Creating DMG..."
"$ROOT_DIR/scripts/make_dmg.sh" "$APP_DIR" "$ROOT_DIR/SideScreen-${VERSION}-mac-universal.dmg"

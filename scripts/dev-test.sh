#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION=$(cat "$ROOT_DIR/VERSION" | tr -d '[:space:]')
APP_DIR="$ROOT_DIR/SideScreen.app"

echo "======================================="
echo "  Side Screen - Dev Test (v$VERSION)"
echo "======================================="
echo ""

# 1. Build macOS
echo "[1/5] Building macOS..."
cd "$ROOT_DIR/MacHost"
swift build -c release 2>&1 | tail -3
echo "  OK"

# 2. Create .app bundle — same layout and signing as release builds
# (scripts/package_mac_app.sh: Sparkle.framework is required at launch).
echo "[2/5] Creating .app bundle..."
BIN_DIR="$(swift build -c release --show-bin-path)"
SPARKLE="$BIN_DIR/Sparkle.framework"
[ -d "$SPARKLE" ] || SPARKLE="$PWD/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
"$ROOT_DIR/scripts/package_mac_app.sh" "$BIN_DIR/SideScreen" "$SPARKLE" "$VERSION" "$APP_DIR" >/dev/null
# The fork identity keeps permissions across rebuilds; ad-hoc when it isn't installed.
IDENTITY="${SIDESCREEN_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] && security find-identity -p codesigning 2>/dev/null | grep -q "SideScreen Fork Code Signing"; then
    IDENTITY="SideScreen Fork Code Signing"
fi
"$ROOT_DIR/scripts/sign_app.sh" "$APP_DIR" "${IDENTITY:--}" >/dev/null 2>&1
echo "  OK (${IDENTITY:-ad-hoc})"

# 3. Build Android
echo "[3/5] Building Android..."
cd "$ROOT_DIR/AndroidClient"
export JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
./gradlew assembleDebug -q
APK="$ROOT_DIR/AndroidClient/app/build/outputs/apk/debug/app-debug.apk"
echo "  OK"

# 4. Install APK on device
echo "[4/5] Installing APK..."
if adb devices | grep -q "device$"; then
    adb install -r "$APK" 2>&1 | tail -1
else
    echo "  No device connected, skipping install"
fi

# 5. Run macOS app
echo "[5/5] Starting macOS app..."
pkill -f "SideScreen.app" 2>/dev/null || true
sleep 0.5

adb reverse tcp:54321 tcp:54321 2>/dev/null || true
open "$APP_DIR"

echo ""
echo "======================================="
echo "  Ready to test!"
echo "  App: $APP_DIR"
echo "  Open Side Screen on your tablet"
echo "======================================="
echo ""
read -p "Test result? [y=OK / n=failed]: " RESULT

pkill -f "SideScreen.app" 2>/dev/null || true

if [ "$RESULT" = "y" ]; then
    echo ""
    echo "Test passed. Ready to push."
else
    echo ""
    echo "Test failed. Fix and re-run."
    exit 1
fi

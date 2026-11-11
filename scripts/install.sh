#!/bin/bash
set -e

# Navigate to project root (parent of scripts directory)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

echo "🚀 Installing Side Screen..."
echo ""

# Set JAVA_HOME for Android Studio's bundled JDK
export JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"

# Check Java
if [ ! -d "$JAVA_HOME" ]; then
  echo "❌ Java not found at: $JAVA_HOME"
  echo "   Please install Android Studio or set JAVA_HOME manually"
  exit 1
fi

# Check ADB connection first
echo "📱 Checking ADB connection..."
if ! adb devices | grep -q "device$"; then
  echo "❌ No Android device found via ADB"
  echo "   Please connect your device via USB and enable USB debugging"
  exit 1
fi
echo "  ✓ Android device connected"
echo ""

# Build macOS app
echo "📦 Building macOS app..."
cd MacHost
swift build -c release
cd "$ROOT_DIR"
echo "  ✓ macOS app built"

# Create macOS .app bundle — same layout and signing as release builds
# (scripts/package_mac_app.sh: Sparkle.framework is required at launch).
echo "📦 Creating macOS .app bundle..."
APP_NAME="SideScreen.app"
VERSION=$(tr -d '[:space:]' < VERSION)
BIN_DIR="$(cd MacHost && swift build -c release --show-bin-path)"
SPARKLE="$BIN_DIR/Sparkle.framework"
[ -d "$SPARKLE" ] || SPARKLE="$ROOT_DIR/MacHost/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
scripts/package_mac_app.sh "$BIN_DIR/SideScreen" "$SPARKLE" "$VERSION" "$APP_NAME"
IDENTITY="${SIDESCREEN_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] && security find-identity -p codesigning 2>/dev/null | grep -q "SideScreen Fork Code Signing"; then
  IDENTITY="SideScreen Fork Code Signing"
fi
scripts/sign_app.sh "$APP_NAME" "${IDENTITY:--}"

echo "  ✓ macOS .app bundle created: $APP_NAME"
echo ""

# Build Android app
echo "📦 Building Android app..."
cd AndroidClient
./gradlew assembleDebug
cd "$ROOT_DIR"
echo "  ✓ Android app built"
echo ""

# Install Android app
echo "📱 Installing Android app..."
adb install -r AndroidClient/app/build/outputs/apk/debug/app-debug.apk
echo "  ✓ Android app installed"
echo ""

# Setup ADB reverse (with retry)
echo "🔧 Setting up USB port forwarding..."
adb reverse --remove tcp:54321 2> /dev/null || true
sleep 0.5
adb reverse tcp:54321 tcp:54321

# Verify ADB reverse is active
echo "🔍 Verifying port forwarding..."
if adb reverse --list | grep -q "tcp:54321"; then
  echo "  ✓ Port 54321 forwarded successfully"
else
  echo "  ⚠️  Port forwarding setup but verification failed"
  echo "  Run './scripts/setup-usb.sh' if connection issues occur"
fi
echo ""

echo "✅ Installation complete!"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "To start streaming:"
echo "  1. Start Mac app: open SideScreen.app"
echo "     (or run: MacHost/.build/release/SideScreen)"
echo "  2. Open 'Side Screen' app on Android"
echo "  3. Tap Connect"
echo ""
echo "💡 Troubleshooting:"
echo "  • Connection fails: ./scripts/setup-usb.sh"
echo "  • Check server: lsof -i :54321"
echo "  • Check forwarding: adb reverse --list"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

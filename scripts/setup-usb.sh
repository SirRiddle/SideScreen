#!/bin/bash
set -e

echo "🔧 Setting up USB port forwarding..."

# Check ADB connection
if ! adb devices | grep -q "device$"; then
    echo "❌ No Android device found via ADB"
    echo ""
    echo "Troubleshooting:"
    echo "  1. Connect device via USB cable"
    echo "  2. Enable Developer Options on device"
    echo "  3. Enable USB Debugging in Developer Options"
    echo "  4. Accept the USB debugging prompt on device"
    echo "  5. Run this script again"
    exit 1
fi

echo "  ✓ Device connected"

# Remove existing reverse
echo "  Clearing existing port forwards..."
adb reverse --remove-all 2>/dev/null || true
sleep 0.5

# Setup new reverse
echo "  Setting up Port 54321..."
adb reverse tcp:54321 tcp:54321

# Verify
if adb reverse --list | grep -q "tcp:54321"; then
    echo ""
    echo "✅ USB port forwarding active!"
    echo ""
    adb reverse --list
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Ready to connect. Make sure Mac app is running."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
else
    echo "❌ Port forwarding failed"
    exit 1
fi

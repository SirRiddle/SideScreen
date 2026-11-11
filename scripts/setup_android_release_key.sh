#!/bin/bash
# One-time: the fork's Android release signing key. Every release APK must be
# signed with the same key, or installed apps can't update (Android refuses a
# different signature and the user has to uninstall, losing the saved pairing).
#
# Creates ~/.android/sidescreen-release.jks (alias "sidescreen") and keeps its
# password in the login keychain (service "SideScreen Android release key").
# Prints the `gh secret set` commands for CI; secret values are never echoed.
# BACK UP THE .jks AND ITS PASSWORD: GitHub secrets cannot be read back, and a
# lost key means every user must uninstall once more.
#
#   scripts/setup_android_release_key.sh
set -euo pipefail

KEYSTORE="${SIDESCREEN_KEYSTORE_PATH:-$HOME/.android/sidescreen-release.jks}"
ALIAS="sidescreen"
SERVICE="SideScreen Android release key"
# Addressed by path: don't depend on the user's keychain search list.
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
REPO="${SIDESCREEN_REPO:-SirRiddle/SideScreen}"
KEYTOOL="${JAVA_HOME:+$JAVA_HOME/bin/}keytool"

if [ -f "$KEYSTORE" ]; then
  echo "✓ $KEYSTORE already exists — not replacing it."
else
  mkdir -p "$(dirname "$KEYSTORE")"
  PASSWORD="$(openssl rand -base64 24 | tr -d '\n/+=' | cut -c1-24)"
  security add-generic-password -U -a "$ALIAS" -s "$SERVICE" -w "$PASSWORD" "$LOGIN_KEYCHAIN" >/dev/null
  "$KEYTOOL" -genkeypair -keystore "$KEYSTORE" -storetype PKCS12 -alias "$ALIAS" \
    -keyalg RSA -keysize 4096 -validity 10000 \
    -storepass "$PASSWORD" -keypass "$PASSWORD" \
    -dname "CN=SideScreen Fork Release, O=SideScreen Fork" >/dev/null 2>&1
  chmod 600 "$KEYSTORE"
  echo "✓ Created $KEYSTORE (password in the login keychain, service '$SERVICE')."
fi
echo "  SHA-256: $("$KEYTOOL" -list -keystore "$KEYSTORE" -alias "$ALIAS" \
  -storepass "$(security find-generic-password -a "$ALIAS" -s "$SERVICE" -w "$LOGIN_KEYCHAIN")" 2>/dev/null | awk -F': ' '/SHA-256|SHA256/{print $2; exit}')"

echo
echo "Set the CI secrets (values are read, never echoed):"
echo "  base64 -i '$KEYSTORE' | gh secret set ANDROID_KEYSTORE_BASE64 -R $REPO"
echo "  security find-generic-password -a $ALIAS -s '$SERVICE' -w '$LOGIN_KEYCHAIN' | tr -d '\\n' | gh secret set ANDROID_KEYSTORE_PASSWORD -R $REPO"
echo "Local release build:"
echo "  SIDESCREEN_KEYSTORE_PATH='$KEYSTORE' SIDESCREEN_KEYSTORE_PASSWORD=\"\$(security find-generic-password -a $ALIAS -s '$SERVICE' -w '$LOGIN_KEYCHAIN')\" ./gradlew assembleRelease"

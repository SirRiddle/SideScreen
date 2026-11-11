#!/bin/bash
# One-time setup of the fork's stable signing identities (re-run to rotate).
#
#  1. A self-signed code-signing certificate ("SideScreen Fork Code Signing"),
#     imported into the login keychain. Signing every build with the same
#     certificate keeps macOS's Screen Recording / Accessibility grants across
#     updates (ad-hoc builds get a new code hash each time, issue #77).
#  2. A Sparkle EdDSA key pair (account "sidescreen-fork"); the private key
#     lives in the login keychain, the public key goes into Info.plist
#     (SUPublicEDKey in scripts/package_mac_app.sh).
#
# Writes the material CI needs into OUT_DIR (default: a new private temp dir)
# and prints the `gh secret set` commands. Secret values are never printed.
# Delete OUT_DIR once the secrets are set.
#
#   scripts/setup_fork_signing.sh [OUT_DIR]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CERT_NAME="SideScreen Fork Code Signing"
SPARKLE_ACCOUNT="sidescreen-fork"
REPO="${SIDESCREEN_REPO:-SirRiddle/SideScreen}"
OUT_DIR="${1:-$(mktemp -d -t sidescreen-signing)}"
GENERATE_KEYS="$ROOT_DIR/MacHost/.build/artifacts/sparkle/Sparkle/bin/generate_keys"

mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"
umask 077

if [ ! -x "$GENERATE_KEYS" ]; then
  echo "Resolving Swift packages for Sparkle's generate_keys..."
  (cd "$ROOT_DIR/MacHost" && swift package resolve)
fi

# --- 1. Code-signing certificate -------------------------------------------
if security find-certificate -c "$CERT_NAME" >/dev/null 2>&1; then
  echo "✓ '$CERT_NAME' already in the keychain — not replacing it."
  echo "  To rotate, delete it in Keychain Access first. CI needs the matching .p12;"
  echo "  if you no longer have it, export the identity from Keychain Access."
else
  echo "Creating '$CERT_NAME' (self-signed, 10 years)..."
  cat > "$OUT_DIR/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $CERT_NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF
  /usr/bin/openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$OUT_DIR/key.pem" -out "$OUT_DIR/cert.pem" -config "$OUT_DIR/cert.cnf" 2>/dev/null
  /usr/bin/openssl rand -base64 24 | tr -d '\n' > "$OUT_DIR/signing.p12.password"
  # LibreSSL (/usr/bin/openssl) writes a PKCS#12 that `security import` reads.
  /usr/bin/openssl pkcs12 -export -name "$CERT_NAME" \
    -inkey "$OUT_DIR/key.pem" -in "$OUT_DIR/cert.pem" \
    -passout "file:$OUT_DIR/signing.p12.password" -out "$OUT_DIR/signing.p12"
  rm -f "$OUT_DIR/key.pem" "$OUT_DIR/cert.cnf"
  security import "$OUT_DIR/signing.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P "$(cat "$OUT_DIR/signing.p12.password")" -T /usr/bin/codesign >/dev/null
  echo "✓ Imported into the login keychain."
  echo "  Certificate SHA-1: $(/usr/bin/openssl x509 -in "$OUT_DIR/cert.pem" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d :)"
fi

# --- 2. Sparkle EdDSA keys ---------------------------------------------------
"$GENERATE_KEYS" --account "$SPARKLE_ACCOUNT" >/dev/null
PUBLIC_KEY="$("$GENERATE_KEYS" --account "$SPARKLE_ACCOUNT" -p)"
printf '%s\n' "$PUBLIC_KEY" > "$OUT_DIR/sparkle_public_key"
rm -f "$OUT_DIR/sparkle_private_key"
"$GENERATE_KEYS" --account "$SPARKLE_ACCOUNT" -x "$OUT_DIR/sparkle_private_key" >/dev/null
echo "✓ Sparkle key pair in the login keychain (account '$SPARKLE_ACCOUNT')."
echo "  SUPublicEDKey: $PUBLIC_KEY"

# --- 3. What CI needs --------------------------------------------------------
echo
echo "Material for GitHub Actions is in: $OUT_DIR"
echo "Set the secrets (values are read from the files, never echoed):"
if [ -f "$OUT_DIR/signing.p12" ]; then
  echo "  base64 -i '$OUT_DIR/signing.p12' | gh secret set MAC_SIGNING_P12_BASE64 -R $REPO"
  echo "  gh secret set MAC_SIGNING_P12_PASSWORD -R $REPO < '$OUT_DIR/signing.p12.password'"
fi
echo "  gh secret set SPARKLE_PRIVATE_KEY -R $REPO < '$OUT_DIR/sparkle_private_key'"
echo "Then delete the folder: rm -rf '$OUT_DIR'"

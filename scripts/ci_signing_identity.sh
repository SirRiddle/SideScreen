#!/bin/bash
# CI: import the fork's code-signing identity from secrets into a temporary
# keychain. Prints `identity=<SHA-1>` and `keychain=<path>` for $GITHUB_OUTPUT,
# or `identity=-` (ad-hoc) when the secrets are not set (e.g. on forks of the fork).
#
#   env MAC_SIGNING_P12_BASE64=... MAC_SIGNING_P12_PASSWORD=... scripts/ci_signing_identity.sh
set -euo pipefail

if [ -z "${MAC_SIGNING_P12_BASE64:-}" ] || [ -z "${MAC_SIGNING_P12_PASSWORD:-}" ]; then
  echo "::warning::MAC_SIGNING_P12_BASE64 / MAC_SIGNING_P12_PASSWORD not set — ad-hoc signing (permissions reset on every update)" >&2
  echo "identity=-"
  exit 0
fi

DIR="${RUNNER_TEMP:-$(mktemp -d)}"
KEYCHAIN="$DIR/signing.keychain-db"
KEYCHAIN_PASSWORD="$(openssl rand -hex 16)"
printf '%s' "$MAC_SIGNING_P12_BASE64" | base64 --decode > "$DIR/signing.p12"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 3600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$DIR/signing.p12" -k "$KEYCHAIN" -P "$MAC_SIGNING_P12_PASSWORD" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
rm -f "$DIR/signing.p12"
# codesign looks identities up through the search list.
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')

IDENTITY="$(security find-identity -p codesigning "$KEYCHAIN" | awk '/SideScreen Fork Code Signing/ {print $2; exit}')"
if [ -z "$IDENTITY" ]; then
  echo "::error::No 'SideScreen Fork Code Signing' identity in MAC_SIGNING_P12_BASE64" >&2
  exit 1
fi
echo "identity=$IDENTITY"
echo "keychain=$KEYCHAIN"

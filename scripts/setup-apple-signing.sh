#!/usr/bin/env bash
set -euo pipefail

PROFILE_NAME=${NOTARYTOOL_KEYCHAIN_PROFILE:-buffer-notary}
SIGNING_KEYCHAIN_PATH=${SIGNING_KEYCHAIN_PATH:-$HOME/Library/Keychains/buffer-signing.keychain-db}
SIGNING_KEYCHAIN_SERVICE=${SIGNING_KEYCHAIN_SERVICE:-buffer-signing-keychain}
APPLE_API_KEY_PATH=${APPLE_API_KEY_PATH:-}
APPLE_API_KEY=${APPLE_API_KEY:-}
APPLE_API_ISSUER=${APPLE_API_ISSUER:-}
APPLE_API_KEY_CONTENT=${APPLE_API_KEY_CONTENT:-}
APPLE_CERTIFICATE=${APPLE_CERTIFICATE:-}
APPLE_CERTIFICATE_PASSWORD=${APPLE_CERTIFICATE_PASSWORD:-}

usage() {
  cat <<EOF
Usage: $(basename "$0")

Reads Apple signing and notarization credentials from environment variables.
Use it with any local secret manager or shell environment that exports the
required APPLE_* variables.

Supported environment variables:
  APPLE_CERTIFICATE              Base64-encoded .p12 Developer ID certificate
  APPLE_CERTIFICATE_PASSWORD     Password for the .p12 certificate
  APPLE_API_KEY                  App Store Connect API key ID
  APPLE_API_ISSUER               App Store Connect issuer ID
  APPLE_API_KEY_PATH             Path to AuthKey_XXXX.p8
  APPLE_API_KEY_CONTENT          Contents of the AuthKey_XXXX.p8 file
  NOTARYTOOL_KEYCHAIN_PROFILE    notarytool profile name (default: buffer-notary)
  SIGNING_KEYCHAIN_PATH          Keychain path for persistent Developer ID cert
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  usage
  exit 0
fi

for cmd in security xcrun base64 openssl; do
  require_cmd "$cmd"
done

if [[ -n "$APPLE_API_KEY_CONTENT" && -z "$APPLE_API_KEY_PATH" && -n "$APPLE_API_KEY" ]]; then
  APPLE_API_KEY_PATH="$HOME/private_keys/AuthKey_${APPLE_API_KEY}.p8"
fi

if [[ -n "$APPLE_API_KEY_CONTENT" ]]; then
  if [[ -z "$APPLE_API_KEY_PATH" ]]; then
    echo "APPLE_API_KEY_PATH is required when APPLE_API_KEY_CONTENT is set" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$APPLE_API_KEY_PATH")"
  printf '%s' "$APPLE_API_KEY_CONTENT" > "$APPLE_API_KEY_PATH"
  chmod 600 "$APPLE_API_KEY_PATH"
fi

if [[ -n "$APPLE_API_KEY" || -n "$APPLE_API_ISSUER" || -n "$APPLE_API_KEY_PATH" ]]; then
  if [[ -z "$APPLE_API_KEY" || -z "$APPLE_API_ISSUER" || -z "$APPLE_API_KEY_PATH" ]]; then
    echo "APPLE_API_KEY, APPLE_API_ISSUER, and APPLE_API_KEY_PATH must all be set for notarization" >&2
    exit 1
  fi
  if [[ ! -f "$APPLE_API_KEY_PATH" ]]; then
    echo "API key file not found: $APPLE_API_KEY_PATH" >&2
    exit 1
  fi

  echo "==> Storing notarytool credentials profile '$PROFILE_NAME'"
  xcrun notarytool store-credentials "$PROFILE_NAME" \
    --key "$APPLE_API_KEY_PATH" \
    --key-id "$APPLE_API_KEY" \
    --issuer "$APPLE_API_ISSUER" >/dev/null
  echo "Stored notarytool profile: $PROFILE_NAME"
fi

if [[ -n "$APPLE_CERTIFICATE" ]]; then
  if [[ -z "$APPLE_CERTIFICATE_PASSWORD" ]]; then
    echo "APPLE_CERTIFICATE_PASSWORD is required when APPLE_CERTIFICATE is set" >&2
    exit 1
  fi

  existing_pw=$(security find-generic-password -a "$USER" -s "$SIGNING_KEYCHAIN_SERVICE" -w 2>/dev/null || true)
  if [[ -n "$existing_pw" && -f "$SIGNING_KEYCHAIN_PATH" ]]; then
    security delete-keychain "$SIGNING_KEYCHAIN_PATH" >/dev/null 2>&1 || true
    security delete-generic-password -a "$USER" -s "$SIGNING_KEYCHAIN_SERVICE" >/dev/null 2>&1 || true
  fi

  keychain_password=$(openssl rand -base64 24 | tr -d '\n')

  cert_file=$(mktemp /tmp/buffer-cert.XXXXXX.p12)
  cleanup() {
    rm -f "$cert_file"
  }
  trap cleanup EXIT

  printf '%s' "$APPLE_CERTIFICATE" | base64 --decode > "$cert_file"

  echo "==> Creating signing keychain at $SIGNING_KEYCHAIN_PATH"
  security create-keychain -p "$keychain_password" "$SIGNING_KEYCHAIN_PATH" >/dev/null
  security unlock-keychain -p "$keychain_password" "$SIGNING_KEYCHAIN_PATH"
  security set-keychain-settings -lut 21600 "$SIGNING_KEYCHAIN_PATH"
  security import "$cert_file" \
    -k "$SIGNING_KEYCHAIN_PATH" \
    -P "$APPLE_CERTIFICATE_PASSWORD" \
    -T /usr/bin/codesign \
    -T /usr/bin/security \
    -T /usr/bin/productbuild >/dev/null
  security set-key-partition-list \
    -S apple-tool:,apple:,codesign:,productsign: \
    -s -k "$keychain_password" \
    "$SIGNING_KEYCHAIN_PATH" >/dev/null

  current_keychains=$(security list-keychains -d user | sed 's/[[:space:]"]//g' | tr '\n' ' ')
  if [[ "$current_keychains" != *"$SIGNING_KEYCHAIN_PATH"* ]]; then
    security list-keychains -d user -s "$SIGNING_KEYCHAIN_PATH" "$HOME/Library/Keychains/login.keychain-db" /Library/Keychains/System.keychain >/dev/null
  fi

  security add-generic-password -U -a "$USER" -s "$SIGNING_KEYCHAIN_SERVICE" -w "$keychain_password" >/dev/null

  echo "Stored keychain password in login keychain service '$SIGNING_KEYCHAIN_SERVICE'"
  echo "Available Developer ID identities:"
  security find-identity -v -p codesigning "$SIGNING_KEYCHAIN_PATH" | grep 'Developer ID Application' || true
fi

echo "==> Apple signing bootstrap complete"

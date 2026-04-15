#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
SCHEME=${SCHEME:-Buffer}
PROJECT=${PROJECT:-$ROOT_DIR/Buffer.xcodeproj}
CONFIGURATION=${CONFIGURATION:-Release}
UPDATES_REPO=${UPDATES_REPO:-wattsjs/buffer-updates}
DOWNLOAD_URL_PREFIX=${DOWNLOAD_URL_PREFIX:-https://raw.githubusercontent.com/$UPDATES_REPO/main/}
PRODUCT_NAME=${PRODUCT_NAME:-Buffer}
SPARKLE_VERSION=${SPARKLE_VERSION:-2.9.1}
DIST_DIR=${DIST_DIR:-$ROOT_DIR/dist}
RELEASE_NOTES_FILE=${RELEASE_NOTES_FILE:-}
NOTARYTOOL_KEYCHAIN_PROFILE=${NOTARYTOOL_KEYCHAIN_PROFILE:-buffer-notary}
APPLE_API_KEY_PATH=${APPLE_API_KEY_PATH:-}
APPLE_API_KEY=${APPLE_API_KEY:-}
APPLE_API_ISSUER=${APPLE_API_ISSUER:-}
APPLE_API_KEY_CONTENT=${APPLE_API_KEY_CONTENT:-}
APPLE_CERTIFICATE=${APPLE_CERTIFICATE:-}
APPLE_CERTIFICATE_PASSWORD=${APPLE_CERTIFICATE_PASSWORD:-}
TEAM_ID=${TEAM_ID:-Q7YAQ49F8V}
SIGNING_KEYCHAIN_PATH=${SIGNING_KEYCHAIN_PATH:-$HOME/Library/Keychains/buffer-signing.keychain-db}
SIGNING_KEYCHAIN_SERVICE=${SIGNING_KEYCHAIN_SERVICE:-buffer-signing-keychain}
DEVELOPER_ID_APPLICATION=${DEVELOPER_ID_APPLICATION:-${APPLE_SIGNING_IDENTITY:-}}
TEMP_KEYCHAIN_PATH=""
TEMP_KEYCHAIN_PASSWORD=""
ORIGINAL_DEFAULT_KEYCHAIN=""
ORIGINAL_KEYCHAIN_LIST=""
NOTARY_MODE="profile"
NOTARY_ARGS=()
KEYCHAIN_BUILD_FLAGS=()

usage() {
  cat <<EOF
Usage: $(basename "$0")

Release Buffer for direct distribution and Sparkle updates.

Preferred setup:
  1. Run scripts/setup-apple-signing.sh once using APPLE_* secrets
  2. Run this script normally

Environment variables supported:
  DEVELOPER_ID_APPLICATION      Common name of your Developer ID Application cert
  NOTARYTOOL_KEYCHAIN_PROFILE   notarytool profile name (default: $NOTARYTOOL_KEYCHAIN_PROFILE)
  APPLE_CERTIFICATE             Base64-encoded .p12 Developer ID cert (optional fallback)
  APPLE_CERTIFICATE_PASSWORD    Password for the .p12 cert
  APPLE_API_KEY                 App Store Connect API key ID
  APPLE_API_ISSUER              App Store Connect issuer ID
  APPLE_API_KEY_PATH            Path to AuthKey_XXXX.p8
  APPLE_API_KEY_CONTENT         Contents of AuthKey_XXXX.p8 (writes to APPLE_API_KEY_PATH)
  TEAM_ID                       Apple Developer Team ID (default: $TEAM_ID)
  SCHEME                        Xcode scheme (default: $SCHEME)
  PROJECT                       Path to .xcodeproj (default: $PROJECT)
  CONFIGURATION                 Build configuration (default: $CONFIGURATION)
  UPDATES_REPO                  Sparkle feed repo (default: $UPDATES_REPO)
  DOWNLOAD_URL_PREFIX           Public base URL for appcast assets
  PRODUCT_NAME                  Exported app name (default: $PRODUCT_NAME)
  DIST_DIR                      Output directory for local artifacts
  RELEASE_NOTES_FILE            Optional .md/.html/.txt release notes file
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

cleanup() {
  local status=$?
  if [[ -n "$TEMP_KEYCHAIN_PATH" && -f "$TEMP_KEYCHAIN_PATH" ]]; then
    security delete-keychain "$TEMP_KEYCHAIN_PATH" >/dev/null 2>&1 || true
  fi
  if [[ -n "$ORIGINAL_KEYCHAIN_LIST" ]]; then
    # shellcheck disable=SC2086
    security list-keychains -d user -s $ORIGINAL_KEYCHAIN_LIST >/dev/null 2>&1 || true
  fi
  if [[ -n "$ORIGINAL_DEFAULT_KEYCHAIN" ]]; then
    security default-keychain -s "$ORIGINAL_DEFAULT_KEYCHAIN" >/dev/null 2>&1 || true
  fi
  exit $status
}
trap cleanup EXIT

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  usage
  exit 0
fi

for cmd in gh git xcodebuild xcrun ditto hdiutil security tar base64 codesign openssl; do
  require_cmd "$cmd"
done

ensure_api_key_file() {
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
}

setup_temp_keychain_from_env() {
  [[ -n "$APPLE_CERTIFICATE" && -n "$APPLE_CERTIFICATE_PASSWORD" ]] || return 1

  ORIGINAL_DEFAULT_KEYCHAIN=$(security default-keychain | tr -d '"')
  ORIGINAL_KEYCHAIN_LIST=$(security list-keychains -d user | tr -d '"')

  TEMP_KEYCHAIN_PATH=$(mktemp -u "$RUNNER_TEMP/buffer-signing.XXXXXX.keychain-db" 2>/dev/null || mktemp -u /tmp/buffer-signing.XXXXXX.keychain-db)
  TEMP_KEYCHAIN_PASSWORD=$(openssl rand -base64 24 | tr -d '\n')
  local cert_file
  cert_file=$(mktemp /tmp/buffer-cert.XXXXXX.p12)
  printf '%s' "$APPLE_CERTIFICATE" | base64 --decode > "$cert_file"

  security create-keychain -p "$TEMP_KEYCHAIN_PASSWORD" "$TEMP_KEYCHAIN_PATH" >/dev/null
  security unlock-keychain -p "$TEMP_KEYCHAIN_PASSWORD" "$TEMP_KEYCHAIN_PATH"
  security set-keychain-settings -lut 21600 "$TEMP_KEYCHAIN_PATH"
  security import "$cert_file" \
    -k "$TEMP_KEYCHAIN_PATH" \
    -P "$APPLE_CERTIFICATE_PASSWORD" \
    -T /usr/bin/codesign \
    -T /usr/bin/security \
    -T /usr/bin/productbuild >/dev/null
  security set-key-partition-list \
    -S apple-tool:,apple:,codesign:,productsign: \
    -s -k "$TEMP_KEYCHAIN_PASSWORD" \
    "$TEMP_KEYCHAIN_PATH" >/dev/null

  security list-keychains -d user -s "$TEMP_KEYCHAIN_PATH" "$HOME/Library/Keychains/login.keychain-db" /Library/Keychains/System.keychain >/dev/null
  security default-keychain -s "$TEMP_KEYCHAIN_PATH" >/dev/null
  rm -f "$cert_file"
  return 0
}

detect_signing_identity() {
  local search_target=${1:-}
  local identity=""
  if [[ -n "$search_target" ]]; then
    identity=$(security find-identity -v -p codesigning "$search_target" 2>/dev/null | grep 'Developer ID Application' | head -1 | sed -n 's/.*"\(.*\)".*/\1/p')
  else
    identity=$(security find-identity -v -p codesigning 2>/dev/null | grep 'Developer ID Application' | head -1 | sed -n 's/.*"\(.*\)".*/\1/p')
  fi
  printf '%s' "$identity"
}

setup_notary_args() {
  if xcrun notarytool history --keychain-profile "$NOTARYTOOL_KEYCHAIN_PROFILE" >/dev/null 2>&1; then
    NOTARY_MODE="profile"
    NOTARY_ARGS=(--keychain-profile "$NOTARYTOOL_KEYCHAIN_PROFILE")
    return 0
  fi

  ensure_api_key_file
  if [[ -n "$APPLE_API_KEY" && -n "$APPLE_API_ISSUER" && -n "$APPLE_API_KEY_PATH" ]]; then
    NOTARY_MODE="api"
    NOTARY_ARGS=(--key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY" --issuer "$APPLE_API_ISSUER")
    return 0
  fi

  echo "No usable notarization credentials found." >&2
  echo "Either configure notarytool profile '$NOTARYTOOL_KEYCHAIN_PROFILE' or set APPLE_API_KEY / APPLE_API_ISSUER / APPLE_API_KEY_PATH." >&2
  exit 1
}

setup_signing() {
  if [[ -n "$DEVELOPER_ID_APPLICATION" ]] && security find-identity -v -p codesigning 2>/dev/null | grep -Fq "$DEVELOPER_ID_APPLICATION"; then
    return 0
  fi

  if [[ -f "$SIGNING_KEYCHAIN_PATH" ]]; then
    DEVELOPER_ID_APPLICATION=$(detect_signing_identity "$SIGNING_KEYCHAIN_PATH")
    if [[ -n "$DEVELOPER_ID_APPLICATION" ]]; then
      KEYCHAIN_BUILD_FLAGS=(OTHER_CODE_SIGN_FLAGS="--keychain $SIGNING_KEYCHAIN_PATH")
      return 0
    fi
  fi

  if setup_temp_keychain_from_env; then
    DEVELOPER_ID_APPLICATION=$(detect_signing_identity "$TEMP_KEYCHAIN_PATH")
    if [[ -n "$DEVELOPER_ID_APPLICATION" ]]; then
      KEYCHAIN_BUILD_FLAGS=(OTHER_CODE_SIGN_FLAGS="--keychain $TEMP_KEYCHAIN_PATH")
      return 0
    fi
  fi

  if [[ -z "$DEVELOPER_ID_APPLICATION" ]]; then
    DEVELOPER_ID_APPLICATION=$(detect_signing_identity)
  fi

  if [[ -z "$DEVELOPER_ID_APPLICATION" ]]; then
    echo "Developer ID Application certificate not found. Run scripts/setup-apple-signing.sh or provide APPLE_CERTIFICATE + APPLE_CERTIFICATE_PASSWORD." >&2
    exit 1
  fi
}

setup_notary_args
setup_signing

SPARKLE_CACHE_DIR=${SPARKLE_CACHE_DIR:-$HOME/.cache/buffer/sparkle-$SPARKLE_VERSION}
SPARKLE_BIN_DIR=$SPARKLE_CACHE_DIR/bin
mkdir -p "$SPARKLE_CACHE_DIR"

if [[ ! -x "$SPARKLE_BIN_DIR/generate_appcast" ]]; then
  tmp_download=$(mktemp -d)
  gh release download "$SPARKLE_VERSION" --repo sparkle-project/Sparkle --pattern "Sparkle-$SPARKLE_VERSION.tar.xz" --dir "$tmp_download" >/dev/null
  tar -xf "$tmp_download/Sparkle-$SPARKLE_VERSION.tar.xz" -C "$SPARKLE_CACHE_DIR"
  rm -rf "$tmp_download"
fi

BUILD_SETTINGS=$(xcodebuild -showBuildSettings -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION")
MARKETING_VERSION=$(printf '%s\n' "$BUILD_SETTINGS" | awk -F ' = ' '/MARKETING_VERSION/ {print $2; exit}')
BUILD_NUMBER=$(printf '%s\n' "$BUILD_SETTINGS" | awk -F ' = ' '/CURRENT_PROJECT_VERSION/ {print $2; exit}')
BUNDLE_IDENTIFIER=$(printf '%s\n' "$BUILD_SETTINGS" | awk -F ' = ' '/PRODUCT_BUNDLE_IDENTIFIER/ {print $2; exit}')

if [[ -z "$MARKETING_VERSION" || -z "$BUILD_NUMBER" || -z "$BUNDLE_IDENTIFIER" ]]; then
  echo "Failed to read version or bundle identifier from build settings" >&2
  exit 1
fi

RELEASE_BASENAME="Buffer-${MARKETING_VERSION}-${BUILD_NUMBER}"
WORK_DIR=$(mktemp -d)
ARCHIVE_PATH="$WORK_DIR/$RELEASE_BASENAME.xcarchive"
EXPORT_DIR="$WORK_DIR/export"
UPDATES_CLONE="$WORK_DIR/updates"
LOCAL_RELEASE_DIR="$DIST_DIR/$RELEASE_BASENAME"
mkdir -p "$EXPORT_DIR" "$LOCAL_RELEASE_DIR" "$DIST_DIR"

EXPORT_OPTIONS="$WORK_DIR/ExportOptions.plist"
cat > "$EXPORT_OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>stripSwiftSymbols</key>
  <true/>
  <key>teamID</key>
  <string>$TEAM_ID</string>
</dict>
</plist>
EOF

echo "==> Using Developer ID identity: $DEVELOPER_ID_APPLICATION"
echo "==> Notarization mode: $NOTARY_MODE"

echo "==> Archiving $PRODUCT_NAME"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -archivePath "$ARCHIVE_PATH" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  "${KEYCHAIN_BUILD_FLAGS[@]}"

echo "==> Exporting Developer ID app"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  "${KEYCHAIN_BUILD_FLAGS[@]}"

APP_PATH="$EXPORT_DIR/$PRODUCT_NAME.app"
ZIP_PATH="$LOCAL_RELEASE_DIR/$RELEASE_BASENAME.zip"
DMG_PATH="$LOCAL_RELEASE_DIR/$RELEASE_BASENAME.dmg"
NOTARY_ZIP_PATH="$WORK_DIR/$RELEASE_BASENAME-notary.zip"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Exported app not found: $APP_PATH" >&2
  exit 1
fi

echo "==> Verifying code signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "==> Creating notarization zip"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$NOTARY_ZIP_PATH"

echo "==> Notarizing app bundle"
xcrun notarytool submit "$NOTARY_ZIP_PATH" "${NOTARY_ARGS[@]}" --wait
xcrun stapler staple "$APP_PATH"

echo "==> Creating Sparkle zip"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> Creating DMG"
DMG_STAGING_DIR="$WORK_DIR/dmg-staging"
mkdir -p "$DMG_STAGING_DIR"
cp -R "$APP_PATH" "$DMG_STAGING_DIR/"
ln -s /Applications "$DMG_STAGING_DIR/Applications"
hdiutil create -volname "$PRODUCT_NAME" -srcfolder "$DMG_STAGING_DIR" -ov -format UDZO "$DMG_PATH" >/dev/null
codesign --force --sign "$DEVELOPER_ID_APPLICATION" "$DMG_PATH"

echo "==> Notarizing DMG"
xcrun notarytool submit "$DMG_PATH" "${NOTARY_ARGS[@]}" --wait
xcrun stapler staple "$DMG_PATH"

echo "==> Updating Sparkle feed repo: $UPDATES_REPO"
git clone "https://github.com/$UPDATES_REPO.git" "$UPDATES_CLONE" >/dev/null 2>&1
cp "$ZIP_PATH" "$UPDATES_CLONE/"

if [[ -n "$RELEASE_NOTES_FILE" ]]; then
  notes_ext=${RELEASE_NOTES_FILE##*.}
  cp "$RELEASE_NOTES_FILE" "$UPDATES_CLONE/$RELEASE_BASENAME.$notes_ext"
fi

"$SPARKLE_BIN_DIR/generate_appcast" \
  --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
  --link "https://github.com/wattsjs/buffer" \
  "$UPDATES_CLONE"

(
  cd "$UPDATES_CLONE"
  git add appcast.xml "$RELEASE_BASENAME.zip"
  if [[ -n "$RELEASE_NOTES_FILE" ]]; then
    git add "$RELEASE_BASENAME."*
  fi
  git commit -m "Publish $RELEASE_BASENAME" >/dev/null
  git push origin main >/dev/null
)

echo "==> Done"
echo "App: $APP_PATH"
echo "ZIP: $ZIP_PATH"
echo "DMG: $DMG_PATH"
echo "Feed: $DOWNLOAD_URL_PREFIX/appcast.xml"

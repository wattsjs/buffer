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
TEAM_ID=${TEAM_ID:-Q7YAQ49F8V}
SIGNING_KEYCHAIN_PATH=${SIGNING_KEYCHAIN_PATH:-$HOME/Library/Keychains/buffer-signing.keychain-db}
SIGNING_KEYCHAIN_SERVICE=${SIGNING_KEYCHAIN_SERVICE:-buffer-signing-keychain}
DEVELOPER_ID_APPLICATION=${DEVELOPER_ID_APPLICATION:-${APPLE_SIGNING_IDENTITY:-}}
ORIGINAL_DEFAULT_KEYCHAIN=""
ORIGINAL_KEYCHAIN_LIST=""
NOTARY_ARGS=()
KEYCHAIN_BUILD_FLAGS=()

usage() {
  cat <<EOF
Usage: $(basename "$0")

Release Buffer for direct distribution and Sparkle updates.

Preferred setup:
  Configure signing and notarization credentials outside the repository, then
  run this script from a clean checkout.

Environment variables supported:
  DEVELOPER_ID_APPLICATION      Common name of your Developer ID Application cert
  NOTARYTOOL_KEYCHAIN_PROFILE   notarytool profile name (default: $NOTARYTOOL_KEYCHAIN_PROFILE)
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

for cmd in gh git xcodebuild xcrun ditto hdiutil security tar codesign create-dmg; do
  require_cmd "$cmd"
done

activate_signing_keychain() {
  local keychain_path=$1
  local keychain_password=""

  ORIGINAL_DEFAULT_KEYCHAIN=$(security default-keychain | tr -d '"')
  ORIGINAL_KEYCHAIN_LIST=$(security list-keychains -d user | tr -d '"')

  keychain_password=$(security find-generic-password -a "$USER" -s "$SIGNING_KEYCHAIN_SERVICE" -w 2>/dev/null || true)
  if [[ -n "$keychain_password" ]]; then
    security unlock-keychain -p "$keychain_password" "$keychain_path" >/dev/null
  else
    security unlock-keychain "$keychain_path" >/dev/null 2>&1 || true
  fi
  security list-keychains -d user -s "$keychain_path" "$HOME/Library/Keychains/login.keychain-db" /Library/Keychains/System.keychain >/dev/null
  security default-keychain -s "$keychain_path" >/dev/null
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
    NOTARY_ARGS=(--keychain-profile "$NOTARYTOOL_KEYCHAIN_PROFILE")
    return 0
  fi

  echo "No usable notarization credentials found." >&2
  echo "Configure notarytool profile '$NOTARYTOOL_KEYCHAIN_PROFILE' outside this repository." >&2
  exit 1
}

setup_signing() {
  if [[ -n "$DEVELOPER_ID_APPLICATION" ]] && security find-identity -v -p codesigning 2>/dev/null | grep -Fq "$DEVELOPER_ID_APPLICATION"; then
    return 0
  fi

  if [[ -f "$SIGNING_KEYCHAIN_PATH" ]]; then
    DEVELOPER_ID_APPLICATION=$(detect_signing_identity "$SIGNING_KEYCHAIN_PATH")
    if [[ -n "$DEVELOPER_ID_APPLICATION" ]]; then
      activate_signing_keychain "$SIGNING_KEYCHAIN_PATH"
      KEYCHAIN_BUILD_FLAGS=(OTHER_CODE_SIGN_FLAGS="--keychain $SIGNING_KEYCHAIN_PATH")
      return 0
    fi
  fi

  if [[ -z "$DEVELOPER_ID_APPLICATION" ]]; then
    DEVELOPER_ID_APPLICATION=$(detect_signing_identity)
  fi

  if [[ -z "$DEVELOPER_ID_APPLICATION" ]]; then
    echo "Developer ID Application certificate not found. Configure signing outside this repository before releasing." >&2
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
echo "==> Notarization profile: $NOTARYTOOL_KEYCHAIN_PROFILE"

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

# Extract .icns from the built app for use as volume icon
APP_ICNS="$APP_PATH/Contents/Resources/AppIcon.icns"
VOLICON_ARGS=()
if [[ -f "$APP_ICNS" ]]; then
  VOLICON_ARGS=(--volicon "$APP_ICNS")
fi

# Use create-dmg for a polished installer window
create-dmg \
  --volname "$PRODUCT_NAME" \
  "${VOLICON_ARGS[@]}" \
  --window-pos 200 120 \
  --window-size 660 400 \
  --icon-size 128 \
  --icon "$PRODUCT_NAME.app" 180 170 \
  --app-drop-link 480 170 \
  --hide-extension "$PRODUCT_NAME.app" \
  --no-internet-enable \
  --codesign "$DEVELOPER_ID_APPLICATION" \
  "$DMG_PATH" \
  "$DMG_STAGING_DIR"

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

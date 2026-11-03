#!/usr/bin/env bash
# Runs the iOS/iPadOS or tvOS UI walk-through on a simulator against the
# loopback Xtream fixture, then exports the attached screenshots.
#   scripts/test-touch-ui.sh ios "iPhone 17 Pro"
#   scripts/test-touch-ui.sh ios "iPad Pro 13-inch (M5)"
#   scripts/test-touch-ui.sh tvos "Apple TV 4K (3rd generation)"
# Start the fixture first: python3 scripts/fake_xtream_server.py
set -euo pipefail
cd "$(dirname "$0")/.."
platform="${1:?usage: test-touch-ui.sh ios|tvos DEVICE}"
device="${2:?device name}"
case "$platform" in
  ios) scheme="Buffer iOS"; os="iOS Simulator" ;;
  tvos) scheme="Buffer tvOS"; os="tvOS Simulator" ;;
  *) echo "unknown platform: $platform" >&2; exit 64 ;;
esac
slug="$(echo "$device" | tr -c 'A-Za-z0-9' '-' | tr -s '-' | sed 's/-$//')"
result=".logs/ui-$slug.xcresult"
shots=".logs/shots/$slug"
rm -rf "$result" "$shots"
mkdir -p "$shots"
package_args=()
if [[ -n "${BUFFER_PACKAGES_DIR:-}" ]]; then package_args=(-clonedSourcePackagesDirPath "$BUFFER_PACKAGES_DIR"); fi
# Start from an empty library so the walk-through adds the source itself.
xcrun simctl uninstall "$device" com.wattsjs.buffer 2>/dev/null || true
status=0
xcodebuild -project Buffer.xcodeproj -scheme "$scheme" -destination "platform=$os,name=$device" \
  -derivedDataPath ".build/dd-$platform" ${package_args[@]+"${package_args[@]}"} \
  -resultBundlePath "$result" test > ".logs/ui-$slug.log" 2>&1 || status=$?
xcrun xcresulttool export attachments --path "$result" --output-path "$shots" > /dev/null 2>&1 || true
echo "status=$status screenshots=$shots"
grep -E "error:|failed|passed" ".logs/ui-$slug.log" | tail -8
exit $status

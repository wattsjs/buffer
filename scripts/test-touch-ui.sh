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
# BUFFER_SEED_FIXTURES optionally seeds the saved ESPN fixture cache (for
# example the Mac app's) so Sports has events when ESPN is unreachable.
common=(-project Buffer.xcodeproj -scheme "$scheme" -destination "platform=$os,name=$device"
  -derivedDataPath ".build/dd-$platform" ${package_args[@]+"${package_args[@]}"})
xcodebuild "${common[@]}" build-for-testing > ".logs/ui-$slug-build.log" 2>&1 || { tail -20 ".logs/ui-$slug-build.log"; exit 1; }
xcrun simctl boot "$device" 2>/dev/null || true
xcrun simctl uninstall "$device" com.wattsjs.buffer 2>/dev/null || true
if [[ -n "${BUFFER_SEED_FIXTURES:-}" ]]; then
  sdk=$([[ $platform == ios ]] && echo iphonesimulator || echo appletvsimulator)
  xcrun simctl install "$device" ".build/dd-$platform/Build/Products/Debug-$sdk/Buffer.app"
  container="$(xcrun simctl get_app_container "$device" com.wattsjs.buffer data)"
  mkdir -p "$container/Library/Caches/buffer"
  cp "$BUFFER_SEED_FIXTURES" "$container/Library/Caches/buffer/sports-fixtures-v1.json"
fi
status=0
xcodebuild "${common[@]}" -resultBundlePath "$result" -collect-test-diagnostics never \
  test-without-building > ".logs/ui-$slug.log" 2>&1 || status=$?
xcrun xcresulttool export attachments --path "$result" --output-path "$shots" > /dev/null 2>&1 &
export_pid=$!
for _ in $(seq 60); do kill -0 "$export_pid" 2>/dev/null || break; sleep 1; done
kill "$export_pid" 2>/dev/null || true
echo "status=$status screenshots=$shots"
grep -E "error:|failed|passed" ".logs/ui-$slug.log" | tail -8
python3 scripts/name_ui_shots.py "$shots" > /dev/null || true
exit $status

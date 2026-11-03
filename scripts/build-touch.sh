#!/usr/bin/env bash
# Builds the iOS/iPadOS or tvOS app for the simulator.
#   scripts/build-touch.sh ios|tvos [Debug|Release]
# Prints the built .app path on success; the full log goes to .logs/.
set -euo pipefail
cd "$(dirname "$0")/.."
platform="${1:?usage: build-touch.sh ios|tvos [configuration]}"
configuration="${2:-Debug}"
case "$platform" in
  ios) scheme="Buffer iOS"; destination="generic/platform=iOS Simulator"; sdk=iphonesimulator ;;
  tvos) scheme="Buffer tvOS"; destination="generic/platform=tvOS Simulator"; sdk=appletvsimulator ;;
  *) echo "unknown platform: $platform" >&2; exit 64 ;;
esac
mkdir -p .logs
log=".logs/build-$platform.log"
derived=".build/dd-$platform"
package_args=()
if [[ -n "${BUFFER_PACKAGES_DIR:-}" ]]; then package_args=(-clonedSourcePackagesDirPath "$BUFFER_PACKAGES_DIR"); fi
if xcodebuild -project Buffer.xcodeproj -scheme "$scheme" -configuration "$configuration" \
    -destination "$destination" -derivedDataPath "$derived" ${package_args[@]+"${package_args[@]}"} \
    build > "$log" 2>&1; then
  echo "$PWD/$derived/Build/Products/$configuration-$sdk/Buffer.app"
else
  grep -E "error:" "$log" | sort -u | head -60 >&2
  echo "Build failed; see $log" >&2
  exit 1
fi

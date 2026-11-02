#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p .logs
skip=0
configuration=debug
runner_args=()
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --skip-build) skip=1; shift ;;
    --configuration)
      if [[ "$#" -lt 2 ]]; then echo '--configuration requires debug or optimized' >&2; exit 1; fi
      configuration="$2"; shift 2 ;;
    --configuration=*) configuration="${1#*=}"; shift ;;
    --help|-h)
      echo 'Usage: scripts/bench.sh [--skip-build] [--configuration debug|optimized] [--compare REPORT] [--tolerance FRACTION]'
      echo 'debug: ordinary Debug -Onone. optimized: full Debug app with -O/WMO, retaining instrumentation.'
      exit 0 ;;
    *) runner_args+=("$1"); shift ;;
  esac
done
derived_data=DerivedData
build_args=(SWIFT_OPTIMIZATION_LEVEL=-Onone SWIFT_COMPILATION_MODE=singlefile GCC_OPTIMIZATION_LEVEL=0)
case "$configuration" in
  debug) ;;
  optimized)
    derived_data=.local/DerivedData-Optimized
    build_args=(SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule GCC_OPTIMIZATION_LEVEL=2
                'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG BUFFER_OPTIMIZED_INSTRUMENTED'
                DEBUG_INFORMATION_FORMAT=dwarf-with-dsym COPY_PHASE_STRIP=NO STRIP_INSTALLED_PRODUCT=NO) ;;
  *) echo 'configuration must be debug or optimized' >&2; exit 1 ;;
esac
build_log=".logs/bench-build-$configuration.log"
if [[ "$skip" == 0 ]]; then
  source "$ROOT/scripts/local-signing.sh"
  buffer_configure_signing synthetic
  xcodebuild -project Buffer.xcodeproj -scheme Buffer -configuration Debug \
    -derivedDataPath "$derived_data" -destination 'platform=macOS,arch=arm64' \
    "${build_args[@]}" "${BUFFER_SIGNING_ARGS[@]}" build > "$build_log" 2>&1 || {
      echo "Build failed; see $build_log" >&2; exit 1;
    }
  buffer_verify_signing "$ROOT/$derived_data/Build/Products/Debug/Buffer.app"
fi
# Bash 3.2 (macOS) treats an empty array expansion as unset under nounset.
exec python3 scripts/bench.py --configuration "$configuration" ${runner_args[@]+"${runner_args[@]}"}

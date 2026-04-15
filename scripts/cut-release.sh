#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
ALLOW_DIRTY=0
OPEN_RELEASE=0
MARKETING_VERSION=""
BUILD_NUMBER=""
EXTRA_NOTES_FILE=${EXTRA_NOTES_FILE:-}

usage() {
  cat <<EOF
Usage: $(basename "$0") [marketing-version] [options]

Cuts a full local release end-to-end:
  1. bumps MARKETING_VERSION / CURRENT_PROJECT_VERSION
  2. commits the version bump
  3. pushes main
  4. runs ./scripts/release-sparkle.sh
  5. creates a GitHub release with assets + changelog

Arguments:
  marketing-version   Optional. If omitted, keeps current MARKETING_VERSION and
                      only increments the build number.

Options:
  --build <number>    Override CURRENT_PROJECT_VERSION (default: current + 1)
  --allow-dirty       Allow running with a dirty tree before bumping version
  --open              Open the created GitHub release page
  -h, --help          Show help

Examples:
  ./scripts/cut-release.sh            # same marketing version, build+1
  ./scripts/cut-release.sh 1.0.1      # set version to 1.0.1, build+1
  ./scripts/cut-release.sh 1.0.1 --build 7
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build)
      BUILD_NUMBER="$2"
      shift 2
      ;;
    --allow-dirty)
      ALLOW_DIRTY=1
      shift
      ;;
    --open)
      OPEN_RELEASE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ -z "$MARKETING_VERSION" ]]; then
        MARKETING_VERSION="$1"
        shift
      else
        echo "Unexpected argument: $1" >&2
        usage >&2
        exit 1
      fi
      ;;
  esac
done

for cmd in git perl xcodebuild; do
  require_cmd "$cmd"
done

cd "$ROOT_DIR"

if [[ "$ALLOW_DIRTY" != "1" ]] && [[ -n "$(git status --porcelain)" ]]; then
  echo "Working tree is dirty. Commit or stash changes first, or pass --allow-dirty." >&2
  exit 1
fi

BUILD_SETTINGS=$(xcodebuild -showBuildSettings -project Buffer.xcodeproj -scheme 'Buffer' -configuration Release)
CURRENT_VERSION=$(printf '%s\n' "$BUILD_SETTINGS" | awk -F ' = ' '/MARKETING_VERSION/ {print $2; exit}')
CURRENT_BUILD=$(printf '%s\n' "$BUILD_SETTINGS" | awk -F ' = ' '/CURRENT_PROJECT_VERSION/ {print $2; exit}')

if [[ -z "$CURRENT_VERSION" || -z "$CURRENT_BUILD" ]]; then
  echo "Failed to read current version/build" >&2
  exit 1
fi

if [[ -z "$MARKETING_VERSION" ]]; then
  MARKETING_VERSION="$CURRENT_VERSION"
fi

if [[ -z "$BUILD_NUMBER" ]]; then
  BUILD_NUMBER=$((CURRENT_BUILD + 1))
fi

if ! [[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "Build number must be numeric: $BUILD_NUMBER" >&2
  exit 1
fi

perl -0pi -e 's/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = '"$MARKETING_VERSION"';/g; s/CURRENT_PROJECT_VERSION = [^;]+;/CURRENT_PROJECT_VERSION = '"$BUILD_NUMBER"';/g' Buffer.xcodeproj/project.pbxproj

git add Buffer.xcodeproj/project.pbxproj

git commit -m "chore(release): cut ${MARKETING_VERSION} (${BUILD_NUMBER})" -m "Bump the Buffer release version to ${MARKETING_VERSION} (${BUILD_NUMBER}) in preparation for the notarized direct-distribution release and GitHub release publish."

git push origin main

./scripts/release-sparkle.sh

PUBLISH_ARGS=(--skip-build)
if [[ "$OPEN_RELEASE" == "1" ]]; then
  PUBLISH_ARGS+=(--open)
fi
if [[ -n "$EXTRA_NOTES_FILE" ]]; then
  export EXTRA_NOTES_FILE
fi
./scripts/publish-github-release.sh "${PUBLISH_ARGS[@]}"

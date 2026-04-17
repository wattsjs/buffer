#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
REPO=${REPO:-wattsjs/buffer}
TARGET=${TARGET:-main}
TAG_PREFIX=${TAG_PREFIX:-v}
ALLOW_DIRTY=${ALLOW_DIRTY:-0}
RUN_RELEASE_BUILD=${RUN_RELEASE_BUILD:-1}
DRY_RUN=0
MAKE_LATEST=1
OPEN_RELEASE=0
PATCH_EXISTING_NOTES=0
EXTRA_NOTES_FILE=${EXTRA_NOTES_FILE:-}

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Builds/notarizes the app, generates changelog notes from git history,
creates a GitHub release, and uploads the DMG + ZIP artifacts.

Options:
  --dry-run         Show what would happen without creating a release
  --allow-dirty     Allow running with a dirty git tree
  --skip-build      Reuse existing dist artifacts instead of running release-sparkle.sh
  --no-latest       Do not mark the GitHub release as latest
  --open            Open the created release page in the browser
  --update-notes    Edit an existing release body instead of creating a new release
  -h, --help        Show help

Environment variables:
  REPO              GitHub repo for the release (default: $REPO)
  TARGET            Git ref for the release tag target (default: $TARGET)
  TAG_PREFIX        Tag prefix (default: $TAG_PREFIX)
  EXTRA_NOTES_FILE  Optional markdown file appended to generated notes

Notes:
  - By default this script requires a clean working tree.
  - It calls ./scripts/release-sparkle.sh unless --skip-build is passed.
  - Version/build are read from Xcode build settings.
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
    --dry-run)
      DRY_RUN=1
      ;;
    --allow-dirty)
      ALLOW_DIRTY=1
      ;;
    --skip-build)
      RUN_RELEASE_BUILD=0
      ;;
    --no-latest)
      MAKE_LATEST=0
      ;;
    --open)
      OPEN_RELEASE=1
      ;;
    --update-notes|--patch-notes)
      PATCH_EXISTING_NOTES=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

for cmd in gh git xcodebuild awk sed mktemp shasum; do
  require_cmd "$cmd"
done

cd "$ROOT_DIR"

if [[ "$ALLOW_DIRTY" != "1" ]] && [[ -n "$(git status --porcelain)" ]]; then
  echo "Working tree is dirty. Commit or stash changes first, or pass --allow-dirty." >&2
  exit 1
fi

# Keep the local tag view aligned with the remote release tags before we derive
# the changelog range. Without this, a fresh clone only knows about the oldest
# tag it happened to fetch, which makes release notes span far too much history.
git fetch --tags --force origin >/dev/null 2>&1 || true

BUILD_SETTINGS=$(xcodebuild -showBuildSettings -project Buffer.xcodeproj -scheme 'Buffer' -configuration Release)
MARKETING_VERSION=$(printf '%s\n' "$BUILD_SETTINGS" | awk -F ' = ' '/MARKETING_VERSION/ {print $2; exit}')
BUILD_NUMBER=$(printf '%s\n' "$BUILD_SETTINGS" | awk -F ' = ' '/CURRENT_PROJECT_VERSION/ {print $2; exit}')

if [[ -z "$MARKETING_VERSION" || -z "$BUILD_NUMBER" ]]; then
  echo "Failed to determine version/build from Xcode build settings" >&2
  exit 1
fi

VERSION_LABEL="${MARKETING_VERSION} (${BUILD_NUMBER})"
RELEASE_BASENAME="Buffer-${MARKETING_VERSION}-${BUILD_NUMBER}"
TAG_NAME="${TAG_PREFIX}${MARKETING_VERSION}-build.${BUILD_NUMBER}"
RELEASE_TITLE="Buffer ${VERSION_LABEL}"
DIST_DIR="$ROOT_DIR/dist/${RELEASE_BASENAME}"
DMG_PATH="$DIST_DIR/${RELEASE_BASENAME}.dmg"
ZIP_PATH="$DIST_DIR/${RELEASE_BASENAME}.zip"
RELEASE_URL="https://github.com/${REPO}/releases/tag/${TAG_NAME}"
CHANGELOG_START="<!-- buffer-release-notes:start -->"
CHANGELOG_END="<!-- buffer-release-notes:end -->"

is_release_note_commit() {
  local subject=$1

  case "$subject" in
    chore\(release\):\ cut\ *|chore\(release\):*)
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

is_release_automation_commit() {
  local subject=$1

  case "$subject" in
    chore\(release\):\ cut\ *|chore\(release\):*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

collect_changelog_entries() {
  local range=$1
  local subject hash

  while IFS=$'\t' read -r subject hash; do
    [[ -z "${subject// }" ]] && continue
    if is_release_note_commit "$subject"; then
      printf -- '- %s (%s)\n' "$subject" "$hash"
    fi
  done < <(git log --reverse --format='%s%x09%h' "$range")
}

collect_any_commit_entries() {
  local range=$1
  local subject hash

  while IFS=$'\t' read -r subject hash; do
    [[ -z "${subject// }" ]] && continue
    if ! is_release_automation_commit "$subject"; then
      printf -- '- %s (%s)\n' "$subject" "$hash"
    fi
  done < <(git log --reverse --format='%s%x09%h' "$range")
}

collect_all_commit_entries() {
  local range=$1
  local subject hash

  while IFS=$'\t' read -r subject hash; do
    [[ -z "${subject// }" ]] && continue
    printf -- '- %s (%s)\n' "$subject" "$hash"
  done < <(git log --reverse --format='%s%x09%h' "$range")
}

if git rev-parse --verify --quiet "${TAG_NAME}^{commit}" >/dev/null; then
  last_tag=$(git describe --tags --abbrev=0 --match "${TAG_PREFIX}*" "${TAG_NAME}^" 2>/dev/null || true)
else
  last_tag=$(git describe --tags --abbrev=0 --match "${TAG_PREFIX}*" 2>/dev/null || true)
fi
if [[ -n "$last_tag" ]]; then
  log_range="${last_tag}..HEAD"
else
  log_range="HEAD"
fi

generate_notes_file() {
  local notes_file=$1
  local include_artifacts=$2
  local changelog_entries fallback_entries raw_commit_count

  changelog_entries=$(collect_changelog_entries "$log_range")
  fallback_entries=$(collect_any_commit_entries "$log_range")
  raw_commit_count=$(git rev-list --count "$log_range" 2>/dev/null || echo 0)

  {
    echo "$CHANGELOG_START"
    echo "## Changelog"
    echo
    if [[ -n "$changelog_entries" ]]; then
      printf '%s\n' "$changelog_entries"
    elif [[ -n "$fallback_entries" ]]; then
      printf '%s\n' "$fallback_entries"
    elif [[ "$raw_commit_count" -gt 0 ]]; then
      collect_all_commit_entries "$log_range"
    else
      echo "- Initial release"
    fi
    echo "$CHANGELOG_END"
    echo

    if [[ "$include_artifacts" == "1" ]]; then
      echo "## Artifacts"
      echo
      printf -- '- DMG: `%s`\n' "${RELEASE_BASENAME}.dmg"
      printf -- '- Sparkle ZIP: `%s`\n' "${RELEASE_BASENAME}.zip"
      echo "- Sparkle appcast: https://raw.githubusercontent.com/wattsjs/buffer-updates/main/appcast.xml"
      echo
    fi

    if [[ -n "$EXTRA_NOTES_FILE" && -f "$EXTRA_NOTES_FILE" ]]; then
      echo "## Notes"
      echo
      cat "$EXTRA_NOTES_FILE"
      echo
    fi
  } > "$notes_file"
}

if gh release view "$TAG_NAME" --repo "$REPO" >/dev/null 2>&1; then
  if [[ "$PATCH_EXISTING_NOTES" != "1" ]]; then
    echo "Release tag already exists on GitHub: $TAG_NAME" >&2
    echo "Use --update-notes to patch the existing release body instead." >&2
    exit 1
  fi

  CHANGELOG_BLOCK=$(mktemp)
  CURRENT_BODY_FILE=$(mktemp)
  UPDATED_BODY_FILE=$(mktemp)
  generate_notes_file "$CHANGELOG_BLOCK" 0
  gh release view "$TAG_NAME" --repo "$REPO" --json body --jq .body > "$CURRENT_BODY_FILE"
  BLOCK_FILE="$CHANGELOG_BLOCK" perl -0ne '
    my $replacement = do { local(@ARGV, $/) = $ENV{BLOCK_FILE}; <> };
    if (index($_, "<!-- buffer-release-notes:start -->") >= 0 && index($_, "<!-- buffer-release-notes:end -->") >= 0) {
      s/<!-- buffer-release-notes:start -->.*?<!-- buffer-release-notes:end -->/$replacement/s;
    } else {
      s/## Changelog\n.*?(?=\n## |\z)/$replacement/s;
    }
    print;
  ' "$CURRENT_BODY_FILE" > "$UPDATED_BODY_FILE"

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[dry-run] would update notes for: $TAG_NAME"
    echo "[dry-run] notes:"
    cat "$UPDATED_BODY_FILE"
    exit 0
  fi

  gh release edit "$TAG_NAME" --repo "$REPO" --title "$RELEASE_TITLE" --notes-file "$UPDATED_BODY_FILE"

  echo "Updated release notes: $RELEASE_URL"
  if [[ "$OPEN_RELEASE" == "1" ]]; then
    gh release view "$TAG_NAME" --repo "$REPO" --web
  fi
  exit 0
fi

if [[ "$RUN_RELEASE_BUILD" == "1" ]]; then
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[dry-run] would run ./scripts/release-sparkle.sh"
  else
    ./scripts/release-sparkle.sh
  fi
fi

if [[ ! -f "$DMG_PATH" || ! -f "$ZIP_PATH" ]]; then
  echo "Expected artifacts not found:" >&2
  echo "  $DMG_PATH" >&2
  echo "  $ZIP_PATH" >&2
  exit 1
fi

DMG_SHA=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
ZIP_SHA=$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')
NOTES_FILE=$(mktemp)
generate_notes_file "$NOTES_FILE" 1
{
  echo "### Checksums"
  echo
  printf -- '- `%s`: `%s`\n' "${RELEASE_BASENAME}.dmg" "$DMG_SHA"
  printf -- '- `%s`: `%s`\n' "${RELEASE_BASENAME}.zip" "$ZIP_SHA"
} >> "$NOTES_FILE"

RELEASE_ARGS=(
  "$TAG_NAME"
  "$DMG_PATH"
  "$ZIP_PATH"
  --repo "$REPO"
  --target "$TARGET"
  --title "$RELEASE_TITLE"
  --notes-file "$NOTES_FILE"
)

if [[ "$MAKE_LATEST" == "1" ]]; then
  RELEASE_ARGS+=(--latest)
fi

if [[ "$DRY_RUN" == "1" ]]; then
  echo "[dry-run] tag: $TAG_NAME"
  echo "[dry-run] title: $RELEASE_TITLE"
  echo "[dry-run] artifacts:"
  echo "  - $DMG_PATH"
  echo "  - $ZIP_PATH"
  echo "[dry-run] notes:"
  cat "$NOTES_FILE"
  exit 0
fi

gh release create "${RELEASE_ARGS[@]}"

echo "Created release: $RELEASE_URL"
if [[ "$OPEN_RELEASE" == "1" ]]; then
  gh release view "$TAG_NAME" --repo "$REPO" --web
fi

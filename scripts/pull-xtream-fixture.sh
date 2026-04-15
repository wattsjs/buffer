#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
OUT_DIR_DEFAULT="$ROOT_DIR/.local/xtream-test"

usage() {
  cat <<EOF
Usage: $(basename "$0") <base-url> <username> <password> [out-dir]

Downloads an Xtream guide locally and builds a local M3U fixture for testing.
If the provider's live-stream API is down, it falls back to the latest cached
channel list from the local Buffer/Mac TV app container.

Examples:
  ./scripts/pull-xtream-fixture.sh https://783.silksurfer.com user pass
  ./scripts/pull-xtream-fixture.sh https://783.silksurfer.com user pass .local/silksurfer
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

curl_fetch() {
  local url="$1"
  local out="$2"
  XTREAM_URL="$url" XTREAM_OUT="$out" uv run python - <<'PY'
import os
import shutil
import ssl
import urllib.request

url = os.environ['XTREAM_URL']
out = os.environ['XTREAM_OUT']
ctx = ssl.create_default_context()
req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
with urllib.request.urlopen(req, context=ctx, timeout=120) as response, open(out, 'wb') as f:
    shutil.copyfileobj(response, f)
PY
}

find_cache_file() {
  local pattern="$1"
  local candidates=(
    "$HOME/Library/Containers/com.wattsjs.buffer/Data/Library/Caches/buffer/$pattern"
    "$HOME/Library/Containers/com.wattsjs.buffer/Data/Library/Caches/mactv/$pattern"
    "$HOME/Library/Containers/com.wattsjs.mactv/Data/Library/Caches/buffer/$pattern"
    "$HOME/Library/Containers/com.wattsjs.mactv/Data/Library/Caches/mactv/$pattern"
  )

  local matches=()
  for candidate in "${candidates[@]}"; do
    for file in $candidate; do
      [[ -e "$file" ]] && matches+=("$file")
    done
  done

  if ((${#matches[@]} == 0)); then
    return 1
  fi

  ls -t "${matches[@]}" 2>/dev/null | head -1
}

jq_playlist_from_api='def clean: tostring | gsub("[\\r\\n]+"; " ");
def attr: clean | gsub("\""; "\\\"");
($cats[0] // []) as $categories
| ($categories | map({key: (.category_id | tostring), value: (.category_name // "Unknown")}) | from_entries) as $catmap
| "#EXTM3U\n"
  + (
      map(
        "#EXTINF:-1 tvg-id=\"\((.epg_channel_id // \"\") | attr)\" tvg-logo=\"\((.stream_icon // \"\") | attr)\" group-title=\"\(($catmap[(.category_id | tostring)] // \"Uncategorized\") | attr)\",\((.name // \"Unknown\") | clean)\n"
        + $base + "/live/" + $user + "/" + $pass + "/" + (.stream_id | tostring) + ".m3u8"
      )
      | join("\n")
    ) + "\n"'

jq_playlist_from_cache='def clean: tostring | gsub("[\\r\\n]+"; " ");
def attr: clean | gsub("\""; "\\\"");
.channels
| "#EXTM3U\n"
  + (
      map(
        "#EXTINF:-1 tvg-id=\"\((.epgChannelID // \"\") | attr)\" tvg-logo=\"\((.logoURL // \"\") | attr)\" group-title=\"\((.group // \"Uncategorized\") | attr)\",\((.name // \"Unknown\") | clean)\n"
        + (.streamURL | tostring)
      )
      | join("\n")
    ) + "\n"'

if [[ $# -lt 3 || $# -gt 4 ]]; then
  usage >&2
  exit 1
fi

require_cmd jq
require_cmd uv

BASE_URL=${1%/}
USERNAME=$2
PASSWORD=$3
OUT_DIR=${4:-$OUT_DIR_DEFAULT}

GUIDE_URL="$BASE_URL/xmltv.php?username=$USERNAME&password=$PASSWORD"
CATEGORIES_URL="$BASE_URL/player_api.php?username=$USERNAME&password=$PASSWORD&action=get_live_categories"
STREAMS_URL="$BASE_URL/player_api.php?username=$USERNAME&password=$PASSWORD&action=get_live_streams"

mkdir -p "$OUT_DIR"

GUIDE_FILE="$OUT_DIR/guide.xml"
CATEGORIES_FILE="$OUT_DIR/categories.json"
STREAMS_FILE="$OUT_DIR/streams.json"
PLAYLIST_FILE="$OUT_DIR/playlist.m3u"
README_FILE="$OUT_DIR/README.md"
META_FILE="$OUT_DIR/source.json"

printf 'Downloading XMLTV guide...\n'
curl_fetch "$GUIDE_URL" "$GUIDE_FILE"

printf 'Fetching Xtream channels...\n'
CHANNEL_SOURCE="xtream-api"
if curl_fetch "$CATEGORIES_URL" "$CATEGORIES_FILE" && curl_fetch "$STREAMS_URL" "$STREAMS_FILE"; then
  jq -r \
    --arg base "$BASE_URL" \
    --arg user "$USERNAME" \
    --arg pass "$PASSWORD" \
    --slurpfile cats "$CATEGORIES_FILE" \
    "$jq_playlist_from_api" \
    "$STREAMS_FILE" > "$PLAYLIST_FILE"
else
  CHANNEL_SOURCE="cache-fallback"
  rm -f "$CATEGORIES_FILE" "$STREAMS_FILE"

  CACHE_FILE=$(find_cache_file 'channels_*.json' || true)
  if [[ -z "$CACHE_FILE" ]]; then
    echo "Xtream API failed and no local cached channel list was found." >&2
    exit 1
  fi

  printf 'Xtream API unavailable, falling back to cached channels: %s\n' "$CACHE_FILE"
  jq -r "$jq_playlist_from_cache" "$CACHE_FILE" > "$PLAYLIST_FILE"
fi

PLAYLIST_ABS=$(cd "$(dirname "$PLAYLIST_FILE")" && pwd)/$(basename "$PLAYLIST_FILE")
GUIDE_ABS=$(cd "$(dirname "$GUIDE_FILE")" && pwd)/$(basename "$GUIDE_FILE")
PLAYLIST_URI="file://$PLAYLIST_ABS"
GUIDE_URI="file://$GUIDE_ABS"
GENERATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
CHANNEL_COUNT=$(grep -c '^#EXTINF:' "$PLAYLIST_FILE" || true)

cat > "$META_FILE" <<EOF
{
  "generatedAt": "$GENERATED_AT",
  "baseURL": "$BASE_URL",
  "channelSource": "$CHANNEL_SOURCE",
  "playlist": "$PLAYLIST_ABS",
  "guide": "$GUIDE_ABS",
  "channelCount": $CHANNEL_COUNT
}
EOF

cat > "$README_FILE" <<EOF
# Local Xtream fixture

Generated: $GENERATED_AT
Source: $BASE_URL
Channel source: $CHANNEL_SOURCE
Channels: $CHANNEL_COUNT

## Use in Buffer

Settings → Account
- Type: M3U Playlist
- Playlist URL: $PLAYLIST_URI
- EPG URL: $GUIDE_URI

You can also paste plain file paths now:
- $PLAYLIST_ABS
- $GUIDE_ABS

## Files
- playlist: $PLAYLIST_ABS
- guide: $GUIDE_ABS
- metadata: $META_FILE
EOF

printf '\nFixture ready.\n'
printf 'Playlist: %s\n' "$PLAYLIST_ABS"
printf 'Guide:    %s\n' "$GUIDE_ABS"
printf 'Source:   %s\n' "$CHANNEL_SOURCE"
printf 'Channels: %s\n' "$CHANNEL_COUNT"

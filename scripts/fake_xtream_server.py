#!/usr/bin/env python3
"""Loopback Xtream Codes fixture for exercising the apps without a provider.

Serves player_api.php (account, live categories/streams, empty VOD/series),
xmltv.php (a guide spanning the last day and the next one) and a rolling live
HLS stream per channel, looped from an ffmpeg-generated test pattern.

    python3 scripts/fake_xtream_server.py --port 8899
    # Add an Xtream source: http://127.0.0.1:8899, user "demo", password "demo".

No credentials or real provider data are involved.
"""
import argparse
import datetime
import http.server
import json
import pathlib
import subprocess
import sys
import time
import urllib.parse
from xml.sax.saxutils import escape

ROOT = pathlib.Path(__file__).resolve().parent.parent
SEGMENT_SECONDS = 2
WINDOW = 6

CATEGORIES = [("1", "Sports"), ("2", "News"), ("3", "Entertainment")]
CHANNELS = [
    ("101", "ESPN", "1", ["NFL Live", "SportsCenter", "College Football", "NBA Countdown"]),
    ("102", "Sky Sports Main Event", "1", ["Premier League Football", "Super Sunday", "Goals on Sunday"]),
    ("103", "beIN Sports 1", "1", ["Champions League", "LaLiga", "Serie A Highlights"]),
    ("104", "Fox Sports 1", "1", ["NASCAR Cup Series", "MLB Postgame", "UFC Countdown"]),
    ("105", "TNT Sports", "1", ["NBA on TNT", "Inside the NBA", "NHL Tonight"]),
    ("201", "BBC News", "2", ["BBC News at One", "World Business Report", "Newsnight"]),
    ("202", "CNN International", "2", ["Connect the World", "Amanpour", "Quest Means Business"]),
    ("203", "Sky News", "2", ["Sky News Breakfast", "The Briefing", "Sky News Tonight"]),
    ("301", "BBC One", "3", ["EastEnders", "The Graham Norton Show", "Match of the Day"]),
    ("302", "ITV1", "3", ["Coronation Street", "Emmerdale", "This Morning"]),
    ("303", "Channel 4", "3", ["Gogglebox", "Grand Designs", "Taskmaster"]),
]


def build_fixture(directory: pathlib.Path) -> list[pathlib.Path]:
    directory.mkdir(parents=True, exist_ok=True)
    playlist = directory / "index.m3u8"
    if not playlist.exists():
        subprocess.run([
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
            "-t", "60", "-c:v", "libx264", "-preset", "veryfast", "-g", str(30 * SEGMENT_SECONDS),
            "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "96k",
            "-f", "hls", "-hls_time", str(SEGMENT_SECONDS), "-hls_playlist_type", "vod",
            "-hls_segment_filename", str(directory / "seg%03d.ts"), str(playlist),
        ], check=True)
    return sorted(directory.glob("seg*.ts"))


class Handler(http.server.BaseHTTPRequestHandler):
    segments: list[pathlib.Path] = []
    started = time.time()
    origin = "http://127.0.0.1:8899"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.command, self.path.split("?")[0]))

    def send(self, body: bytes, content_type: str, status: int = 200):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        query = dict(urllib.parse.parse_qsl(url.query))
        if url.path == "/player_api.php":
            return self.player_api(query)
        if url.path == "/xmltv.php":
            return self.send(self.xmltv().encode(), "application/xml")
        parts = url.path.strip("/").split("/")
        if len(parts) == 4 and parts[0] == "live" and parts[3].endswith(".m3u8"):
            return self.send(self.live_playlist(parts[3][:-5]).encode(), "application/vnd.apple.mpegurl")
        if len(parts) == 2 and parts[0] == "seg":
            index = int(parts[1].split(".")[0]) % len(self.segments)
            return self.send(self.segments[index].read_bytes(), "video/mp2t")
        self.send(b"not found", "text/plain", 404)

    def player_api(self, query):
        if query.get("username") != "demo" or query.get("password") != "demo":
            return self.send(json.dumps({"user_info": {"auth": 0}}).encode(), "application/json")
        action = query.get("action")
        expiry = int(time.time()) + 365 * 86400
        if action is None:
            body = {"user_info": {"username": "demo", "auth": 1, "status": "Active", "exp_date": str(expiry),
                                  "is_trial": "0", "active_cons": "0", "max_connections": "2"},
                    "server_info": {"url": "127.0.0.1", "port": "8899", "timezone": "UTC"}}
        elif action == "get_live_categories":
            body = [{"category_id": cid, "category_name": name, "parent_id": 0} for cid, name in CATEGORIES]
        elif action == "get_live_streams":
            body = [{"num": i + 1, "name": name, "stream_id": int(sid), "stream_icon": "",
                     "epg_channel_id": f"ch{sid}", "category_id": cat, "tv_archive": 0, "tv_archive_duration": 0}
                    for i, (sid, name, cat, _) in enumerate(CHANNELS)]
        elif action in ("get_simple_data_table", "get_short_epg"):
            body = {"epg_listings": []}
        else:
            body = []
        self.send(json.dumps(body).encode(), "application/json")

    def xmltv(self) -> str:
        now = datetime.datetime.now(datetime.timezone.utc).replace(minute=0, second=0, microsecond=0)
        start = now - datetime.timedelta(hours=24)
        lines = ['<?xml version="1.0" encoding="UTF-8"?>', '<tv generator-info-name="buffer-fake-xtream">']
        for sid, name, _, _ in CHANNELS:
            lines.append(f'<channel id="ch{sid}"><display-name>{escape(name)}</display-name></channel>')
        fmt = "%Y%m%d%H%M%S +0000"
        for sid, _, _, titles in CHANNELS:
            cursor, slot = start, int(sid)
            while cursor < now + datetime.timedelta(hours=26):
                minutes = (30, 60, 90, 60)[slot % 4]
                end = cursor + datetime.timedelta(minutes=minutes)
                title = titles[slot % len(titles)]
                lines.append(f'<programme start="{cursor.strftime(fmt)}" stop="{end.strftime(fmt)}" channel="ch{sid}">'
                             f'<title>{escape(title)}</title><desc>{escape(title)} on the fixture feed.</desc></programme>')
                cursor, slot = end, slot + 1
        lines.append("</tv>")
        return "\n".join(lines)

    def live_playlist(self, stream_id: str) -> str:
        sequence = int((time.time() - self.started) // SEGMENT_SECONDS)
        lines = ["#EXTM3U", "#EXT-X-VERSION:3", f"#EXT-X-TARGETDURATION:{SEGMENT_SECONDS}",
                 f"#EXT-X-MEDIA-SEQUENCE:{sequence}"]
        for number in range(sequence, sequence + WINDOW):
            if number % len(self.segments) == 0 and number != sequence:
                lines.append("#EXT-X-DISCONTINUITY")
            lines.append(f"#EXTINF:{SEGMENT_SECONDS}.0,")
            lines.append(f"{self.origin}/seg/{number}.ts")
        return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8899)
    parser.add_argument("--host", default="127.0.0.1")
    args = parser.parse_args()
    Handler.segments = build_fixture(ROOT / ".local" / "fake-xtream")
    Handler.origin = f"http://{args.host}:{args.port}"
    server = http.server.ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"Fake Xtream on {Handler.origin} (user demo / password demo), {len(Handler.segments)} segments", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""HLS proxy that injects network disturbances for stability testing."""

import http.server
import socketserver
import socket
import urllib.request
import urllib.parse
import sys
import os
import random
import time
import threading
import re

# Configuration from environment
SEGMENT_DROP_RATE = float(os.environ.get("SEGMENT_DROP_RATE", "0.3"))
STALL_DURATION_MS = int(os.environ.get("STALL_DURATION_MS", "3000"))
PROXY_PORT = int(os.environ.get("PROXY_PORT", "8765"))
SEED = int(os.environ.get("SEED", "42"))

random.seed(SEED)

class StallHandler:
    """Manages artificial connection stalls."""
    def __init__(self):
        self._stall_until = 0.0
        self._lock = threading.Lock()
        self.stall_count = 0

    def maybe_stall(self, path: str) -> bool:
        """Decide whether to stall this request. Returns True if stalled."""
        if not path.endswith('.ts'):
            return False
        if random.random() > SEGMENT_DROP_RATE:
            return False
        duration = random.uniform(STALL_DURATION_MS * 0.5, STALL_DURATION_MS * 1.5) / 1000.0
        with self._lock:
            self._stall_until = time.time() + duration
        self.stall_count += 1
        print(f"[stall #{self.stall_count}] {duration*1000:.0f}ms on {path}", file=sys.stderr, flush=True)
        time.sleep(duration)
        return True

stall_handler = StallHandler()

# CDN base URL and playlist cache
CDN_BASE = ""
PLAYLIST_CONTENT = b""
SEGMENT_CACHE = {}  # path -> (content_type, data)
SEGMENT_CACHE_LOCK = threading.Lock()

def fetch_with_retry(url, max_retries=3):
    for attempt in range(max_retries):
        try:
            req = urllib.request.Request(url)
            with urllib.request.urlopen(req, timeout=15) as resp:
                return resp.read(), resp.headers.get('Content-Type', 'application/octet-stream')
        except Exception as e:
            if attempt == max_retries - 1:
                raise
            time.sleep(0.5)

def rewrite_playlist(data, upstream_base):
    """Rewrite absolute segment URLs to point at our proxy."""
    text = data.decode('utf-8', errors='replace')
    # Replace absolute CDN segment URLs with proxy URLs
    # Pattern: /hls/.../segment.ts
    def rewrite(m):
        path = m.group(1)
        return f'http://127.0.0.1:{PROXY_PORT}{path}'
    text = re.sub(r'(/hls/[\w/]+\.ts)', rewrite, text)
    return text.encode('utf-8')

class ProxyHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # Suppress default logging
        pass

    def do_GET(self):
        path = self.path

        # Inject stalls
        stall_handler.maybe_stall(path)

        if path.endswith('.m3u8'):
            # Serve rewritten playlist
            self.send_response(200)
            self.send_header('Content-Type', 'application/vnd.apple.mpegurl')
            self.end_headers()
            self.wfile.write(PLAYLIST_CONTENT)
            return

        if path.endswith('.ts'):
            # Check cache first
            with SEGMENT_CACHE_LOCK:
                if path in SEGMENT_CACHE:
                    content_type, data = SEGMENT_CACHE[path]
                    self.send_response(200)
                    self.send_header('Content-Type', content_type)
                    self.send_header('Content-Length', str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                    return

            # Fetch from upstream
            try:
                seg_url = CDN_BASE.rstrip('/') + '/' + path.lstrip('/')
                data, content_type = fetch_with_retry(seg_url)
                with SEGMENT_CACHE_LOCK:
                    SEGMENT_CACHE[path] = (content_type, data)
                self.send_response(200)
                self.send_header('Content-Type', content_type)
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            except Exception as e:
                print(f"[proxy] segment fetch failed: {path} -> {e}", file=sys.stderr, flush=True)
                self.send_response(502)
                self.end_headers()
                self.wfile.write(b'Bad Gateway')
            return

        self.send_response(404)
        self.end_headers()

def main():
    global CDN_BASE, PLAYLIST_CONTENT

    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <stream_url>", file=sys.stderr)
        sys.exit(1)

    stream_url = sys.argv[1]

    # Resolve redirect and fetch playlist
    print(f"[proxy] Resolving: {stream_url}", file=sys.stderr, flush=True)
    resp = urllib.request.urlopen(stream_url, timeout=15)
    final_url = resp.geturl()
    # Extract scheme+host for absolute segment URL construction
    parsed = urllib.parse.urlparse(final_url)
    CDN_BASE = f"{parsed.scheme}://{parsed.netloc}"

    raw_playlist = resp.read()
    print(f"[proxy] CDN base: {CDN_BASE}", file=sys.stderr, flush=True)
    print(f"[proxy] Playlist: {len(raw_playlist)} bytes", file=sys.stderr, flush=True)

    PLAYLIST_CONTENT = rewrite_playlist(raw_playlist, CDN_BASE)

    server = socketserver.ThreadingTCPServer(('127.0.0.1', PROXY_PORT), ProxyHandler)
    server.allow_reuse_address = True
    server.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    # SO_REUSEPORT may not be available on all platforms; ignore if it fails
    try:
        server.socket.setsockopt(socket.SOL_SOCKET, 0x0200, 1)  # SO_REUSEPORT
    except (AttributeError, OSError):
        pass

    print(f"[proxy] Listening on :{PROXY_PORT}", file=sys.stderr, flush=True)
    print(f"[proxy] Drop rate={SEGMENT_DROP_RATE}, stall={STALL_DURATION_MS}ms, seed={SEED}", file=sys.stderr, flush=True)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.shutdown()
        print(f"[proxy] Stall count: {stall_handler.stall_count}", file=sys.stderr, flush=True)

if __name__ == '__main__':
    main()

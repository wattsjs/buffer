#!/usr/bin/env python3
"""Local socket integration tests; no player, provider or encoding needed."""
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
import http.server
import importlib.util
import pathlib
import socket
import sys
import threading
import time
import unittest
import urllib.error
import urllib.request

MODULE_PATH = pathlib.Path(__file__).resolve().parents[1] / 'benchmarks/hls_retry_proxy.py'
spec = importlib.util.spec_from_file_location('hls_retry_proxy', MODULE_PATH)
proxy_module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = proxy_module
spec.loader.exec_module(proxy_module)
Broker, LocalHLSProxy, Policy = proxy_module.Broker, proxy_module.LocalHLSProxy, proxy_module.Policy
MEDIA = b'\x47local-transport-stream\x00\xffPTS:original' * 4096
MANIFEST = b'#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:7\n#EXTINF:2,\nsegment.ts\n'


@contextmanager
def origin_server(respond):
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_): pass
        def do_GET(self):
            try: respond(self)
            except (BrokenPipeError, ConnectionResetError): pass
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, kwargs={'poll_interval': .025}, daemon=True)
    thread.start()
    try: yield f'http://127.0.0.1:{server.server_port}'
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=1)


def send(handler, status=200, body=MEDIA, **headers):
    handler.send_response(status)
    handler.send_header('Content-Length', str(len(body)))
    for key, value in headers.items(): handler.send_header(key.replace('_', '-'), value)
    handler.end_headers()
    handler.wfile.write(body)


class RetryProxyTests(unittest.TestCase):
    def test_loopback_origin_and_path_only(self):
        for origin in ('https://127.0.0.1:1234', 'http://localhost:1234', 'http://192.168.1.1:80',
                       'http://127.0.0.1', 'http://user:pass@127.0.0.1:4', 'http://127.0.0.1:4/x'):
            with self.subTest(origin=origin), self.assertRaises(ValueError): Broker(origin)
        for path in ('https://example.com/a', '//example.com/a', '/../secret', '/%2e%2e/secret',
                     '/a\\b', '/%00bad', '/a#fragment'):
            with self.subTest(path=path), self.assertRaises(ValueError): Broker.validate_path(path)
        for value in ('bytes=1-2,5-6', 'other=1-2', 'bytes=-', 'bytes=1 -2'):
            with self.subTest(value=value), self.assertRaises(ValueError): Broker.validate_range(value)
        for seconds in (0, 7, float('inf'), float('nan')):
            with self.assertRaises(ValueError): Policy(retry_seconds=seconds)

    def test_502_503_504_recover_same_bytes_and_cache_once(self):
        for status in (502, 503, 504):
            requests = []
            def respond(h):
                requests.append(h.path)
                send(h, status if len(requests) <= 2 else 200, b'' if len(requests) <= 2 else MEDIA)
            with self.subTest(status=status), origin_server(respond) as origin:
                broker = Broker(origin, Policy(retry_seconds=1, attempt_timeout=.2))
                try:
                    response = broker.fetch('/segment.ts')
                    self.assertEqual((response.status, response.body), (200, MEDIA))
                    self.assertIs(broker.fetch('/segment.ts'), response)
                    self.assertEqual(len(requests), 3)
                    self.assertEqual(broker.snapshot()['retries'], 2)
                    self.assertEqual(broker.snapshot()['cacheHits'], 1)
                finally: broker.close()

    def test_no_auth_missing_throttle_or_redirect_retries(self):
        for status in (401, 403, 404, 429, 509, 301, 302):
            requests = []
            def respond(h):
                requests.append(h.path)
                send(h, status, b'failure', Location='http://192.0.2.1/must-not-follow')
            with self.subTest(status=status), origin_server(respond) as origin:
                broker = Broker(origin)
                try:
                    response = broker.fetch('/segment.ts')
                    self.assertEqual(response.status, status)
                    self.assertEqual(response.body, b'failure')
                    self.assertEqual(len(requests), 1)
                    self.assertEqual(broker.snapshot()['retries'], 0)
                    self.assertEqual(broker.snapshot()['cacheItems'], 0)
                finally: broker.close()

    def test_manifest_unchanged_never_cached_and_relative_segment_via_proxy(self):
        requests = []
        def respond(h):
            requests.append(h.path)
            send(h, body=MANIFEST if h.path.endswith('m3u8') else MEDIA,
                 Content_Type='application/vnd.apple.mpegurl' if h.path.endswith('m3u8') else 'video/mp2t')
        with origin_server(respond) as origin, LocalHLSProxy(origin) as proxy:
            for _ in range(2):
                with urllib.request.urlopen(proxy.url(), timeout=2) as r:
                    self.assertEqual(r.read(), MANIFEST)
            with urllib.request.urlopen(proxy.url('/segment.ts'), timeout=2) as r:
                self.assertEqual(r.read(), MEDIA)
                self.assertEqual(r.headers['Content-Type'], 'video/mp2t')
            self.assertEqual(requests, ['/stream.m3u8', '/stream.m3u8', '/segment.ts'])

    def test_range_and_query_identity_and_cache_bounds(self):
        requests = []
        def respond(h):
            requests.append((h.path, h.headers.get('Range')))
            body = h.path.encode() + (h.headers.get('Range') or '').encode()
            send(h, 206 if h.headers.get('Range') else 200, body)
        with origin_server(respond) as origin:
            broker = Broker(origin, Policy(cache_items=2, cache_bytes=40))
            try:
                a = broker.fetch('/s.ts?version=1', 'bytes=0-2')
                self.assertIs(broker.fetch('/s.ts?version=1', 'bytes=0-2'), a)
                b = broker.fetch('/s.ts?version=1', 'bytes=3-5')
                c = broker.fetch('/s.ts?version=2', 'bytes=3-5')
                self.assertNotEqual(a.body, b.body)
                self.assertNotEqual(b.body, c.body)
                self.assertEqual(len(requests), 3)
                self.assertLessEqual(broker.snapshot()['cacheItems'], 2)
                self.assertLessEqual(broker.snapshot()['cacheBytes'], 40)
                self.assertGreater(broker.snapshot()['evicted'], 0)
            finally: broker.close()

    def test_concurrent_exact_resource_coalesces_and_fetch_permits_bounded(self):
        requests = []
        lock = threading.Lock()
        def respond(h):
            with lock: requests.append(h.path)
            time.sleep(.1)
            send(h)
        with origin_server(respond) as origin:
            broker = Broker(origin, Policy(max_fetches=2, max_flights=16))
            try:
                with ThreadPoolExecutor(max_workers=12) as workers:
                    results = list(workers.map(lambda _: broker.fetch('/same.ts'), range(12)))
                self.assertEqual(requests, ['/same.ts'])
                self.assertTrue(all(r.body == MEDIA for r in results))
                with ThreadPoolExecutor(max_workers=8) as workers:
                    results = list(workers.map(lambda n: broker.fetch(f'/{n}.ts'), range(8)))
                self.assertTrue(all(r.body == MEDIA for r in results))
                stats = broker.snapshot()
                self.assertEqual(stats['coalesced'], 11)
                self.assertLessEqual(stats['peakActiveFetches'], 2)
            finally: broker.close()

    def test_consumer_cancellation_does_not_cancel_shared_consumer(self):
        entered = threading.Event()
        cancel = threading.Event()
        def respond(h):
            entered.set()
            time.sleep(.15)
            send(h)
        with origin_server(respond) as origin:
            broker = Broker(origin)
            try:
                with ThreadPoolExecutor(max_workers=2) as workers:
                    first = workers.submit(broker.fetch, '/same.ts', None, cancel.is_set)
                    self.assertTrue(entered.wait(1))
                    second = workers.submit(broker.fetch, '/same.ts')
                    time.sleep(.025)
                    cancel.set()
                    self.assertIsNone(first.result(1))
                    self.assertEqual(second.result(1).body, MEDIA)
                self.assertEqual(broker.snapshot()['originAttempts'], 1)
                self.assertEqual(broker.snapshot()['consumerCancelled'], 1)
            finally: broker.close()

    def test_all_consumers_cancel_stops_retries_and_new_flight_is_bounded(self):
        entered = threading.Event()
        def respond(h):
            entered.set()
            time.sleep(.15)
            send(h, 502, b'')
        with origin_server(respond) as origin:
            broker = Broker(origin, Policy(max_fetches=1, max_flights=1))
            cancel = threading.Event()
            try:
                with ThreadPoolExecutor(max_workers=1) as workers:
                    first = workers.submit(broker.fetch, '/same.ts', None, cancel.is_set)
                    self.assertTrue(entered.wait(1))
                    cancel.set()
                    self.assertIsNone(first.result(1))
                    self.assertEqual(broker.fetch('/same.ts').status, 503)
                time.sleep(.2)
                stats = broker.snapshot()
                self.assertEqual(stats['originAttempts'], 1)
                self.assertEqual(stats['retries'], 0)
                self.assertEqual(stats['inFlight'], 0)
                self.assertEqual(stats['abandonedFlights'], 1)
            finally: broker.close()

    def test_network_reset_retries_complete_body_no_partial_output(self):
        attempts = []
        def respond(h):
            attempts.append(h.path)
            if len(attempts) == 1:
                h.send_response(200)
                h.send_header('Content-Length', str(len(MEDIA)))
                h.end_headers()
                h.wfile.write(MEDIA[:50])
                h.wfile.flush()
                h.connection.shutdown(socket.SHUT_RDWR)
            else: send(h)
        with origin_server(respond) as origin:
            broker = Broker(origin, Policy(retry_seconds=1, attempt_timeout=.2))
            try:
                result = broker.fetch('/s.ts')
                self.assertEqual((result.status, result.body), (200, MEDIA))
                self.assertEqual(len(attempts), 2)
                self.assertEqual(broker.snapshot()['originStatuses']['network'], 1)
            finally: broker.close()

    def test_retry_deadline_retry_after_resource_and_event_bounds(self):
        def respond(h): send(h, 502, b'')
        with origin_server(respond) as origin:
            broker = Broker(origin, Policy(retry_seconds=.35, attempt_timeout=.1, event_limit=1))
            try:
                start = time.monotonic()
                self.assertEqual(broker.fetch('/s.ts').status, 502)
                self.assertLess(time.monotonic()-start, .5)
                self.assertGreater(broker.snapshot()['eventDrops'], 0)
            finally: broker.close()
        def long_delay(h): send(h, 503, b'', Retry_After='10')
        with origin_server(long_delay) as origin:
            broker = Broker(origin, Policy(retry_seconds=.35, attempt_timeout=.1))
            try:
                self.assertEqual(broker.fetch('/s.ts').status, 503)
                self.assertEqual(broker.snapshot()['originAttempts'], 1)
            finally: broker.close()
        def huge(h): send(h, body=MEDIA)
        with origin_server(huge) as origin:
            broker = Broker(origin, Policy(max_resource_bytes=64))
            try:
                result = broker.fetch('/s.ts')
                self.assertEqual((result.status, result.body), (413, b''))
                self.assertEqual(broker.snapshot()['cacheBytes'], 0)
            finally: broker.close()

    def test_slow_trickle_obeys_total_deadline(self):
        def respond(h):
            h.send_response(200)
            h.send_header('Content-Length', '100')
            h.end_headers()
            for _ in range(100):
                h.wfile.write(b'a')
                h.wfile.flush()
                time.sleep(.03)
        with origin_server(respond) as origin:
            broker = Broker(origin, Policy(retry_seconds=.25, attempt_timeout=.1))
            try:
                start = time.monotonic()
                result = broker.fetch('/s.ts')
                self.assertEqual(result.status, 504)
                self.assertEqual(result.body, b'')
                self.assertLess(time.monotonic()-start, .4)
            finally: broker.close()

    def test_http_range_preserves_actual_bytes_and_headers(self):
        ranges = []
        def respond(h):
            ranges.append(h.headers.get('Range'))
            send(h, 206, MEDIA[10:41], Content_Range=f'bytes 10-40/{len(MEDIA)}')
        with origin_server(respond) as origin, LocalHLSProxy(origin) as proxy:
            request = urllib.request.Request(proxy.url('/segment.ts'), headers={'Range': 'bytes=10-40'})
            with urllib.request.urlopen(request, timeout=2) as response:
                self.assertEqual(response.status, 206)
                self.assertEqual(response.read(), MEDIA[10:41])
                self.assertEqual(response.headers['Content-Range'], f'bytes 10-40/{len(MEDIA)}')
            self.assertEqual(ranges, ['bytes=10-40'])

    def test_expired_or_no_store_media_is_not_reused(self):
        requests = []
        def respond(h):
            requests.append(h.path)
            send(h, body=MEDIA, Cache_Control='no-store' if h.path == '/key.key' else 'public')
        with origin_server(respond) as origin:
            broker = Broker(origin, Policy(cache_seconds=.03))
            try:
                broker.fetch('/key.key')
                broker.fetch('/key.key')
                broker.fetch('/segment.ts')
                time.sleep(.05)
                broker.fetch('/segment.ts')
                self.assertEqual(requests, ['/key.key', '/key.key', '/segment.ts', '/segment.ts'])
                self.assertEqual(broker.snapshot()['cacheHits'], 0)
            finally: broker.close()

    def test_close_is_bounded_cancels_active_fetch_and_is_idempotent(self):
        entered = threading.Event()
        def respond(h):
            entered.set()
            time.sleep(1)
            send(h)
        with origin_server(respond) as origin:
            proxy = LocalHLSProxy(origin, Policy(attempt_timeout=.1))
            with ThreadPoolExecutor(max_workers=1) as workers:
                pending = workers.submit(proxy.broker.fetch, '/s.ts')
                self.assertTrue(entered.wait(1))
                start = time.monotonic()
                proxy.close()
                proxy.close()
                self.assertLess(time.monotonic()-start, .3)
                self.assertIsNone(pending.result(1))
                self.assertEqual(proxy.broker.snapshot()['inFlight'], 0)

    def test_client_socket_disconnect_cancels_http_consumer(self):
        entered = threading.Event()
        def respond(h):
            entered.set()
            time.sleep(.15)
            send(h, 502, b'')
        with origin_server(respond) as origin, LocalHLSProxy(origin) as proxy:
            client = socket.create_connection(('127.0.0.1', proxy.server.server_port))
            client.sendall(b'GET /s.ts HTTP/1.1\r\nHost: localhost\r\n\r\n')
            self.assertTrue(entered.wait(1))
            client.close()
            time.sleep(.25)
            stats = proxy.broker.snapshot()
            self.assertEqual(stats['originAttempts'], 1)
            self.assertEqual(stats['consumerCancelled'], 1)
            self.assertEqual(stats['abandonedFlights'], 1)


if __name__ == '__main__': unittest.main()

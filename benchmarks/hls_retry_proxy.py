#!/usr/bin/env python3
"""Experimental local-fixture HLS fetch broker. Never accepts provider URLs.

Relative manifest/segment URIs remain untouched: the broker serves the same
paths and returns complete origin bytes, without remuxing or timestamp changes.
This is deliberately not a production HTTP proxy (no auth, redirects or TLS).
"""
from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
import http.client
import http.server
import email.utils
import math
import re
import select
import socket
import threading
import time
import urllib.error
import urllib.parse
import urllib.request


@dataclass(frozen=True)
class Policy:
    retry_seconds: float = 6.0
    attempt_timeout: float = .75
    max_attempts: int = 16
    max_fetches: int = 8
    max_flights: int = 32
    max_clients: int = 64
    cache_bytes: int = 64 * 1024 * 1024
    cache_items: int = 32
    max_resource_bytes: int = 16 * 1024 * 1024
    cache_seconds: float = 120.0
    event_limit: int = 2048

    def __post_init__(self):
        if (not math.isfinite(self.retry_seconds) or not 0 < self.retry_seconds <= 6
                or not math.isfinite(self.attempt_timeout) or not 0 < self.attempt_timeout <= self.retry_seconds
                or not math.isfinite(self.cache_seconds) or self.cache_seconds <= 0):
            raise ValueError('invalid time budget')
        for name in ('max_attempts', 'max_fetches', 'max_flights', 'max_clients',
                     'cache_bytes', 'cache_items', 'max_resource_bytes', 'event_limit'):
            value = getattr(self, name)
            if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
                raise ValueError('invalid ' + name)
        if self.max_fetches > self.max_flights:
            raise ValueError('fetch limit exceeds flight limit')


@dataclass(frozen=True)
class Resource:
    status: int
    headers: tuple
    body: bytes


@dataclass
class Flight:
    done: threading.Event = field(default_factory=threading.Event)
    cancelled: threading.Event = field(default_factory=threading.Event)
    consumers: int = 0
    result: Resource | None = None


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *_):
        return None


class Broker:
    RETRY_STATUSES = {502, 503, 504}
    CACHE_EXTENSIONS = {'.ts', '.m4s', '.mp4', '.key'}
    RESPONSE_HEADERS = {'content-type', 'content-range', 'accept-ranges', 'etag',
                        'last-modified', 'cache-control', 'content-encoding', 'retry-after'}

    def __init__(self, origin, policy=None):
        parsed = urllib.parse.urlsplit(origin)
        if (parsed.scheme != 'http' or parsed.hostname != '127.0.0.1'
                or parsed.username or parsed.password or parsed.path not in ('', '/')
                or parsed.query or parsed.fragment or parsed.port is None):
            raise ValueError('only an explicit 127.0.0.1 local-fixture origin is allowed')
        self.origin = f'http://127.0.0.1:{parsed.port}'
        self.policy = policy or Policy()
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._permits = threading.BoundedSemaphore(self.policy.max_fetches)
        self._executor = ThreadPoolExecutor(max_workers=self.policy.max_flights,
                                            thread_name_prefix='local-hls-fetch')
        self._flights = {}
        self._all_flights = {}
        self._cache = OrderedDict()
        self._cache_bytes = 0
        self._started = time.monotonic()
        self._events = []
        self._stats = dict(requests=0, cacheHits=0, coalesced=0, originAttempts=0,
                           retries=0, completed=0, completedBytes=0, consumerCancelled=0,
                           abandonedFlights=0, rejectedFlights=0, rejectedClients=0,
                           activeFetches=0, peakActiveFetches=0, peakFlights=0,
                           evicted=0, eventDrops=0, maxFetchMs=0.0, internalFailures=0)
        self._statuses = {}

    @staticmethod
    def validate_path(path):
        parsed = urllib.parse.urlsplit(path)
        decoded = urllib.parse.unquote(parsed.path)
        if (not path.startswith('/') or path.startswith('//') or parsed.scheme
                or parsed.netloc or parsed.fragment or '\\' in decoded
                or any(part in ('.', '..') for part in decoded.split('/'))
                or any(ord(c) < 32 or ord(c) == 127 for c in path + decoded)):
            raise ValueError('non-local resource path')
        return path

    @staticmethod
    def validate_range(value):
        if value is not None and not re.fullmatch(r'bytes=(?:\d+-\d*|-\d+)', value):
            raise ValueError('only a single byte range is supported')
        return value

    def _record(self, kind, **values):
        # Called under the lock; no resource URLs, paths or credentials are emitted.
        if len(self._events) < self.policy.event_limit:
            self._events.append(dict(event=kind, elapsedMs=(time.monotonic()-self._started)*1000, **values))
        else:
            self._stats['eventDrops'] += 1

    def _prune_cache(self):
        now = time.monotonic()
        for key, (_, expiry) in list(self._cache.items()):
            if expiry <= now:
                resource, _ = self._cache.pop(key)
                self._cache_bytes -= len(resource.body)
                self._stats['evicted'] += 1

    def fetch(self, path, byte_range=None, cancelled=None):
        path = self.validate_path(path)
        byte_range = self.validate_range(byte_range)
        key = (path, byte_range)
        cancelled = cancelled or (lambda: False)
        with self._lock:
            self._stats['requests'] += 1
            if self._stop.is_set() or cancelled():
                self._stats['consumerCancelled'] += 1
                return None
            self._prune_cache()
            if key in self._cache:
                result, _ = self._cache[key]
                self._cache.move_to_end(key)
                self._stats['cacheHits'] += 1
                return result
            flight = self._flights.get(key)
            if flight is None:
                if len(self._all_flights) >= self.policy.max_flights:
                    self._stats['rejectedFlights'] += 1
                    return Resource(503, (), b'')
                flight = Flight(consumers=1)
                self._flights[key] = flight
                self._all_flights[id(flight)] = flight
                self._stats['peakFlights'] = max(self._stats['peakFlights'], len(self._all_flights))
                self._executor.submit(self._run_flight, key, flight)
            else:
                flight.consumers += 1
                self._stats['coalesced'] += 1
        try:
            while not flight.done.wait(.025):
                if self._stop.is_set() or cancelled():
                    with self._lock:
                        self._stats['consumerCancelled'] += 1
                    return None
            if self._stop.is_set() or cancelled():
                return None
            return flight.result
        finally:
            with self._lock:
                flight.consumers -= 1
                if not flight.consumers and not flight.done.is_set():
                    flight.cancelled.set()
                    self._stats['abandonedFlights'] += 1
                    # A new consumer must not join this cancelled request.
                    if self._flights.get(key) is flight:
                        self._flights.pop(key)

    def _run_flight(self, key, flight):
        started = time.monotonic()
        try:
            result = self._fetch_origin(key, flight)
        except Exception:
            with self._lock:
                self._stats['internalFailures'] += 1
                self._record('internal-failure')
            # A failed experiment is an HTTP failure, never a half-written media body.
            result = Resource(502, (), b'')
        with self._lock:
            flight.result = result
            if not flight.cancelled.is_set() and not self._stop.is_set():
                self._stats['completed'] += 1
                self._stats['completedBytes'] += len(result.body)
                self._stats['maxFetchMs'] = max(self._stats['maxFetchMs'], (time.monotonic()-started)*1000)
                extension = '.' + urllib.parse.urlsplit(key[0]).path.rsplit('.', 1)[-1].lower()
                if (result.status in (200, 206) and extension in self.CACHE_EXTENSIONS
                        and len(result.body) <= self.policy.cache_bytes
                        and not any(name.lower() == 'cache-control' and 'no-store' in value.lower()
                                    for name, value in result.headers)):
                    # Live manifests are never cached; range is part of identity.
                    while self._cache and (len(self._cache) >= self.policy.cache_items
                            or self._cache_bytes + len(result.body) > self.policy.cache_bytes):
                        _, (evicted, _) = self._cache.popitem(last=False)
                        self._cache_bytes -= len(evicted.body)
                        self._stats['evicted'] += 1
                    self._cache[key] = (result, time.monotonic()+self.policy.cache_seconds)
                    self._cache_bytes += len(result.body)
            if self._flights.get(key) is flight:
                self._flights.pop(key)
            self._all_flights.pop(id(flight), None)
            flight.done.set()

    def _fetch_origin(self, key, flight):
        deadline = time.monotonic() + self.policy.retry_seconds
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        last = Resource(504, (), b'')
        for attempt in range(self.policy.max_attempts):
            if self._stop.is_set() or flight.cancelled.is_set() or time.monotonic() >= deadline:
                return last
            while not self._permits.acquire(timeout=min(.025, max(.001, deadline-time.monotonic()))):
                if self._stop.is_set() or flight.cancelled.is_set() or time.monotonic() >= deadline:
                    return last
            try:
                if self._stop.is_set() or flight.cancelled.is_set() or time.monotonic() >= deadline:
                    return last
                headers = {'Accept-Encoding': 'identity', 'Connection': 'close'}
                if key[1] is not None:
                    headers['Range'] = key[1]
                request = urllib.request.Request(self.origin+key[0], headers=headers)
                with self._lock:
                    self._stats['originAttempts'] += 1
                    self._stats['activeFetches'] += 1
                    self._stats['peakActiveFetches'] = max(self._stats['peakActiveFetches'], self._stats['activeFetches'])
                try:
                    try:
                        response = opener.open(request, timeout=min(self.policy.attempt_timeout, deadline-time.monotonic()))
                    except urllib.error.HTTPError as error:
                        response = error
                    with response:
                        status = response.code
                        retained_headers = tuple((name, value) for name, value in response.headers.items()
                                                 if name.lower() in self.RESPONSE_HEADERS)
                        transport = response.fp if isinstance(response, urllib.error.HTTPError) else response
                        body = bytearray()
                        while True:
                            if self._stop.is_set() or flight.cancelled.is_set():
                                return last
                            if time.monotonic() >= deadline:
                                raise TimeoutError('resource deadline')
                            # read1 yields after one socket read, so slow trickle bodies
                            # cannot hide indefinitely inside a read(size) call.
                            if transport.fp is None:
                                break
                            transport.fp.raw._sock.settimeout(min(self.policy.attempt_timeout, deadline-time.monotonic()))
                            chunk = transport.read1(min(64*1024, self.policy.max_resource_bytes-len(body)+1))
                            if not chunk:
                                break
                            body.extend(chunk)
                            if len(body) > self.policy.max_resource_bytes:
                                return Resource(413, (), b'')
                        expected_length = response.headers.get('Content-Length')
                        if expected_length is not None and int(expected_length) != len(body):
                            raise http.client.IncompleteRead(bytes(body))
                        last = Resource(status, retained_headers, bytes(body))
                    with self._lock:
                        self._statuses[str(status)] = self._statuses.get(str(status), 0)+1
                        self._record('attempt', attempt=attempt+1, status=status, bytes=len(last.body))
                    if status not in self.RETRY_STATUSES:
                        return last
                    retry_after = response.headers.get('Retry-After')
                except (urllib.error.URLError, OSError, http.client.HTTPException, TimeoutError):
                    last = Resource(504, (), b'')
                    retry_after = None
                    with self._lock:
                        self._statuses['network'] = self._statuses.get('network', 0)+1
                        self._record('attempt', attempt=attempt+1, status=0, bytes=0)
                finally:
                    with self._lock:
                        self._stats['activeFetches'] -= 1
            finally:
                self._permits.release()
            delay = min(.1*(2**min(attempt, 3)), .5)
            if retry_after:
                try:
                    seconds = float(retry_after)
                    if math.isfinite(seconds) and seconds >= 0:
                        delay = max(delay, seconds)
                except ValueError:
                    try:
                        date = email.utils.parsedate_to_datetime(retry_after)
                        delay = max(delay, date.timestamp()-time.time())
                    except (ValueError, TypeError, OverflowError):
                        pass
            if attempt+1 >= self.policy.max_attempts or time.monotonic()+delay >= deadline:
                return last
            with self._lock:
                self._stats['retries'] += 1
            # Interrupted when all consumers disappear; another consumer survives independently.
            if flight.cancelled.wait(delay) or self._stop.is_set():
                return last
        return last

    def snapshot(self):
        with self._lock:
            self._prune_cache()
            return dict(schema=1, localFixtureOnly=True, policy=vars(self.policy),
                        **self._stats, cacheItems=len(self._cache), cacheBytes=self._cache_bytes,
                        inFlight=len(self._all_flights), originStatuses=dict(self._statuses),
                        events=list(self._events))

    def close(self):
        self._stop.set()
        with self._lock:
            for flight in self._all_flights.values():
                flight.cancelled.set()
        self._executor.shutdown(wait=True, cancel_futures=False)


class LocalHLSProxy:
    def __init__(self, origin, policy=None):
        self.broker = Broker(origin, policy)
        broker = self.broker

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'

            def log_message(self, *_):
                pass

            def _disconnected(self):
                try:
                    if not select.select([self.connection], [], [], 0)[0]:
                        return False
                    return self.connection.recv(1, socket.MSG_PEEK) == b''
                except OSError:
                    return True

            def do_GET(self):
                if self.headers.get('Authorization') or self.headers.get('Cookie'):
                    self.send_error(400, 'local fixtures only')
                    return
                try:
                    result = broker.fetch(self.path, self.headers.get('Range'), self._disconnected)
                except ValueError:
                    self.send_error(400, 'invalid fixture resource')
                    return
                if result is None:
                    self.close_connection = True
                    return
                self.send_response(result.status)
                for name, value in result.headers:
                    self.send_header(name, value)
                self.send_header('Content-Length', str(len(result.body)))
                self.send_header('Connection', 'close')
                self.end_headers()
                self.close_connection = True
                try:
                    self.wfile.write(result.body)
                except (BrokenPipeError, ConnectionResetError):
                    pass

        class Server(http.server.ThreadingHTTPServer):
            daemon_threads = True
            block_on_close = False

            def __init__(self, *args):
                self.clients = threading.BoundedSemaphore(broker.policy.max_clients)
                super().__init__(*args)

            def process_request(self, request, address):
                if not self.clients.acquire(blocking=False):
                    with broker._lock:
                        broker._stats['rejectedClients'] += 1
                    try:
                        request.sendall(b'HTTP/1.1 503 Busy\r\nContent-Length: 0\r\nConnection: close\r\n\r\n')
                    except OSError:
                        pass
                    self.shutdown_request(request)
                    return
                request.settimeout(broker.policy.retry_seconds + 1)
                super().process_request(request, address)

            def process_request_thread(self, request, address):
                try:
                    super().process_request_thread(request, address)
                finally:
                    self.clients.release()

        self.server = Server(('127.0.0.1', 0), Handler)
        self._thread = threading.Thread(target=self.server.serve_forever, kwargs={'poll_interval': .05},
                                        name='local-hls-proxy', daemon=True)
        self._closed = False
        self._thread.start()

    def url(self, path='/stream.m3u8'):
        return f'http://127.0.0.1:{self.server.server_port}' + self.broker.validate_path(path)

    def close(self):
        if self._closed:
            return
        self._closed = True
        self.server.shutdown()
        self.server.server_close()
        self.broker.close()
        self._thread.join(timeout=1)

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

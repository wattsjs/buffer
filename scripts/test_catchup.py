#!/usr/bin/env python3
"""Integration tests for production XtreamClient using a loopback API fixture."""
import base64
import collections
import http.server
import json
import pathlib
import subprocess
import threading
import time
import unittest
import urllib.parse

ROOT = pathlib.Path(__file__).resolve().parent.parent

class CatchupHTTPTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.executable = ROOT / '.local/bench/catchup-tests'
        cls.executable.parent.mkdir(parents=True, exist_ok=True)
        sources = ['Buffer/Models/SourceChannelIdentity.swift', 'Buffer/Models/Channel.swift', 'Buffer/Models/EPGProgram.swift',
                   'Buffer/Models/ServerConfig.swift', 'Buffer/Models/VODItem.swift',
                   'Buffer/Models/VODSeries.swift', 'Buffer/Services/XtreamClient.swift',
                   'Buffer/Support/AppLog.swift', 'benchmarks/catchup_integration.swift']
        subprocess.run(['swiftc', '-O', *sources, '-o', str(cls.executable)], cwd=ROOT, check=True, timeout=60)

    def run_scenario(self, scenario):
        lock = threading.Lock()
        counts = collections.Counter()
        active = 0
        peak = 0
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_): pass
            def do_GET(self):
                nonlocal active, peak
                query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
                sid = int(query.get('stream_id', ['-1'])[0])
                with lock:
                    counts[sid] += 1
                    active += 1
                    peak = max(peak, active)
                try:
                    time.sleep(.3 if scenario == 'cancel' else .04 + sid % 4 * .01)
                    if scenario == 'all-fail' or (scenario == 'partial' and sid % 3 == 0):
                        self.send_error(503)
                        return
                    listing = dict(id=str(sid), title=base64.b64encode(b'Sport Fixture').decode(),
                                   description=base64.b64encode(b'Match description').decode(),
                                   start_timestamp='1700000300', stop_timestamp='1700000600')
                    expired = dict(listing, id='expired', start_timestamp='1699990000', stop_timestamp='1699990300')
                    invalid = dict(listing, id='invalid', stop_timestamp='0')
                    listings = [listing, expired, invalid]
                    if scenario == 'progress-metadata':
                        listings += [dict(listing, id='nonfinite', start_timestamp='inf', stop_timestamp='inf'),
                                     dict(listing, id='titleless', title='', start_timestamp='1700000400', stop_timestamp='1700000650'),
                                     dict(listing, id='explicit-no-event', title=base64.b64encode(b'No Event Today').decode(), start_timestamp='1700000500', stop_timestamp='1700000700')]
                    body = json.dumps({'epg_listings': listings}).encode()
                    self.send_response(200)
                    self.send_header('Content-Length', str(len(body)))
                    self.send_header('Content-Type', 'application/json')
                    self.end_headers()
                    self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError): pass
                finally:
                    with lock: active -= 1
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        server.daemon_threads = True
        threading.Thread(target=server.serve_forever, daemon=True).start()
        started = time.monotonic()
        try:
            result = subprocess.run([str(self.executable), f'http://127.0.0.1:{server.server_port}', scenario],
                                    capture_output=True, text=True, timeout=15)
            elapsed = time.monotonic() - started
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr[-3000:])
            self.assertLessEqual(peak, 8, 'unbounded HTTP fanout')
            if scenario == 'cancel':
                self.assertLessEqual(sum(counts.values()), 8, 'scheduled more requests after cancellation')
                self.assertLess(elapsed, 1.5, 'slow cancellation')
            else:
                self.assertEqual(counts, collections.Counter({i: 6 if scenario == 'benchmark' else 1 for i in range(24)}))
                self.assertGreater(peak, 1, 'requests unexpectedly serialized')
            if scenario == 'benchmark':
                payload = next(line.removeprefix('CATCHUP_BENCH_JSON ') for line in result.stdout.splitlines() if line.startswith('CATCHUP_BENCH_JSON '))
                report = json.loads(payload)
                report.update(peakRequests=peak, note='Loopback HTTP fixture with controlled 40-70ms response latency; not a live-provider throughput claim')
                out = ROOT / '.logs/catchup-bench.json'
                out.write_text(json.dumps(report, indent=2) + '\n')
            print(result.stdout.strip(), f'peakRequests={peak} requests={sum(counts.values())}')
        finally:
            server.shutdown()
            server.server_close()

    def test_streamed_progress_raw_coverage_and_missing_text(self): self.run_scenario('progress-metadata')
    def test_success(self): self.run_scenario('success')
    def test_partial_errors(self): self.run_scenario('partial')
    def test_all_errors(self): self.run_scenario('all-fail')
    def test_cancellation(self): self.run_scenario('cancel')
    def test_serial_parallel_equivalence(self): self.run_scenario('benchmark')

if __name__ == '__main__': unittest.main()

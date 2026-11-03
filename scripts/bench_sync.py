#!/usr/bin/env python3
"""Measure production catalog/guide overlap using controlled loopback latency.

Run current source: python3 scripts/bench_sync.py
Compare a prior report: python3 scripts/bench_sync.py --compare .logs/sync-bench-latest.json
Compare a saved EPGViewModel source snapshot: --before-source /path/to/EPGViewModel.swift
No saved accounts, real provider, keychain or app cache are accessed.
"""
import argparse
import datetime
import hashlib
import json
import pathlib
import statistics
import subprocess
import sys
import test_sync

ROOT = test_sync.ROOT

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def run():
    parser = argparse.ArgumentParser(description=__doc__)
    baseline = parser.add_mutually_exclusive_group()
    baseline.add_argument('--before-source', type=pathlib.Path)
    baseline.add_argument('--compare', type=pathlib.Path)
    parser.add_argument('--samples', type=int, default=3)
    parser.add_argument('--tolerance', type=float, default=0.15)
    parser.add_argument('--output', type=pathlib.Path, default=ROOT / '.logs/sync-bench-latest.json')
    args = parser.parse_args()
    if args.samples < 1 or args.tolerance < 0:
        parser.error('samples must be positive and tolerance must be nonnegative')
    # Load comparison before a current run can replace the output path.
    previous = json.loads(args.compare.read_text()) if args.compare else None
    test_sync.SyncHTTPTests.setUpClass()
    case = test_sync.SyncHTTPTests('test_guide_publishes_before_slow_catalog')
    current = test_sync.SyncHTTPTests.executable
    report = dict(fixture='sync-http-overlap-v1', schemaVersion=1,
                  configuration='Standalone optimized production EPGViewModel + HTTP clients/parsers; platform/cache stubs',
                  movieAndSeriesLatencyMs=650, guideLatencyMs=20, after=[],
                  afterSourceSHA256=digest(ROOT / 'Shared/Support/PerfMetrics.swift', 'Shared/Support/AppLog.swift', 'Shared/ViewModels/EPGViewModel.swift'),
                  afterExecutableSHA256=digest(current),
                  sourceHashes={p: digest(ROOT / p) for p in [*test_sync.SOURCES, test_sync.BRIDGE_HEADER]},
                  recordedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  limitations='Controlled loopback latency; not a live-provider throughput claim or full-app Debug CPU/RSS measurement.')
    before_executable = None
    if args.before_source:
        source = args.before_source.resolve(strict=True)
        before_executable = ROOT / '.local/bench/sync-tests-before'
        sources = [str(source) if p == 'Shared/ViewModels/EPGViewModel.swift' else p for p in test_sync.SOURCES]
        subprocess.run(['swiftc', '-O', '-I', 'Shared/SwiftLibxml2', '-import-objc-header', test_sync.BRIDGE_HEADER, *sources,
                        '-o', str(before_executable)], cwd=ROOT, check=True, timeout=90)
        report.update(before=[], beforeSourceSHA256=digest(source), beforeExecutableSHA256=digest(before_executable))
    for _ in range(args.samples):
        if before_executable:
            case.executable = before_executable
            case.expect_parallel_catalog = False
            report['before'].append(case.run_scenario('overlap'))
        case.executable = current
        case.expect_parallel_catalog = True
        report['after'].append(case.run_scenario('overlap'))
    median = statistics.median(r['elapsedMs'] for r in report['after'])
    baseline_samples = report.get('before')
    if previous:
        for field in ('fixture', 'configuration', 'movieAndSeriesLatencyMs', 'guideLatencyMs'):
            if previous.get(field) != report[field]:
                raise ValueError(f'incompatible baseline field: {field}')
        baseline_samples = previous['after']
    failed = False
    if baseline_samples:
        before_median = statistics.median(r['elapsedMs'] for r in baseline_samples)
        report.update(baselineMedianMs=before_median, medianMs=median,
                      changeFraction=(median / before_median) - 1)
        failed = median > before_median * (1 + args.tolerance)
    else:
        report['medianMs'] = median
    report['regression'] = failed
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(f'Current median {median:.0f}ms; report {args.output}')
    if baseline_samples:
        print(f'Baseline median {before_median:.0f}ms; change {report["changeFraction"]:+.1%}')
    return 2 if failed else 0

if __name__ == '__main__':
    try:
        sys.exit(run())
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f'Benchmark evidence error: {error}', file=sys.stderr)
        sys.exit(1)

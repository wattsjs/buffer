#!/usr/bin/env python3
"""Measure first useful production guide publication, history coverage and tail.

Runs only loopback fixtures, actual clients/parsers/EPGViewModel, isolated caches.
--before-source compares a saved EPGViewModel.swift snapshot; --compare gates a
prior compatible report. Provider-side history truncation is represented as
7 advertised archive days but only2 actual returned schedule days.
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

def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()

def run():
    parser = argparse.ArgumentParser(description=__doc__)
    base = parser.add_mutually_exclusive_group()
    base.add_argument('--before-source', type=pathlib.Path)
    base.add_argument('--compare', type=pathlib.Path)
    parser.add_argument('--scenario', choices=['guide-progressive', 'guide-slow-xml', 'guide-empty-xml'], default='guide-progressive')
    parser.add_argument('--samples', type=int, default=3)
    parser.add_argument('--tolerance', type=float, default=.15)
    parser.add_argument('--output', type=pathlib.Path, default=ROOT / '.logs/guide-bench-latest.json')
    args = parser.parse_args()
    if args.samples < 1 or args.tolerance < 0: parser.error('invalid samples/tolerance')
    previous = json.loads(args.compare.read_text()) if args.compare else None
    test_sync.SyncHTTPTests.setUpClass()
    case = test_sync.SyncHTTPTests('test_current_guide_publishes_before_slow_partial_history')
    current = test_sync.SyncHTTPTests.executable
    case.measure_only = True
    report = dict(schemaVersion=1, fixture='guide-progressive-96-v1', scenario=args.scenario,
                  configuration='Optimized standalone production VM/HTTP clients/parsers; isolated platform/cache dependencies',
                  after=[], afterSourceSHA256=digest(ROOT / 'Shared/Support/PerfMetrics.swift', 'Shared/Support/AppLog.swift', 'Shared/ViewModels/EPGViewModel.swift'),
                  afterExecutableSHA256=digest(current),
                  sourceHashes={p: digest(ROOT / p) for p in [*test_sync.SOURCES, test_sync.BRIDGE_HEADER]},
                  recordedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  limitations='Controlled loopback latency and8 failed stream APIs plus failed bulk lookback. Not a real-provider throughput claim; missing schedules stay missing.')
    before_binary = None
    if args.before_source:
        source = args.before_source.resolve(strict=True)
        before_binary = ROOT / '.local/bench/guide-before-tests'
        sources = [str(source) if p == 'Shared/ViewModels/EPGViewModel.swift' else p for p in test_sync.SOURCES]
        subprocess.run(['swiftc', '-O', '-I', 'Shared/SwiftLibxml2', '-import-objc-header', test_sync.BRIDGE_HEADER, *sources, '-o', str(before_binary)], cwd=ROOT, check=True, timeout=90)
        report.update(before=[], beforeSourceSHA256=digest(source), beforeExecutableSHA256=digest(before_binary))
    for _ in range(args.samples):
        if before_binary:
            case.executable = before_binary
            case.expect_visible_priority = False
            report['before'].append(case.run_scenario(args.scenario))
        case.executable = current
        case.expect_visible_priority = True
        report['after'].append(case.run_scenario(args.scenario))
    baseline = report.get('before')
    if previous:
        for field in ('schemaVersion', 'fixture', 'scenario', 'configuration'):
            if previous.get(field) != report[field]: raise ValueError(f'incompatible baseline: {field}')
        baseline = previous['after']
    metrics = ['firstCurrentMs', 'firstVisibleHistoryMs', 'completeMs']
    report['medianMs'] = {field: statistics.median(r[field] for r in report['after']) for field in metrics}
    regression = False
    if baseline:
        report['baselineMedianMs'] = {field: statistics.median(r[field] for r in baseline) for field in metrics}
        for field in ('currentRows', 'historyChannels'):
            if any(r[field] != report['after'][0][field] for r in baseline + report['after']):
                raise ValueError(f'coverage changed: {field}; cannot treat this as equivalent benchmark output')
        report['changeFraction'] = {field: report['medianMs'][field] / report['baselineMedianMs'][field] - 1 for field in metrics}
        regression = any(change > args.tolerance for change in report['changeFraction'].values())
    report['regression'] = regression
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(dict(medianMs=report['medianMs'], changeFraction=report.get('changeFraction'), output=str(args.output))))
    return 2 if regression else 0

if __name__ == '__main__':
    try: sys.exit(run())
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f'Guide benchmark evidence error: {error}', file=sys.stderr)
        sys.exit(1)

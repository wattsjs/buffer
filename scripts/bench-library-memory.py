#!/usr/bin/env python3
"""Measure retained production search-index allocation with unmatched XMLTV IDs.

The production EPGViewModel, clients, parsers and guide lookup compile unchanged.
Only platform/cache dependencies use the same isolated in-memory test support as
sync integration tests. No saved sources, provider, Keychain or app cache is used.
Hydration timing includes guide preparation; capacity is not an RSS claim.
"""
import argparse
import datetime
import hashlib
import json
import pathlib
import re
import statistics
import subprocess
import uuid

from test_sync import BRIDGE_HEADER, SOURCES

ROOT = pathlib.Path(__file__).resolve().parent.parent


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def compile_driver(name, model):
    executable = ROOT / '.local/bench' / f'library-memory-{name}'
    paths = [model if p == 'Buffer/Support/PerfMetrics.swift', 'Buffer/Support/AppLog.swift', 'Buffer/ViewModels/EPGViewModel.swift' else ROOT / p for p in SOURCES]
    header = ROOT / BRIDGE_HEADER
    inputs = paths + [header]
    input_hashes = [digest(p) for p in inputs]
    subprocess.run(['swiftc', '-O', '-I', str(ROOT / 'Buffer/SwiftLibxml2'),
                    '-import-objc-header', str(header),
                    *map(str, paths), '-o', str(executable)], cwd=ROOT, check=True, timeout=90)
    if input_hashes != [digest(p) for p in inputs]:
        raise ValueError('benchmark sources changed during compilation')
    return executable, {str(p.relative_to(ROOT)) if p.is_relative_to(ROOT) else p.name: digest(p)
                        for p in inputs}


def measure(executable):
    result = subprocess.run(['/usr/bin/time', '-l', str(executable),
                             'http://127.0.0.1:1', 'library-search-benchmark'],
                            cwd=ROOT, capture_output=True, text=True, check=True, timeout=15)
    data = json.loads(next(line.removeprefix('LIBRARY_MEMORY_JSON ')
                           for line in result.stdout.splitlines() if line.startswith('LIBRARY_MEMORY_JSON ')))
    match = re.search(r'(\d+)\s+maximum resident set size', result.stderr)
    if not match:
        raise ValueError('missing macOS process RSS evidence')
    data['peakRSSBytes'] = int(match.group(1))
    data['reservedEntryBytes'] = data['searchCapacity'] * data['entryStride']
    if (data['guidePrograms'], data['searchEntries'], data['checksum']) != (100_003, 3, 3):
        raise ValueError('search output/fixture changed')
    return data


def run():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--before-view-model', type=pathlib.Path)
    parser.add_argument('--compare', type=pathlib.Path)
    parser.add_argument('--trials', type=int, default=5)
    parser.add_argument('--output', type=pathlib.Path, default=ROOT / '.logs/library-memory-latest.json')
    args = parser.parse_args()
    if args.trials < 1 or args.before_view_model and args.compare:
        parser.error('positive trials and either source control or prior report required')
    prior = json.loads(args.compare.read_text()) if args.compare else None
    run_id = uuid.uuid4().hex[:12]
    (ROOT / '.local/bench').mkdir(parents=True, exist_ok=True)
    executable, hashes = compile_driver('after-' + run_id, ROOT / 'Buffer/ViewModels/EPGViewModel.swift')
    report = dict(schemaVersion=1, fixture='library-search-unmatched-v1', configuration='optimized',
                  recordedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  sourceHashes=hashes, executableSHA256=digest(executable), after=[],
                  limitations='Synthetic in-memory hydration. Capacity is unused reserved element storage; process peak RSS includes fixture generation and guide preparation. Timing is whole hydration/search publication, not isolated search construction.')
    control = None
    if args.before_view_model:
        control, report['beforeSourceHashes'] = compile_driver('before-' + run_id, args.before_view_model.resolve(strict=True))
        report.update(beforeExecutableSHA256=digest(control), before=[])
    if prior and any(prior.get(key) != report[key] for key in ('schemaVersion', 'fixture', 'configuration')):
        raise ValueError('incompatible baseline metadata')
    for trial in range(args.trials):
        engines = [('before', control), ('after', executable)] if control else [('after', executable)]
        if trial % 2:
            engines.reverse()
        for label, binary in engines:
            report[label].append(measure(binary))
    report['medianElapsedMs'] = statistics.median(x['elapsedMs'] for x in report['after'])
    report['medianPeakRSSBytes'] = statistics.median(x['peakRSSBytes'] for x in report['after'])
    report['reservedEntryBytes'] = report['after'][0]['reservedEntryBytes']
    references = report.get('before', prior.get('after') if prior else None)
    if references:
        report['baselineReservedEntryBytes'] = references[0]['reservedEntryBytes']
        report['baselineMedianElapsedMs'] = statistics.median(x['elapsedMs'] for x in references)
        report['baselineMedianPeakRSSBytes'] = statistics.median(x['peakRSSBytes'] for x in references)
    report['regression'] = bool(references and report['reservedEntryBytes'] > report['baselineReservedEntryBytes'])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(f"search entries=3 reserved={report['reservedEntryBytes']} bytes "
          f"whole-hydration median={report['medianElapsedMs']:.1f}ms "
          f"peak RSS={report['medianPeakRSSBytes']/1048576:.1f}MiB")
    if references:
        print(f"baseline reserved={report['baselineReservedEntryBytes']} bytes "
              f"whole-hydration median={report['baselineMedianElapsedMs']:.1f}ms "
              f"peak RSS={report['baselineMedianPeakRSSBytes']/1048576:.1f}MiB")
    return 2 if report['regression'] else 0


if __name__ == '__main__':
    raise SystemExit(run())

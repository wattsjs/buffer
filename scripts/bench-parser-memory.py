#!/usr/bin/env python3
"""Benchmark production parsers with synthetic fixtures in isolated processes.

RSS includes fixture generation and Foundation allocator reuse; output-buffer
capacity is a separate allocation metric, not a resident-memory claim.
No saved sources, app process, provider, keychain or app data cache are used.
"""
import argparse
import datetime
import hashlib
import json
import pathlib
import statistics
import subprocess
import sys
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[1]
COMMON = ['Shared/Models/EPGProgram.swift', 'Shared/Models/SourceChannelIdentity.swift', 'Shared/Models/Channel.swift',
          'Shared/Models/VODItem.swift', 'Shared/Support/AppLog.swift',
          'benchmarks/parser_memory_benchmark.swift']


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def compile_parser(name, configuration, xml, m3u):
    executable = ROOT / '.local/bench' / f'parser-memory-{configuration}-{name}'
    sources = [ROOT / p for p in COMMON] + [xml, m3u]
    header = ROOT / 'Shared/Support/ChannelIdentityEncoding.h'
    inputs = sources + [header]
    input_hashes = [digest(p) for p in inputs]
    subprocess.run(['swiftc', '-O' if configuration == 'optimized' else '-Onone',
                    '-I', str(ROOT / 'Shared/SwiftLibxml2'),
                    '-import-objc-header', str(header),
                    *map(str, sources), '-o', str(executable)], cwd=ROOT,
                   check=True, timeout=90)
    if input_hashes != [digest(p) for p in inputs]:
        raise ValueError('benchmark sources changed during compilation')
    return executable, {str(p.relative_to(ROOT)) if p.is_relative_to(ROOT) else p.name: digest(p)
                        for p in inputs}


def measure(executable, case, samples):
    result = subprocess.run([str(executable), case['kind'], str(case['count']),
                             str(samples + 1), str(case['descriptionBytes'])],
                            cwd=ROOT, check=True, capture_output=True, text=True, timeout=90)
    data = json.loads(result.stdout)
    if data['count'] != case['count'] or len(data['samplesMs']) != samples:
        raise ValueError('missing parser output or samples')
    data['medianMs'] = statistics.median(data['samplesMs'])
    return data


def run():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--before-xml', type=pathlib.Path)
    parser.add_argument('--before-m3u', type=pathlib.Path)
    parser.add_argument('--compare', type=pathlib.Path)
    parser.add_argument('--configuration', choices=['debug', 'optimized'], default='debug')
    parser.add_argument('--trials', type=int, default=3)
    parser.add_argument('--samples', type=int, default=7)
    parser.add_argument('--tolerance', type=float, default=0.15)
    parser.add_argument('--absolute-tolerance-ms', type=float, default=0.05,
                        help='minimum elapsed-time difference for a regression; protects microsecond capacity fixtures from timer noise')
    parser.add_argument('--quick', action='store_true')
    parser.add_argument('--identity-cases', action='store_true', help='50k provided-ID and ID-less M3U fixtures')
    parser.add_argument('--output', type=pathlib.Path, default=ROOT / '.logs/parser-memory-latest.json')
    args = parser.parse_args()
    if args.trials < 1 or args.samples < 1 or args.tolerance < 0 or args.absolute_tolerance_ms < 0:
        parser.error('trials/samples must be positive and tolerance nonnegative')
    if args.compare and (args.before_xml or args.before_m3u):
        parser.error('use either source snapshots or a prior report')
    previous = json.loads(args.compare.read_text()) if args.compare else None
    (ROOT / '.local/bench').mkdir(parents=True, exist_ok=True)
    xml, m3u = ROOT / 'Shared/Support/PerfMetrics.swift', 'Shared/Services/XMLTVParser.swift', ROOT / 'Shared/Services/M3UParser.swift'
    run_id = uuid.uuid4().hex[:12]
    after, hashes = compile_parser('after-' + run_id, args.configuration, xml, m3u)
    before = None
    before_hashes = None
    if args.before_xml or args.before_m3u:
        before, before_hashes = compile_parser('control-' + run_id, args.configuration,
            args.before_xml.resolve(strict=True) if args.before_xml else xml,
            args.before_m3u.resolve(strict=True) if args.before_m3u else m3u)
    cases = [dict(kind=k, count=n, descriptionBytes=d) for k, n, d in (
        [('m3u', 50000, 0), ('m3u-idless', 50000, 0)] if args.identity_cases else
        [('xml', 1000, 128), ('m3u', 50000, 0)] if args.quick else
        [('xml', 1, 128), ('xml', 1000, 128), ('xml', 50000, 1024),
         ('xml', 350000, 128), ('m3u', 1000, 0), ('m3u', 50000, 0)])]
    report = dict(schemaVersion=1, fixture='parser-identity-v1' if args.identity_cases else 'parser-memory-v1', configuration=args.configuration,
        cases=[], trials=args.trials, samples=args.samples, absoluteToleranceMs=args.absolute_tolerance_ms,
        recordedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),
        sourceHashes=hashes, executableSHA256=digest(after),
        compiler=subprocess.check_output(['swiftc', '--version'], text=True).strip(),
        limitations='Synthetic fixtures, standalone production parsers; RSS includes fixture generation and allocator reuse. Reserved element bytes are not resident-memory bytes.')
    if before:
        report.update(beforeSourceHashes=before_hashes, beforeExecutableSHA256=digest(before))
    if previous and any(previous.get(field) != report[field] for field in ['schemaVersion', 'fixture', 'configuration']):
        raise ValueError('incompatible baseline metadata')
    if previous and [dict(kind=c['kind'], count=c['count'], descriptionBytes=c['descriptionBytes']) for c in previous['cases']] != cases:
        raise ValueError('incompatible baseline fixtures')
    regression = False
    for case_index, case in enumerate(cases):
        item = dict(**case, after=[])
        if before: item['before'] = []
        for trial in range(args.trials):
            engines = [('before', before), ('after', after)] if before else [('after', after)]
            if trial % 2: engines.reverse()
            for key, executable in engines:
                item[key].append(measure(executable, case, args.samples))
        item['medianMs'] = statistics.median(r['medianMs'] for r in item['after'])
        item['medianPeakRSSBytes'] = statistics.median(r['peakRSSBytes'] for r in item['after'])
        reference = item.get('before') if before else previous['cases'][case_index]['after'] if previous else None
        current = item['after'][0]
        if any((r['count'], r['checksum'], r['inputBytes']) != (current['count'], current['checksum'], current['inputBytes'])
               for r in item['after'] + (reference or [])):
            raise ValueError('parser fixture/checksum differs')
        if reference:
            baseline = statistics.median(r['medianMs'] for r in reference)
            item.update(baselineMedianMs=baseline, changeFraction=item['medianMs'] / baseline - 1,
                        regression=item['medianMs'] - baseline > max(baseline * args.tolerance, args.absolute_tolerance_ms))
            regression |= item['regression']
        report['cases'].append(item)
        print(f"{case['kind']} count={case['count']} median={item['medianMs']:.3f}ms "
              f"peak={item['medianPeakRSSBytes']/1048576:.1f}MiB "
              + (f"change={item['changeFraction']:+.1%}" if reference else ''), flush=True)
    report['regression'] = regression
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(f'Report {args.output}')
    return 2 if regression else 0


if __name__ == '__main__':
    try:
        sys.exit(run())
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f'Benchmark evidence error: {error}', file=sys.stderr)
        sys.exit(1)

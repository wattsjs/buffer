#!/usr/bin/env python3
"""Run real Buffer benchmark functions; compare equivalent builds, fail closed."""
import argparse
import datetime
import hashlib
import json
import pathlib
import platform
import statistics
import subprocess
import sys
import build_config

ROOT = pathlib.Path(__file__).resolve().parent.parent

def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT, text=True).strip()

def compare(report, baseline, tolerance):
    for candidate in (report, baseline):
        metadata = candidate.get('buildMetadata')
        if not isinstance(metadata, dict):
            raise ValueError('Incompatible baseline: missing executable build metadata; capture a new baseline')
        profile = next((name for name, values in build_config.CONFIGURATIONS.items()
                        if values['label'] == candidate.get('configuration')), None)
        if profile is None:
            raise ValueError('Incompatible baseline: unsupported configuration')
        build_config.validate_metadata(metadata, profile)
    for field in ('schema', 'fixture', 'machine', 'configuration'):
        if baseline.get(field) != report.get(field):
            raise ValueError(f'Incompatible baseline: {field}')
    if baseline['buildMetadata'] != report['buildMetadata']:
        raise ValueError('Incompatible baseline: executable build metadata')
    old = {m['name']: m for m in baseline['measurements']}
    if set(old) != {m['name'] for m in report['measurements']}:
        raise ValueError('Baseline case coverage differs')
    regressions = []
    for m in report['measurements']:
        previous = old[m['name']]
        if previous['checksum'] != m['checksum']:
            raise ValueError(f'Output changed: {m["name"]}')
        before = statistics.median(previous['samplesMs'])
        after = statistics.median(m['samplesMs'])
        print(f'{m["name"]}: {before:.3f} -> {after:.3f} ms ({(after / before - 1)*100:+.1f}%)')
        if after > before * (1 + tolerance):
            regressions.append(m['name'])
    return regressions

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--compare', type=pathlib.Path)
    parser.add_argument('--tolerance', type=float, default=0.15)
    parser.add_argument('--configuration', choices=list(build_config.CONFIGURATIONS), default='debug')
    args = parser.parse_args()
    if not 0 <= args.tolerance <= 1:
        parser.error('tolerance must be between 0 and 1')
    baseline = json.loads(args.compare.read_text()) if args.compare else None
    executable = build_config.executable_path(args.configuration)
    metadata = build_config.read_binary_metadata(executable, args.configuration)
    artifact = build_config.artifact_fingerprint(executable)
    binary_hash = artifact['sha256']
    result = subprocess.run([str(executable), '--benchmark'], cwd=ROOT,
                            capture_output=True, text=True, timeout=180)
    if result.returncode:
        raise RuntimeError(f'Benchmark process exited {result.returncode}: {result.stderr[-2000:]}')
    lines = [line.removeprefix('BUFFER_BENCH_JSON ') for line in result.stdout.splitlines()
             if line.startswith('BUFFER_BENCH_JSON ')]
    if len(lines) != 1:
        raise ValueError('Missing or duplicate benchmark result')
    report = json.loads(lines[0])
    if report.get('schema') != 3:
        raise ValueError('Unsupported benchmark schema; rebuild the app')
    if report.get('buildMetadata') != metadata:
        raise ValueError('Benchmark metadata differs from executable preflight')
    if binary_hash != build_config.binary_sha256(executable):
        raise ValueError('Measured executable changed during benchmark')
    expected_cases = {'playlist-parse-1000', 'xmltv-parse-1000', 'guide-lookup-480',
                      'sports-index-48000', 'sports-shared-guide-96000'}
    measurements = report.get('measurements', [])
    if len(measurements) != len(expected_cases) or {m['name'] for m in measurements} != expected_cases:
        raise ValueError('Incomplete benchmark coverage')
    for m in report['measurements']:
        if len(m['samplesMs']) != 7 or any(not 0 < n < 180000 for n in m['samplesMs']):
            raise ValueError('Invalid timing samples')
    diff = git('diff', 'HEAD')
    report.update(machine={'arch': platform.machine(), 'os': platform.mac_ver()[0]},
                  configuration=metadata['configuration'], commit=git('rev-parse', 'HEAD'),
                  worktreeDiffSHA256=hashlib.sha256(diff.encode()).hexdigest(),
                  binarySHA256=binary_hash,
                  artifactFingerprint=artifact,
                  recordedAt=datetime.datetime.now(datetime.timezone.utc).isoformat())
    folder = ROOT / '.logs'
    folder.mkdir(exist_ok=True)
    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
    payload = json.dumps(report, indent=2) + '\n'
    (folder / f'bench-{args.configuration}-{stamp}.json').write_text(payload)
    (folder / 'bench-latest.json').write_text(payload)
    (folder / f'bench-{args.configuration}-latest.json').write_text(payload)
    for m in report['measurements']:
        print(f'{m["name"]}: median={statistics.median(m["samplesMs"]):.3f}ms checksum={m["checksum"]}')
    if args.compare:
        failures = compare(report, baseline, args.tolerance)
        if failures:
            print('REGRESSION: ' + ', '.join(failures), file=sys.stderr)
            return 2
    print(f'Saved .logs/bench-{args.configuration}-latest.json '
          f'({metadata["configuration"]}; full-app binary, instrumented timings, not Release claims)')
    return 0

if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, RuntimeError, OSError, subprocess.SubprocessError) as error:
        print(f'Benchmark failed: {error}', file=sys.stderr)
        sys.exit(1)

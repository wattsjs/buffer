#!/usr/bin/env python3
"""Verify and benchmark production poster thumbnail requests with built Nuke.

The control uses full NSImage decode plus the previous resize processor. Trials
run in isolated processes with the same synthetic local JPEG and Nuke object.
This measures decode/resize work; it does not measure network or full-app RSS.
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
SOURCES = ['Buffer/Support/RecentImageFailures.swift', 'Buffer/Services/ArtworkImageDecoder.swift', 'Buffer/Services/ImageLoader.swift',
           'Buffer/Services/LogoColorAnalyzer.swift', 'Buffer/Services/LogoAtlas.swift',
           'benchmarks/image_decode_benchmark.swift']


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--products-dir', type=pathlib.Path, default=ROOT / 'DerivedData/Build/Products/Debug')
    parser.add_argument('--trials', type=int, default=5)
    parser.add_argument('--test-only', action='store_true')
    parser.add_argument('--compare', type=pathlib.Path)
    parser.add_argument('--tolerance', type=float, default=0.15)
    parser.add_argument('--output', type=pathlib.Path, default=ROOT / '.logs/artwork-bench-latest.json')
    args = parser.parse_args()
    if args.trials < 1 or args.tolerance < 0:
        parser.error('trials must be positive and tolerance nonnegative')
    previous = json.loads(args.compare.read_text()) if args.compare else None
    nuke = args.products_dir.resolve(strict=True) / 'Nuke.o'
    run_directory = ROOT / '.local/bench' / ('artwork-' + uuid.uuid4().hex[:12])
    run_directory.mkdir(parents=True, exist_ok=True)
    executable = run_directory / 'image-decode'
    fixture = run_directory / 'artwork-4k.jpg'
    subprocess.run(['swiftc', '-O', '-I', str(args.products_dir.resolve()),
                    *[str(ROOT / p) for p in SOURCES], str(nuke), '-o', str(executable)],
                   cwd=ROOT, check=True, timeout=90)
    # Always regenerate in another process so creation memory is excluded
    # from the isolated decode trials.
    subprocess.run([str(executable), 'generate', str(fixture)], check=True, timeout=30)
    subprocess.run([str(executable), 'test', str(fixture)], check=True, timeout=30)
    rotated_fixture = run_directory / 'artwork-4k-rotated.jpg'
    subprocess.run([str(executable), 'generate-rotated', str(rotated_fixture)], check=True, timeout=30)
    subprocess.run([str(executable), 'test', str(rotated_fixture)], check=True, timeout=30)
    pdf_fixture = run_directory / 'artwork-vector.pdf'
    subprocess.run([str(executable), 'generate-pdf', str(pdf_fixture)], check=True, timeout=30)
    subprocess.run([str(executable), 'test', str(pdf_fixture)], check=True, timeout=30)
    if args.test_only: return 0
    report = dict(schemaVersion=1, fixture='artwork-4k-jpeg-v1', fixtureSHA256=digest(fixture),
                  sourceHashes={p: digest(ROOT / p) for p in SOURCES},
                  executableSHA256=digest(executable), nukeObjectSHA256=digest(nuke),
                  configuration=f'Standalone Swift -O driver + built Nuke {args.products_dir.name} object',
                  recordedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(), trials=[],
                  limitations='Decode/resize surface only, synthetic JPEG, no network. RSS includes framework working set and can increase despite lower CPU time.')
    if previous and any(previous.get(field) != report[field] for field in ['schemaVersion', 'fixture', 'fixtureSHA256', 'configuration', 'nukeObjectSHA256']):
        raise ValueError('incompatible artwork baseline metadata')
    for trial in range(args.trials):
        row = dict(trial=trial)
        for mode in (['resize', 'thumbnail'] if trial % 2 == 0 else ['thumbnail', 'resize']):
            output = subprocess.run([str(executable), mode, str(fixture)],
                                    check=True, capture_output=True, text=True, timeout=30)
            sample = json.loads(output.stdout)
            if len(sample['samplesMs']) != 10 or sample['width'] <= 0 or sample['height'] <= 0:
                raise ValueError('missing artwork measurement')
            sample['medianMs'] = statistics.median(sample['samplesMs'])
            row[mode] = sample
        if (row['resize']['width'], row['resize']['height']) != (row['thumbnail']['width'], row['thumbnail']['height']):
            raise ValueError('artwork geometry differs')
        report['trials'].append(row)
    for mode in ['resize', 'thumbnail']:
        report[mode + 'MedianMs'] = statistics.median(t[mode]['medianMs'] for t in report['trials'])
        report[mode + 'MedianPeakRSSBytes'] = statistics.median(t[mode]['peakRSSBytes'] for t in report['trials'])
    reference = previous['thumbnailMedianMs'] if previous else report['resizeMedianMs']
    report.update(changeFraction=report['thumbnailMedianMs'] / reference - 1,
                  regression=report['thumbnailMedianMs'] > reference * (1 + args.tolerance))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(f"Resize {report['resizeMedianMs']:.2f}ms → thumbnail {report['thumbnailMedianMs']:.2f}ms; "
          f"comparison change {report['changeFraction']:+.1%}; report {args.output}")
    return 2 if report['regression'] else 0


if __name__ == '__main__':
    try:
        sys.exit(run())
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f'Artwork benchmark evidence error: {error}', file=sys.stderr)
        sys.exit(1)

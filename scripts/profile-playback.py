#!/usr/bin/env python3
"""Sample only an owned Buffer child playing the controlled local HLS corpus.

Sampling perturbs playback. Use an independent unsampled capture for CPU and
frame-drop comparisons; this artifact exists to attribute work to stacks.
"""
import argparse
import datetime
import json
import os
import pathlib
import signal
import subprocess
import sys
import time

import build_config

ROOT = pathlib.Path(__file__).resolve().parent.parent


def owned_child(parent_pid, executable):
    listing = subprocess.check_output(
        ['ps', '-axo', 'pid=,ppid=,comm='], text=True
    )
    for line in listing.splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) != 3 or int(fields[1]) != parent_pid:
            continue
        if pathlib.Path(fields[2]).resolve() == executable.resolve():
            return int(fields[0])
    return None


def rendered_capture(directory):
    for path in directory.glob('playback-*/stdout.log'):
        if path.parent in rendered_capture.existing:
            continue
        # The bounded local run emits only a few dozen records.
        for line in path.read_text(errors='replace').splitlines():
            if not line.startswith('BUFFER_PLAYBACK_JSON '):
                continue
            try:
                event = json.loads(line.removeprefix('BUFFER_PLAYBACK_JSON '))
            except json.JSONDecodeError:
                continue
            if (event.get('event') == 'sample' and event.get('rendered')
                    and event.get('elapsedMs', 0) >= 8_000
                    and event.get('renderedFrameCount', 0) > 0):
                return path.parent
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--configuration', choices=['debug', 'optimized'], default='optimized')
    parser.add_argument('--seconds', type=int, default=30)
    args = parser.parse_args()
    if not 20 <= args.seconds <= 60:
        parser.error('seconds must be 20..60')
    executable = build_config.executable_path(args.configuration)
    destination = ROOT / '.logs' / ('render-profile-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
    destination.mkdir(parents=True)
    rendered_capture.existing = set((ROOT / '.logs').glob('playback-*'))
    command = [sys.executable, str(ROOT / 'scripts/playback.py'),
               '--engine', 'mpv', '--configuration', args.configuration,
               '--profile', '1080p60', '--seconds', str(args.seconds),
               '--ao', 'avfoundation', '--fault', 'none']
    result = dict(purpose='stack attribution; sampling perturbs this playback run',
                  buildMetadata=build_config.read_binary_metadata(executable, args.configuration),
                  artifactFingerprint=build_config.artifact_fingerprint(executable),
                  command=command, sampled=False)
    with (destination / 'harness.log').open('w') as log:
        proc = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + args.seconds + 30
            capture = None
            while proc.poll() is None and time.monotonic() < deadline:
                child_pid = owned_child(proc.pid, executable)
                capture = rendered_capture(ROOT / '.logs')
                if child_pid is not None and capture is not None:
                    result['ownedPID'] = child_pid
                    result['playbackArtifacts'] = str(capture)
                    # Ownership and executable are rechecked immediately before attach.
                    if owned_child(proc.pid, executable) != child_pid:
                        raise RuntimeError('owned playback child changed before sampling')
                    sample_command = ['/usr/bin/sample', str(child_pid), '5', '1',
                                      '-file', str(destination / 'stacks.sample.txt')]
                    sample = subprocess.run(sample_command, capture_output=True, text=True, timeout=20)
                    (destination / 'sample.log').write_text(sample.stdout + sample.stderr)
                    result['sampleExitCode'] = sample.returncode
                    result['sampled'] = sample.returncode == 0
                    break
                time.sleep(.5)
            result['harnessExitCode'] = proc.wait(timeout=args.seconds + 25)
            if capture is not None and (capture / 'report.json').exists():
                report = json.loads((capture / 'report.json').read_text())
                result['sampledCapturePassed'] = report.get('passed', False)
                result['sampledCaptureFailures'] = report.get('failures', [])
        finally:
            if proc.poll() is None:
                child_pid = owned_child(proc.pid, executable)
                if child_pid is not None:
                    # Terminating Python does not guarantee its finally runs.
                    # Recheck ownership and close its exact player first.
                    try:
                        os.kill(child_pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
                proc.terminate()
                try:
                    proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
    (destination / 'metadata.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
    print(f'Profile artifacts: {destination}')
    return 0 if result['sampled'] and result.get('sampledCapturePassed') else 1


if __name__ == '__main__':
    raise SystemExit(main())

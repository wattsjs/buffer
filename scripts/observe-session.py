#!/usr/bin/env python3
"""Launch one normal saved-library session; record numeric state without URLs.

Observation completion leaves the app running. An early exit or missing samples
is an evidence failure. Playback health is diagnostic: do not call idle or
user-paused sessions healthy based on absence of frame drops.
"""
import argparse
import datetime
import hashlib
import json
import pathlib
import statistics
import subprocess
import time
import threading
import os
import build_config
import local_signing

ROOT = pathlib.Path(__file__).resolve().parent.parent
EXECUTABLE = ROOT / 'DerivedData/Build/Products/Debug/Buffer.app/Contents/MacOS/Buffer'


def summarize(events, seconds):
    samples = [e for e in events if e.get('event') == 'sample']
    failures = []
    if any(e.get('event') == 'output-failure' or e.get('droppedRecords', 0) > 0
           or e.get('outputHealthy') is False for e in events):
        failures.append('diagnostic output lost records')
    if not events or events[0].get('event') != 'start': failures.append('missing start')
    if not events or events[-1].get('event') != 'end': failures.append('missing end')
    if len(samples) < max(1, seconds - 2): failures.append('insufficient samples')
    if samples and samples[-1]['elapsedMs'] < (seconds - 2) * 1000: failures.append('short observation')
    if events and events[-1].get('event') == 'end' and events[-1].get('reason') != 'duration':
        failures.append('observation ended early')
    by_slot = {}
    for sample in samples:
        for player in sample.get('players', []):
            by_slot.setdefault(player['slot'], []).append((sample, player))
    players = []
    for slot, observations in by_slot.items():
        frames = [p for _, p in observations if p['rendered']]
        active_frames = [p for p in frames if p.get('playbackRequested')]
        generations = {}
        for _, player in observations:
            totals = generations.setdefault(player['generation'], {'frameDrops': 0, 'decoderDrops': 0})
            for key in totals: totals[key] = max(totals[key], player[key])
        stalled = 0
        frozen = 0
        for (a, pa), (b, pb) in zip(observations, observations[1:]):
            if (pa['generation'] == pb['generation'] and pa['rendered']
                    and pa.get('playbackRequested') and pb.get('playbackRequested')
                    and pb['time'] - pa['time'] < .05):
                stalled += (b['elapsedMs'] - a['elapsedMs']) / 1000
            if (pa['generation'] == pb['generation'] and pa['rendered']
                    and pa.get('playbackRequested') and pb.get('playbackRequested')
                    and pa.get('windowVisible') and pb.get('windowVisible')
                    and pa.get('renderedFrameCount') is not None and pb.get('renderedFrameCount') is not None
                    and pb['renderedFrameCount'] <= pa['renderedFrameCount']):
                frozen += (b['elapsedMs'] - a['elapsedMs']) / 1000
        sync = [abs(p['avSyncSeconds']) for p in active_frames if p.get('avSyncSeconds') is not None]
        players.append(dict(slot=slot, samples=len(observations), renderedSamples=len(frames),
            generations=len(generations), sampledStalledSeconds=stalled,
            visibleSamples=sum(bool(p.get('windowVisible')) for _, p in observations),
            sampledRendererFrozenSeconds=frozen if frames and all('renderedFrameCount' in p for p in frames) else None,
            frameDrops=sum(g['frameDrops'] for g in generations.values()),
            decoderDrops=sum(g['decoderDrops'] for g in generations.values()),
            maxAVSyncSeconds=max(sync, default=None),
            audioOutputs=sorted({p['audioOutput'] for p in active_frames if p.get('audioOutput')}),
            startupMs=[p['startupMs'] for p in frames if p.get('startupMs') is not None][:1],
            recoveryReloads=max((p['recoveryReloads'] for _, p in observations), default=0)))
    footprint = [e['physicalFootprintBytes'] / 1024**2 for e in samples if 'physicalFootprintBytes' in e]
    return dict(evidenceComplete=not failures, failures=failures, samples=len(samples), players=players,
        maxTickGapMs=max((e['tickGapMs'] for e in samples), default=None),
        peakPhysicalFootprintMiB=max(footprint, default=None),
        medianPhysicalFootprintMiB=statistics.median(footprint) if footprint else None,
        limitations=['Sampled stalls exclude user-paused intervals; generation changes can hide short stalls',
                     'Readiness and progressing media time do not prove every on-screen frame or physical audibility',
                     'Observation is diagnostic, not a playback health gate or a provider-to-provider benchmark'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seconds', type=int, default=60)
    parser.add_argument('--ao', choices=['avfoundation', 'coreaudio'])
    parser.add_argument('--configuration', choices=['debug', 'optimized'], default='debug')
    args = parser.parse_args()
    if not 5 <= args.seconds <= 3600: parser.error('seconds must be 5..3600')
    selected_executable = EXECUTABLE if args.configuration == 'debug' else build_config.executable_path(args.configuration)
    if not selected_executable.exists(): parser.error('build first with scripts/bench.sh')
    try:
        local_signing.verify_normal_app(selected_executable.parents[2])
    except local_signing.SigningError as error:
        parser.error(str(error))
    metadata = build_config.read_binary_metadata(selected_executable, args.configuration)
    existing = subprocess.run(['pgrep', '-x', 'Buffer'], capture_output=True, text=True)
    if existing.stdout.strip(): parser.error('quit existing Buffer instances first to avoid duplicate provider sessions')
    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
    folder = ROOT / '.logs' / f'session-{stamp}'
    folder.mkdir(parents=True)
    snapshot = folder / 'samples.jsonl'
    fifo = folder / 'events.pipe'
    os.mkfifo(fifo, 0o600)
    command = ['open', '-g', '-n', str(selected_executable.parents[2]), '--stdout', str(fifo),
               '--stderr', '/dev/null', '--args', '--observe-session',
               '--observe-session-seconds', str(args.seconds)]
    if args.ao: command.extend(['--observe-session-ao', args.ao])
    # Only persist the tagged numeric records. Discard third-party stdout and
    # stderr rather than saving logs which may contain authenticated URLs.
    fingerprint = build_config.artifact_fingerprint(selected_executable)
    binary_hash = fingerprint['sha256']
    completed = threading.Event()
    started_at = [None]
    records = []
    def read_snapshots():
        with fifo.open(errors='replace') as incoming, snapshot.open('w') as saved:
            for line in incoming:
                if not line.startswith('BUFFER_SESSION_JSON '): continue
                try: event = json.loads(line.removeprefix('BUFFER_SESSION_JSON '))
                except json.JSONDecodeError: continue
                records.append(event)
                if event.get('event') == 'start' and started_at[0] is None:
                    started_at[0] = time.monotonic()
                saved.write(json.dumps(event, separators=(',', ':')) + '\n')
                saved.flush()
                if event.get('event') == 'end': completed.set()
    reader = threading.Thread(target=read_snapshots, daemon=True)
    reader.start()
    launched_at = time.monotonic()
    subprocess.run(command, check=True, timeout=15)
    pid = None
    for _ in range(100):
        rows = subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True).splitlines()
        found = [int(parts[0]) for row in rows if len(parts := row.strip().split(None, 1)) == 2
                 and pathlib.Path(parts[1]).resolve() == selected_executable]
        if len(found) == 1:
            pid = found[0]
            break
        time.sleep(.1)
    if pid is None: raise RuntimeError('LaunchServices did not start exactly one local Buffer')
    def is_alive():
        result = subprocess.run(['ps', '-p', str(pid), '-o', 'comm='], capture_output=True, text=True)
        return result.returncode == 0 and pathlib.Path(result.stdout.strip()).resolve() == selected_executable
    print(f'Normal app launched pid={pid}. Select one channel in its UI. Recording {args.seconds}s.', flush=True)
    resources = []
    # Window/bootstrap time is measured separately from the requested capture
    # duration. A slow launch must not silently truncate observation samples.
    while is_alive():
        deadline = (started_at[0] + args.seconds + 10) if started_at[0] is not None else (launched_at + 60)
        if time.monotonic() >= deadline: break
        result = subprocess.run(['ps', '-p', str(pid), '-o', '%cpu=,rss='], capture_output=True, text=True)
        fields = result.stdout.split()
        if len(fields) == 2:
            resources.append(dict(wallTime=time.time(), cpuPercent=float(fields[0]), rssKiB=int(fields[1])))
        if completed.is_set(): break
        time.sleep(1)
    events = []
    if snapshot.exists():
        for line in snapshot.read_text().splitlines():
            try: events.append(json.loads(line))
            except json.JSONDecodeError: pass  # A trailing partial record cannot prove completion.
    report = summarize(events, args.seconds)
    report.update(schema=2, scenario=dict(seconds=args.seconds, audioOverride=args.ao, configuration=args.configuration),
        buildMetadata=metadata, artifactFingerprint=fingerprint,
        binarySHA256=binary_hash,
        launchToObservationMs=(started_at[0] - launched_at) * 1000 if started_at[0] is not None else None,
        resources=resources, medianCPUPercent=statistics.median([r['cpuPercent'] for r in resources]) if resources else None,
        peakRSSMiB=max((r['rssKiB'] / 1024 for r in resources), default=None),
        processStillRunning=is_alive(), pid=pid, recordedAt=datetime.datetime.now(datetime.timezone.utc).isoformat())
    report['limitations'].append('LaunchServices child exit code is unavailable; missing end/sample evidence fails closed')
    if not reader.is_alive(): fifo.unlink(missing_ok=True)
    (folder / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({k: v for k, v in report.items() if k != 'resources'}, indent=2))
    print(f'Artifacts: {folder.relative_to(ROOT)}. App remains open if still running.')
    return 0 if report['evidenceComplete'] else 2


if __name__ == '__main__': raise SystemExit(main())

#!/usr/bin/env python3
"""Sequential saved-source playback evidence, with tagged numeric output only."""
import argparse
import base64
import datetime
import json
import math
import pathlib
import statistics
import subprocess
import threading
import time
import os
import uuid

import build_config
import local_signing
from playback import score, startup_reserve_confirmed, startup_target_confirmed, live_analysis_confirmed

ROOT = pathlib.Path(__file__).resolve().parent.parent
PLAN_KEYS = {'schema', 'caseSeconds', 'sourceTimeoutSeconds', 'cases'}
CASE_KEYS = {'sourceName', 'sourceID', 'channelName', 'channelID', 'expectedWidth', 'expectedHeight', 'expectedFPS',
             'playbackMode', 'catchupOffsetMinutes', 'vodName', 'vodID', 'vodResumeSeconds'}
EVENT_KEYS = {'event', 'schema', 'cases', 'caseSeconds', 'pid', 'buildMetadata', 'case', 'seconds', 'reason',
    'completedCases', 'restored', 'teardownConfirmed', 'cancelled', 'backendIdle', 'captured',
    'elapsedMs', 'tickGapMs', 'generation', 'windowVisible', 'applicationActive', 'time', 'cache', 'rendered',
    'windowOnActiveSpace', 'windowMiniaturized', 'windowLevel', 'applicationHidden', 'windowKey', 'windowMain',
    'renderedFrameCount', 'secondsSinceLastRender', 'playbackRequested', 'playing', 'pause', 'pausedForCache',
    'loading', 'buffering', 'bufferingMs', 'frameDrops', 'decoderDrops', 'mistimed', 'delayed', 'cacheFloorPauses',
    'startupMs', 'recoveryReloads', 'playlistFails', 'http509', 'width', 'height', 'fps', 'hwdec', 'videoCodec',
    'audioCodec', 'audioChannels', 'audioOutput', 'avSyncSeconds', 'muted', 'volume', 'configuredBufferSeconds',
    'physicalFootprintBytes', 'playbackMode', 'catchupRequested', 'catchupProgrammeStartUnixSeconds',
    'catchupProgrammeEndUnixSeconds', 'catchupLoadedStartUnixSeconds',
    'vodRequested', 'isSeekable', 'duration', 'vodResumeSeconds', 'archiveTimestampRecoveryEnabled', 'renderTimingNoBlock', 'startupReserveEnabled', 'exactCacheSeconds',
    'cachePauseInitial', 'cachePauseWaitSeconds',
    'startupTargetEnabled', 'startupHoldActive', 'startupHoldReleasedAtMs', 'startupHoldReleaseCacheSeconds',
    'nativeCacheOnlyEnabled',
    'rawTimePos', 'rawTimePosAgeMs', 'videoPTS', 'videoPTSAgeMs',
    'liveAnalysisEnabled', 'liveAnalysisRequestedSeconds', 'lavfAnalyzeDurationSeconds', 'lavfProbeSize',
    'lavfProbeInfo', 'audioSampleRate', 'startupPhaseTimingsMs',
    'droppedRecords', 'writtenRecords', 'producedRecords', 'outputHealthy'}
PRESET_CASES = [
    dict(sourceName='Odyssey', channelName='MLB Network', expectedWidth=1280, expectedHeight=720, expectedFPS=60),
    dict(sourceName='Odyssey', channelName='Sky Sports Tennis SD', expectedWidth=720, expectedHeight=576, expectedFPS=25),
    dict(sourceName='Odyssey', channelName='Sky Sports Tennis', expectedWidth=1920, expectedHeight=1080, expectedFPS=50),
    dict(sourceName='Odyssey', channelName='Sky Sports Main Event UHD', expectedWidth=3840, expectedHeight=2160, expectedFPS=50),
    dict(sourceName='Infinity', channelName='AU: Fox Sports News', expectedWidth=1280, expectedHeight=720, expectedFPS=50),
]
FAST_PRESET_CASES = [
    *PRESET_CASES[:4],
    dict(sourceName='Odyssey', channelName='TSN 4K UHD (HDR)', expectedWidth=3840, expectedHeight=2160, expectedFPS=60),
    dict(sourceName='Odyssey', channelName='Sky Sports Tennis', playbackMode='catchup', catchupOffsetMinutes=120),
    PRESET_CASES[4],
]
PRESETS = {
    'sports-mix': dict(cases=PRESET_CASES),
    'sports-mix-fast': dict(caseSeconds=25, sourceTimeoutSeconds=60, cases=FAST_PRESET_CASES),
}


def validate_plan(raw):
    if not isinstance(raw, dict) or not set(raw).issubset(PLAN_KEYS): raise ValueError('unknown plan fields')
    plan = dict(schema=1, caseSeconds=45, sourceTimeoutSeconds=180) | raw
    if raw.get('schema', 1) != 1: raise ValueError('unsupported plan schema')
    for field, bounds in [('caseSeconds', (20, 60)), ('sourceTimeoutSeconds', (15, 300))]:
        if type(plan[field]) is not int or not bounds[0] <= plan[field] <= bounds[1]: raise ValueError(f'invalid {field}')
    cases = plan.get('cases')
    if not isinstance(cases, list) or not 1 <= len(cases) <= 20: raise ValueError('cases must contain 1..20 entries')
    normalized = []
    for case in cases:
        if not isinstance(case, dict) or not set(case).issubset(CASE_KEYS): raise ValueError('unknown case fields')
        case = {key: value for key, value in case.items() if value is not None}
        mode = case.get('playbackMode', 'live')
        if mode not in ('live', 'catchup', 'vod'): raise ValueError('playbackMode must be live, catchup or vod')
        selectors = ('vodName', 'vodID') if mode == 'vod' else ('channelName', 'channelID')
        forbidden = ('channelName', 'channelID') if mode == 'vod' else ('vodName', 'vodID')
        for pair in [('sourceName', 'sourceID'), selectors]:
            if sum(key in case for key in pair) != 1: raise ValueError('one source and one content selector required')
        if any(key in case for key in forbidden): raise ValueError('content selectors must match playbackMode')
        for field in ['sourceName', 'sourceID', 'channelName', 'channelID', 'vodName', 'vodID']:
            if field in case:
                value = case[field]
                if (not isinstance(value, str) or not 1 <= len(value) <= 200 or '://' in value
                        or any(ord(char) < 32 or ord(char) == 127 for char in value)):
                    raise ValueError('selectors must be non-secret names or IDs; URLs are forbidden')
        if 'sourceID' in case:
            try: case['sourceID'] = str(uuid.UUID(case['sourceID']))
            except (ValueError, AttributeError): raise ValueError('sourceID must be a UUID') from None
        if ('expectedWidth' in case) != ('expectedHeight' in case): raise ValueError('width and height must be supplied together')
        for field in ['expectedWidth', 'expectedHeight']:
            if field in case and (type(case[field]) is not int or not 1 <= case[field] <= 16384): raise ValueError('invalid resolution')
        if 'expectedFPS' in case and (type(case['expectedFPS']) not in (int, float) or not math.isfinite(case['expectedFPS'])
                or not 0 < case['expectedFPS'] <= 240): raise ValueError('invalid expected FPS')
        if 'catchupOffsetMinutes' in case and (mode != 'catchup' or type(case['catchupOffsetMinutes']) is not int or
                not 1 <= case['catchupOffsetMinutes'] <= 43200): raise ValueError('invalid catchup offset')
        if 'vodResumeSeconds' in case and (mode != 'vod' or type(case['vodResumeSeconds']) not in (int, float) or
                not math.isfinite(case['vodResumeSeconds']) or not 0 < case['vodResumeSeconds'] <= 86400):
            raise ValueError('invalid VOD resume position')
        if mode == 'catchup' and 'catchupOffsetMinutes' not in case: case['catchupOffsetMinutes'] = 60
        case['playbackMode'] = mode
        normalized.append(case)
    plan['cases'] = normalized
    return plan


def summarize_case(events, item, seconds, max_drops=5, max_stall=3, max_avsync=.15):
    samples = [event for event in events if event.get('event') == 'sample']
    failures = []
    for marker in ['case-start', 'case-prepared', 'case-closed', 'case-end']:
        if len([event for event in events if event.get('event') == marker]) != 1: failures.append(f'missing or duplicate {marker}')
    end = next((event for event in events if event.get('event') == 'case-end'), {})
    if end.get('captured') is not True: failures.append('case did not capture requested duration')
    if end.get('reason'): failures.append(end['reason'])
    if end.get('teardownConfirmed') is not True: failures.append('backend teardown unconfirmed')
    closed = next((event for event in events if event.get('event') == 'case-closed'), {})
    if closed.get('backendIdle') is not True: failures.append('backend idle acknowledgment missing')
    required = {'elapsedMs', 'generation', 'time', 'width', 'height', 'rendered', 'frameDrops', 'decoderDrops',
                'mistimed', 'delayed', 'renderedFrameCount', 'windowVisible', 'bufferingMs', 'playbackRequested'}
    if any(not required.issubset(sample) for sample in samples):
        return dict(passed=False, failures=failures + ['incomplete playback samples'], samples=len(samples))
    boolean_fields = {'rendered', 'windowVisible', 'playbackRequested'}
    numeric_fields = required - boolean_fields
    if any(type(sample[field]) is not bool for sample in samples for field in boolean_fields) or any(
            type(sample[field]) not in (int, float) or not math.isfinite(sample[field]) or sample[field] < 0
            for sample in samples for field in numeric_fields):
        return dict(passed=False, failures=failures + ['invalid playback sample values'], samples=len(samples))
    if not any(sample['playbackRequested'] for sample in samples):
        failures.append('playback was never requested after opening')
    if any(b['elapsedMs'] <= a['elapsedMs'] for a, b in zip(samples, samples[1:])):
        return dict(passed=False, failures=failures + ['unordered playback samples'], samples=len(samples))
    playback = score([dict(event='start'), *samples, dict(event='end')], seconds,
                     max_drops=max_drops, max_stall=max_stall, require_render_activity=True, require_buffering_metrics=True)
    failures.extend(playback['failures'])
    rendered = [sample for sample in samples if sample.get('rendered')]
    if not rendered or any(not isinstance(sample.get('fps'), (int, float)) or sample['fps'] <= 0 for sample in rendered):
        failures.append('missing coded frame-rate telemetry')
    if not rendered or any(not sample.get('audioOutput') or not sample.get('audioCodec') or
                           type(sample.get('audioChannels')) is not int or sample['audioChannels'] <= 0
                           for sample in rendered): failures.append('missing decoded-audio/output telemetry')
    if rendered and any(sample.get('muted') is not False or type(sample.get('volume')) not in (int, float) or
                        sample['volume'] <= 0 for sample in rendered):
        failures.append('audio was muted or volume evidence missing')
    sync = [abs(sample['avSyncSeconds']) for sample in rendered if type(sample.get('avSyncSeconds')) in (int, float)
            and math.isfinite(sample['avSyncSeconds'])]
    if len(sync) != len(rendered) or not sync: failures.append('missing AV-sync telemetry')
    if sync and max(sync) > max_avsync: failures.append('AV-sync budget exceeded')
    mode = item.get('playbackMode', 'live')
    if not rendered or any(sample.get('playbackMode') != mode for sample in rendered):
        failures.append('actual playback intent differs from requested case')
    if mode == 'catchup':
        fields = ['catchupProgrammeStartUnixSeconds', 'catchupProgrammeEndUnixSeconds', 'catchupLoadedStartUnixSeconds']
        if not rendered or any(sample.get('catchupRequested') is not True or any(
                type(sample.get(field)) not in (int, float) or not math.isfinite(sample[field]) or sample[field] <= 0
                for field in fields) for sample in rendered):
            failures.append('missing actual archived-programme evidence')
        elif any(sample['catchupProgrammeEndUnixSeconds'] <= sample['catchupProgrammeStartUnixSeconds'] or
                 abs(sample['catchupLoadedStartUnixSeconds'] - sample['catchupProgrammeStartUnixSeconds']) > 5 for sample in rendered):
            failures.append('archive load did not use the selected real programme')
    if mode == 'vod':
        if not rendered or any(sample.get('vodRequested') is not True or sample.get('isSeekable') is not True or
                type(sample.get('duration')) not in (int, float) or not math.isfinite(sample['duration']) or
                sample['duration'] <= 0 for sample in rendered):
            failures.append('missing actual seekable on-demand timeline evidence')
        if 'vodResumeSeconds' in item and (not rendered or any(
                sample.get('vodResumeSeconds') != item['vodResumeSeconds'] for sample in rendered) or
                not any(sample['time'] >= item['vodResumeSeconds'] - 5 for sample in rendered)):
            failures.append('on-demand resume did not reach requested position')
    if 'expectedWidth' in item and (not rendered or any(sample['width'] != item['expectedWidth'] or
            sample['height'] != item['expectedHeight'] for sample in rendered)):
        failures.append('coded resolution differs from expectation')
    if 'expectedFPS' in item and (not rendered or any(type(sample.get('fps')) not in (int, float) or
            abs(sample['fps'] - item['expectedFPS']) > .5 for sample in rendered)):
        failures.append('coded frame rate differs from expectation')
    resolutions = sorted({(sample['width'], sample['height']) for sample in rendered})
    rates = sorted({round(sample['fps'], 3) for sample in rendered if type(sample.get('fps')) in (int, float)})
    footprint = [sample['physicalFootprintBytes'] / 1024**2 for sample in samples if 'physicalFootprintBytes' in sample]
    return dict(playback, passed=not failures, failures=failures, selector=item, codedResolutions=resolutions,
        codedFrameRates=rates, audioOutputs=sorted({s['audioOutput'] for s in rendered if s.get('audioOutput')}),
        audioChannels=sorted({s['audioChannels'] for s in rendered if s.get('audioChannels')}), maxAVSyncSeconds=max(sync, default=None),
        minCacheSeconds=min((s['cache'] for s in rendered if type(s.get('cache')) in (int, float)), default=None),
        recoveryReloads=max((s.get('recoveryReloads', 0) for s in samples), default=0),
        http509=max((s.get('http509', 0) for s in samples), default=0),
        playlistFailures=max((s.get('playlistFails', 0) for s in samples), default=0),
        playbackMode=mode,
        onDemandDurations=sorted({s['duration'] for s in rendered if mode == 'vod' and type(s.get('duration')) in (int, float)}),
        archiveProgrammeStarts=sorted({s['catchupProgrammeStartUnixSeconds'] for s in rendered
                                     if type(s.get('catchupProgrammeStartUnixSeconds')) in (int, float)}),
        peakPhysicalFootprintMiB=max(footprint, default=None))


def summarize(events, plan, metadata, **budgets):
    failures = []
    if any(event.get('event') == 'output-failure' or event.get('droppedRecords', 0) > 0
           or event.get('outputHealthy') is False for event in events):
        failures.append('diagnostic output lost records')
    starts = [event for event in events if event.get('event') == 'start']
    ends = [event for event in events if event.get('event') == 'end']
    if (len(starts) != 1 or starts[0].get('buildMetadata') != metadata or
            starts[0].get('cases') != len(plan['cases']) or starts[0].get('caseSeconds') != plan['caseSeconds']):
        failures.append('missing or incompatible scenario start')
    if len(ends) != 1: failures.append('missing or duplicate scenario end')
    end = ends[-1] if ends else {}
    if end.get('completedCases') != len(plan['cases']): failures.append('case coverage incomplete')
    if end.get('restored') is not True: failures.append('original source/selection restoration unconfirmed')
    if end.get('teardownConfirmed') is not True: failures.append('scenario backend teardown unconfirmed')
    if end.get('cancelled'): failures.append('scenario cancelled')
    if any(event.get('event') == 'failure' for event in events): failures.append('scenario failed before case capture')
    if not events or events[0].get('event') != 'start' or events[-1].get('event') != 'end':
        failures.append('scenario envelope out of order')
    active_case = None
    prepared = False
    closed = False
    for event in events:
        kind = event.get('event')
        if kind == 'case-start':
            if active_case is not None: failures.append('cases overlapped before teardown')
            active_case, prepared, closed = event.get('case'), False, False
        elif kind in {'case-prepared', 'sample', 'case-closed', 'case-end'}:
            if event.get('case') != active_case or active_case is None: failures.append('case events out of order')
            if kind == 'case-prepared': prepared = True
            elif kind == 'sample' and (not prepared or closed): failures.append('samples outside owned capture interval')
            elif kind == 'case-closed': closed = True
            elif kind == 'case-end': active_case = None
    expected = set(range(len(plan['cases'])))
    if any(event.get('case') not in expected for event in events if 'case' in event): failures.append('unexpected case marker')
    cases = [summarize_case([event for event in events if event.get('case') == index], item,
                           plan['caseSeconds'], **budgets) for index, item in enumerate(plan['cases'])]
    return dict(schema=1, passed=not failures and all(case['passed'] for case in cases), failures=failures,
        cases=cases, plan=plan, buildMetadata=metadata, restored=end.get('restored') is True,
        limitations=['Decoded audio/output/AV-sync telemetry does not prove physical speaker audibility',
                     'Coded frame rate describes the stream; render counters confirm activity, not every presented frame',
                     'The owned diagnostic player floats during capture to reduce occlusion; no pin preference is saved',
                     'Provider cases are sequential real observations, not controlled provider-to-provider speed comparisons',
                     'Playback can update normal probe metadata and VOD progress; scenario bypasses library recents/usage hooks',
                     *(['VOD playback can update the normal resume record']
                       if any(case.get('playbackMode') == 'vod' for case in plan['cases']) else []),
                     'Restoration covers source and model selection/search; view-local transient state is not serialized',
                     *(['Short captures validate startup and immediate playback; sustained playback requires a longer run']
                       if plan['caseSeconds'] < 45 else [])])


def sanitize_event(raw):
    if not isinstance(raw, dict) or raw.get('event') not in {'start', 'end', 'failure', 'output-failure', 'case-start', 'case-prepared', 'case-closed', 'case-end', 'sample'}:
        raise ValueError('unsupported scenario record')
    clean = {key: value for key, value in raw.items() if key in EVENT_KEYS}
    for key, value in clean.items():
        if key == 'buildMetadata':
            if not isinstance(value, dict): raise ValueError('invalid metadata')
            profile = next((name for name, data in build_config.CONFIGURATIONS.items() if data['label'] == value.get('configuration')), None)
            if profile is None: raise ValueError('unsupported metadata')
            clean[key] = build_config.validate_metadata(value, profile)
        elif key == 'startupPhaseTimingsMs':
            allowed = {'loadStarted', 'redirectStarted', 'redirectCompleted', 'loadSubmitted',
                       'startFile', 'fileLoaded', 'firstRender'}
            if (not isinstance(value, dict) or not set(value).issubset(allowed)
                    or any(type(item) not in (int, float) or not math.isfinite(item) or item < 0
                           for item in value.values())):
                raise ValueError('unsafe phase telemetry')
        elif isinstance(value, float) and not math.isfinite(value): raise ValueError('non-finite numeric telemetry')
        elif isinstance(value, str):
            if len(value) > 200 or '://' in value or any(char not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-,./ ()' for char in value):
                raise ValueError('unsafe textual telemetry')
        elif value is not None and type(value) not in (int, float, bool): raise ValueError('unsupported telemetry value')
    return clean


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--plan', type=pathlib.Path)
    source.add_argument('--preset', choices=list(PRESETS))
    parser.add_argument('--case-seconds', type=int, choices=range(20, 61))
    parser.add_argument('--configuration', choices=list(build_config.CONFIGURATIONS), default='debug')
    parser.add_argument('--ao', choices=['auto', 'avfoundation', 'coreaudio'], default='auto')
    parser.add_argument('--archive-timestamps', action='store_true', help='Opt-in archive timestamp recovery experiment')
    parser.add_argument('--render-no-block', action='store_true', help='Opt-in render timing experiment')
    parser.add_argument('--startup-reserve', action='store_true', help='Opt-in live startup reserve experiment')
    parser.add_argument('--startup-target', action='store_true', help='DEBUG trial: hold live playback until measured buffer target')
    parser.add_argument('--native-cache-only', action='store_true', help='DEBUG trial: native cache handling without the app floor')
    parser.add_argument('--live-analysis', type=int, choices=[1, 2], help='DEBUG trial: bounded known-format live stream analysis')
    parser.add_argument('--max-drops', type=int, default=5)
    parser.add_argument('--max-stall', type=float, default=3)
    parser.add_argument('--max-avsync', type=float, default=.15)
    args = parser.parse_args()
    if sum((args.startup_reserve, args.startup_target, args.native_cache_only)) > 1: parser.error('select one startup experiment')
    if args.max_drops < 0 or args.max_stall < 0 or args.max_avsync < 0: parser.error('budgets cannot be negative')
    raw = json.loads(args.plan.read_text()) if args.plan else dict(PRESETS[args.preset])
    if args.case_seconds is not None: raw['caseSeconds'] = args.case_seconds
    plan = validate_plan(raw)
    executable = build_config.executable_path(args.configuration)
    metadata = build_config.read_binary_metadata(executable, args.configuration)
    if not any(b'BUFFER_MATRIX_JSON ' in component.read_bytes() for component in build_config.code_component_paths(executable)):
        parser.error('build the saved-playback scenario hooks first')
    local_signing.verify_normal_app(executable.parents[2])
    existing = subprocess.run(['pgrep', '-x', 'Buffer'], capture_output=True, text=True)
    if existing.stdout.strip(): parser.error('quit existing Buffer instances to avoid unrelated provider sessions')
    fingerprint = build_config.artifact_fingerprint(executable)
    folder = ROOT / '.logs' / ('channel-matrix-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
    folder.mkdir(parents=True)
    fifo = folder / 'events.pipe'
    os.mkfifo(fifo, 0o600)
    records, record_errors, resources = [], [], []
    phase = {'case': None, 'capture': False}
    completed = threading.Event()
    def read_records():
        with fifo.open(errors='replace') as incoming, (folder / 'events.jsonl').open('w') as saved:
            for line in incoming:
                if not line.startswith('BUFFER_MATRIX_JSON '): continue
                try: event = sanitize_event(json.loads(line.removeprefix('BUFFER_MATRIX_JSON ')))
                except (ValueError, TypeError):
                    record_errors.append('invalid numeric scenario record')
                    continue
                records.append(event)
                if event.get('event') == 'case-start': phase.update(case=event.get('case'), capture=False)
                if event.get('event') == 'sample': phase['capture'] = True
                if event.get('event') in {'case-closed', 'case-end'}: phase['capture'] = False
                if event.get('event') == 'case-end': phase['case'] = None
                saved.write(json.dumps(event, separators=(',', ':')) + '\n')
                saved.flush()
                if event.get('event') == 'end': completed.set()
    reader = threading.Thread(target=read_records, daemon=True)
    reader.start()
    encoded = base64.b64encode(json.dumps(plan, separators=(',', ':')).encode()).decode()
    # Passing non-secret JSON through inherited arguments avoids sandbox file
    # access or a file panel. No sandbox entitlements or credentials change.
    command = ['open', '-g', '-n', str(executable.parents[2]), '--stdout', str(fifo), '--stderr', '/dev/null',
               '--args', '--saved-playback-scenario', encoded]
    # Select the process-local experiment without --observe-session: that
    # recorder has its own fixed duration and stdout ownership.
    if args.ao != 'auto': command.extend(['--observe-session-ao', args.ao])
    if args.archive_timestamps: command.append('--validate-archive-timestamps')
    if args.render_no_block: command.append('--validate-render-no-block')
    if args.startup_reserve: command.append('--validate-startup-reserve')
    if args.startup_target: command.append('--validate-startup-target')
    if args.native_cache_only: command.append('--validate-native-cache-only')
    if args.live_analysis: command.append(f'--validate-live-analysis={args.live_analysis}')
    subprocess.run(command, check=True, timeout=15)
    deadline = time.monotonic() + len(plan['cases']) * (plan['sourceTimeoutSeconds'] + plan['caseSeconds'] + 35) + plan['sourceTimeoutSeconds'] + 60
    pid = None
    launched_at = time.monotonic()
    while not completed.is_set() and time.monotonic() < deadline:
        if pid is None:
            rows = subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True).splitlines()
            found = [int(parts[0]) for row in rows if len(parts := row.strip().split(None, 1)) == 2
                     and pathlib.Path(parts[1]).resolve() == executable]
            if len(found) == 1: pid = found[0]
        if pid is not None:
            result = subprocess.run(['ps', '-p', str(pid), '-o', '%cpu=,rss='], capture_output=True, text=True)
            values = result.stdout.split()
            if len(values) == 2:
                resources.append(dict(wallTime=time.time(), cpuPercent=float(values[0]), rssKiB=int(values[1]), **phase))
            else: break
        if not records and time.monotonic() - launched_at > plan['sourceTimeoutSeconds'] + 30: break
        time.sleep(1)
    report = summarize(records, plan, metadata, max_drops=args.max_drops, max_stall=args.max_stall, max_avsync=args.max_avsync)
    if record_errors: report['failures'].extend(sorted(set(record_errors))); report['passed'] = False
    if build_config.artifact_fingerprint(executable) != fingerprint:
        report['failures'].append('app artifact changed during scenario'); report['passed'] = False
    for index, case in enumerate(report['cases']):
        if args.startup_reserve and plan['cases'][index].get('playbackMode', 'live') == 'live':
            rendered = [event for event in records if event.get('case') == index and event.get('event') == 'sample' and event.get('rendered')]
            if not startup_reserve_confirmed(rendered):
                case['failures'].append('startup reserve experiment lacked actual mpv setting confirmation')
                case['passed'] = False
                report['passed'] = False
        if args.startup_target and plan['cases'][index].get('playbackMode', 'live') == 'live':
            rendered = [event for event in records if event.get('case') == index and event.get('event') == 'sample' and event.get('rendered')]
            target = max((sample.get('configuredBufferSeconds', 0) for sample in rendered), default=0)
            if target <= 0 or not startup_target_confirmed(rendered, target):
                case['failures'].append('startup target experiment lacked measured buffer release')
                case['passed'] = False
                report['passed'] = False
        if args.native_cache_only and plan['cases'][index].get('playbackMode', 'live') == 'live':
            rendered = [event for event in records if event.get('case') == index and event.get('event') == 'sample' and event.get('rendered')]
            if not rendered or any(sample.get('nativeCacheOnlyEnabled') is not True
                    or sample.get('cacheFloorPauses') != 0 for sample in rendered):
                case['failures'].append('native cache-only experiment was not active')
                case['passed'] = False
                report['passed'] = False
        if args.live_analysis and plan['cases'][index].get('playbackMode', 'live') == 'live':
            rendered = [event for event in records if event.get('case') == index and event.get('event') == 'sample' and event.get('rendered')]
            if not live_analysis_confirmed(rendered, args.live_analysis):
                case['failures'].append('live analysis experiment lacked actual option/audio confirmation')
                case['passed'] = False
                report['passed'] = False
        if args.render_no_block:
            rendered = [event for event in records if event.get('case') == index
                        and event.get('event') == 'sample' and event.get('rendered')]
            if not rendered or any(event.get('renderTimingNoBlock') is not True for event in rendered):
                case['failures'].append('render timing experiment was not active')
                case['passed'] = False
                report['passed'] = False
        if args.archive_timestamps and plan['cases'][index].get('playbackMode') == 'catchup':
            rendered = [event for event in records if event.get('case') == index
                        and event.get('event') == 'sample' and event.get('rendered')]
            if not rendered or any(event.get('archiveTimestampRecoveryEnabled') is not True for event in rendered):
                case['failures'].append('archive timestamp experiment was not active')
                case['passed'] = False
                report['passed'] = False
        captured_resources = [resource for resource in resources if resource['case'] == index and resource['capture']]
        case['medianCPUPercent'] = statistics.median([r['cpuPercent'] for r in captured_resources]) if captured_resources else None
        case['peakRSSMiB'] = max((r['rssKiB'] / 1024 for r in captured_resources), default=None)
        if args.ao != 'auto' and case.get('audioOutputs') != [args.ao]:
            case['failures'].append('actual audio output differs from requested experiment'); case['passed'] = False; report['passed'] = False
    report.update(artifactFingerprint=fingerprint, binarySHA256=fingerprint['sha256'], pid=pid, resources=resources,
                  audioOutputOverride=None if args.ao == 'auto' else args.ao,
                  archiveTimestampRecoveryOverride=args.archive_timestamps,
                  renderTimingNoBlockOverride=args.render_no_block,
                  startupReserveOverride=args.startup_reserve,
                  startupTargetOverride=args.startup_target,
                  nativeCacheOnlyOverride=args.native_cache_only,
                  liveAnalysisOverride=args.live_analysis,
                  peakRSSMiB=max((item['rssKiB'] / 1024 for item in resources), default=None),
                  medianCPUPercent=statistics.median([item['cpuPercent'] for item in resources]) if resources else None,
                  recordedAt=datetime.datetime.now(datetime.timezone.utc).isoformat())
    (folder / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    if not reader.is_alive(): fifo.unlink(missing_ok=True)
    print(json.dumps({key: value for key, value in report.items() if key != 'resources'}, indent=2))
    print(f'Artifacts: {folder.relative_to(ROOT)}. App remains open if still running.')
    return 0 if report['passed'] else 2


if __name__ == '__main__':
    try: raise SystemExit(main())
    except (ValueError, OSError, subprocess.SubprocessError):
        # Do not print subprocess errors: their command text includes argv,
        # and future callers could accidentally put secret data in selectors.
        print('Channel matrix failed before complete evidence; inspect the numeric report if created.')
        raise SystemExit(1)

#!/usr/bin/env python3
"""Real-renderer HLS validation, deterministic time-based faults, owned processes only."""
import argparse
import bisect
import datetime
from fractions import Fraction
import functools
import hashlib
import http.server
import importlib.util
import json
import math
import pathlib
import os
import shlex
import shutil
import statistics
import subprocess
import sys
import threading
import time
import build_config

ROOT = pathlib.Path(__file__).resolve().parent.parent


def start_local_transport_proxy(origin):
    """Load the explicit, loopback-only transport experiment on demand."""
    name = 'buffer_local_hls_retry_proxy'
    module = sys.modules.get(name)
    if module is None:
        spec = importlib.util.spec_from_file_location(name, ROOT / 'benchmarks/hls_retry_proxy.py')
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        spec.loader.exec_module(module)
    return module.LocalHLSProxy(origin)

# The Main10 corpus is SDR BT.709. Ten-bit storage alone does not establish HDR
# content, mastering metadata or correct HDR presentation.
PROFILES = {
    '720p30': dict(width=1280, height=720, fps='30', bitrate='3000k', codec='h264', bits=8),
    '1080p60': dict(width=1920, height=1080, fps='60', bitrate='8000k', codec='h264', bits=8),
    '2160p50-hevc10': dict(width=3840, height=2160, fps='50', bitrate='18000k', codec='hevc', bits=10),
    '2160p5994-hevc10': dict(width=3840, height=2160, fps='60000/1001', bitrate='22000k', codec='hevc', bits=10),
}
FAULTS = ('none', 'stall', '502', '503', '401', '403', '404', '429', '509', 'offline')
HEVC_SDR_METADATA = ('hevc_metadata=colour_primaries=1:transfer_characteristics=1:'
                     'matrix_coefficients=1:video_full_range_flag=0')


def fixture_command(profile, seconds, fixture):
    spec = PROFILES[profile]
    size = f"{spec['width']}x{spec['height']}"
    command = ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
               '-f', 'lavfi', '-i', f"testsrc2=size={size}:rate={spec['fps']}",
               '-f', 'lavfi', '-i', 'anullsrc=r=48000:cl=stereo', '-t', str(seconds)]
    if spec['codec'] == 'hevc':
        command += ['-c:v', 'hevc_videotoolbox', '-profile:v', 'main10',
                    '-allow_sw', '0', '-pix_fmt', 'p010le', '-prio_speed', '1',
                    '-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709',
                    # VideoToolbox can omit primaries/transfer from its HEVC
                    # SPS despite the encoder options. Write the SDR VUI into
                    # the bitstream itself, then verify the actual TS stream.
                    '-bsf:v', HEVC_SDR_METADATA]
    else:
        command += ['-c:v', 'libx264', '-preset', 'ultrafast', '-threads', '2',
                    '-pix_fmt', 'yuv420p', '-sc_threshold', '0']
    command += ['-g', str(round(float(Fraction(spec['fps'])) * 2)), '-b:v', spec['bitrate'],
                '-c:a', 'aac', '-b:a', '64k', '-f', 'hls', '-hls_time', '2',
                '-hls_playlist_type', 'vod', '-hls_segment_filename',
                str(fixture / 'segment-%03d.ts'), str(fixture / 'stream.m3u8')]
    return command


def read_segments(playlist):
    segments = []
    duration_line = None
    for line in playlist.read_text().splitlines():
        if line.startswith('#EXTINF:'):
            duration = float(line.split(':', 1)[1].split(',', 1)[0])
            if not math.isfinite(duration) or duration <= 0:
                raise ValueError('invalid HLS segment duration')
            duration_line = line
        elif line.endswith('.ts') and duration_line:
            # Fixtures are generated locally; reject unexpected paths even if a
            # stale cache was replaced, instead of hashing/serving another file.
            if pathlib.Path(line).name != line:
                raise ValueError('non-local HLS segment path')
            segments.append((duration_line, line))
            duration_line = None
    return segments


def segment_timeline(segments):
    ends = []
    total = 0.0
    for duration_line, _ in segments:
        total += float(duration_line.split(':', 1)[1].split(',', 1)[0])
        ends.append(total)
    return ends


def rolling_playlist(segments, ends, elapsed, origin_wall):
    # Only completed media is advertised. Fractional-frame-rate GOPs can be
    # 2.002 seconds long, so index * 2 is not the media timeline.
    last = bisect.bisect_right(ends, 20 + elapsed)
    first = max(0, last - 12)
    target = max(1, math.ceil(max((float(line.split(':', 1)[1].split(',', 1)[0])
                                 for line, _ in segments), default=2)))
    lines = ['#EXTM3U', '#EXT-X-VERSION:3', f'#EXT-X-TARGETDURATION:{target}',
             f'#EXT-X-MEDIA-SEQUENCE:{first}']
    for index in range(first, last):
        start = ends[index - 1] if index else 0
        date = datetime.datetime.fromtimestamp(origin_wall + start, datetime.timezone.utc)
        lines.append('#EXT-X-PROGRAM-DATE-TIME:' + date.isoformat(timespec='milliseconds'))
        lines.extend(segments[index])
    return ('\n'.join(lines) + '\n').encode()


def validate_fixture_probe(profile, probe):
    spec = PROFILES[profile]
    video = next((stream for stream in probe.get('streams', []) if stream.get('codec_type') == 'video'), None)
    audio = next((stream for stream in probe.get('streams', []) if stream.get('codec_type') == 'audio'), None)
    if video is None or audio is None:
        raise ValueError('fixture is missing video or audio')
    if (video.get('codec_name'), video.get('width'), video.get('height')) != (spec['codec'], spec['width'], spec['height']):
        raise ValueError('fixture video codec/dimensions do not match profile')
    try:
        fps = Fraction(video.get('avg_frame_rate', '0/0'))
    except (ValueError, ZeroDivisionError):
        fps = Fraction(0)
    if not fps:
        fps = Fraction(video.get('r_frame_rate', '0/0'))
    if abs(float(fps - Fraction(spec['fps']))) > .01:
        raise ValueError('fixture frame rate does not match profile')
    expected_pixels = {'yuv420p10le', 'p010le'} if spec['bits'] == 10 else {'yuv420p', 'yuvj420p'}
    if video.get('pix_fmt') not in expected_pixels:
        raise ValueError('fixture pixel depth does not match profile')
    if spec['bits'] == 10 and any(video.get(field) != 'bt709' for field in ('color_space', 'color_transfer', 'color_primaries')):
        raise ValueError('Main10 fixture does not have the intended SDR BT.709 signaling')
    if audio.get('codec_name') != 'aac' or audio.get('channels') != 2 or str(audio.get('sample_rate')) != '48000':
        raise ValueError('fixture audio format does not match profile')
    return dict(video=video, audio=audio, expected=spec, content='synthetic SDR test pattern',
                physicalAudioQualification=False)


def prepare_fixture(profile, seconds, out):
    duration = seconds + 40
    # Keep existing H.264 fixture names to reuse the same comparison corpus.
    fixture = ROOT / '.local' / f'hls-{profile}-{duration}'
    fixture.mkdir(parents=True, exist_ok=True)
    playlist = fixture / 'stream.m3u8'
    command = fixture_command(profile, duration, fixture)
    generated = not playlist.exists()
    if generated:
        with (out / 'ffmpeg.log').open('w') as log:
            try:
                subprocess.run(command, stdout=log, stderr=log, check=True, timeout=180)
            except (subprocess.SubprocessError, OSError):
                # FFmpeg can leave a complete-looking manifest after a failed
                # encode. The next attempt must not mistake it for valid cache.
                playlist.unlink(missing_ok=True)
                raise
    segments = read_segments(playlist)
    ends = segment_timeline(segments)
    if not ends or ends[-1] < seconds + 30 or any(not (fixture / name).is_file() for _, name in segments):
        raise RuntimeError('Incomplete HLS fixture; regenerate it')
    probe_command = ['ffprobe', '-v', 'error', '-show_streams', '-of', 'json', str(fixture / segments[0][1])]
    probe = json.loads(subprocess.check_output(probe_command, text=True, timeout=30))
    metadata = validate_fixture_probe(profile, probe)
    digest = hashlib.sha256()
    for file in [playlist, *(fixture / name for _, name in segments)]:
        digest.update(file.name.encode())
        with file.open('rb') as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b''):
                digest.update(chunk)
    metadata.update(schema=1, profile=profile, generated=generated,
                    generationCommand=command if generated else None,
                    corpusSHA256=digest.hexdigest(), durationSeconds=ends[-1], segments=len(segments))
    (out / 'fixture.json').write_text(json.dumps(metadata, indent=2) + '\n')
    return fixture, segments, ends, metadata


def injected_status(fault):
    if fault in ('none', 'stall'):
        return None
    return 502 if fault == 'offline' else int(fault)


def startup_reserve_confirmed(rendered):
    """Require actual current-item mpv readback, not just requested flags."""
    if not rendered or any(sample.get('startupReserveEnabled') is not True for sample in rendered):
        return False
    complete = False
    for sample in rendered:
        initial, wait = sample.get('cachePauseInitial'), sample.get('cachePauseWaitSeconds')
        if initial is not None and initial is not True:
            return False
        if wait is not None and (type(wait) not in (int, float) or not math.isfinite(wait) or wait <= 0):
            return False
        complete |= initial is True and wait is not None
    return complete


def startup_target_confirmed(rendered, target_seconds):
    """A requested hold or a timeout is not evidence of a measured release."""
    if not rendered or any(sample.get('startupTargetEnabled') is not True for sample in rendered):
        return False
    return any(sample.get('startupHoldActive') is False
        and type(sample.get('startupHoldReleasedAtMs')) in (int, float)
        and math.isfinite(sample['startupHoldReleasedAtMs']) and sample['startupHoldReleasedAtMs'] >= 0
        and type(sample.get('startupHoldReleaseCacheSeconds')) in (int, float)
        and math.isfinite(sample['startupHoldReleaseCacheSeconds'])
        and sample['startupHoldReleaseCacheSeconds'] >= target_seconds
        for sample in rendered)


def live_analysis_confirmed(rendered, requested_seconds):
    if not rendered or any(sample.get('liveAnalysisEnabled') is not True
            or sample.get('liveAnalysisRequestedSeconds') != requested_seconds for sample in rendered):
        return False
    complete = False
    for sample in rendered:
        actual, size, info = (sample.get('lavfAnalyzeDurationSeconds'), sample.get('lavfProbeSize'),
                              sample.get('lavfProbeInfo'))
        if actual is not None and (type(actual) not in (int, float)
                or not math.isfinite(actual) or abs(actual - requested_seconds) > 0.001):
            return False
        if size is not None and (type(size) is not int or size != 2_097_152):
            return False
        if info is not None and info != 'auto':
            return False
        complete |= actual is not None and size is not None and info is not None
    return complete and all(type(sample.get('audioSampleRate')) is int and sample['audioSampleRate'] > 0
                            for sample in rendered)


def score(events, seconds, max_drops=5, max_stall=3, require_render_activity=False, require_buffering_metrics=False):
    failures = []
    if any(e.get('event') == 'output-failure' or e.get('droppedRecords', 0) > 0
           or e.get('outputHealthy') is False for e in events):
        failures.append('diagnostic output lost records')
    samples = [e for e in events if e.get('event') == 'sample']
    rendered = [s for s in samples if s['rendered'] and s['width'] > 0 and s['height'] > 0]
    if not events or events[0].get('event') != 'start': failures.append('missing start')
    if not events or events[-1].get('event') != 'end': failures.append('missing end')
    if len(samples) < seconds: failures.append('insufficient samples')
    if not rendered: failures.append('no rendered video')
    if samples and samples[-1]['elapsedMs'] < (seconds - 1) * 1000: failures.append('short capture')
    progress = 0
    stalled = 0
    rendered_readiness_lost = 0
    timestamp_discontinuities = 0
    excluded_clock_jump_seconds = 0
    max_gap = 0
    frozen_renderer = 0
    has_rendered = False
    raw_clock = any('rawTimePos' in sample for sample in samples)

    def ready(sample):
        return sample['rendered'] and sample['width'] > 0 and sample['height'] > 0

    def playback_clock(sample):
        if not raw_clock:
            return sample['time']
        value, age = sample.get('rawTimePos'), sample.get('rawTimePosAgeMs')
        valid = (type(value) in (int, float) and math.isfinite(value) and value >= 0
                 and type(age) in (int, float) and math.isfinite(age) and age >= 0)
        if not valid:
            if ready(sample) and 'missing raw playback clock telemetry' not in failures:
                failures.append('missing raw playback clock telemetry')
            return None
        held = (sample.get('pause') is True or sample.get('pausedForCache') is True
                or sample.get('startupHoldActive') is True or sample.get('playbackRequested') is False)
        if ready(sample) and not held and age > 1000 and 'stale raw playback clock telemetry' not in failures:
            failures.append('stale raw playback clock telemetry')
        return value

    clocks = [playback_clock(sample) for sample in samples]
    for index, (a, b) in enumerate(zip(samples, samples[1:])):
        dt = (b['elapsedMs'] - a['elapsedMs']) / 1000
        max_gap = max(max_gap, dt)
        has_rendered = has_rendered or ready(a)
        requested = a.get('playbackRequested', True) and b.get('playbackRequested', True)
        if dt <= 0 or not math.isfinite(dt):
            failures.append('invalid sample clock telemetry')
            continue
        # Hold the sampled readiness state over the following interval. Initial
        # startup and a deliberate user pause are not playback interruptions;
        # readiness lost after the first frame, including reloads, is one.
        if has_rendered and requested and not ready(a):
            rendered_readiness_lost += dt
        if a['generation'] != b['generation']: continue
        if not requested: continue
        if clocks[index] is None or clocks[index + 1] is None:
            continue
        advance = clocks[index + 1] - clocks[index]
        if not math.isfinite(advance):
            failures.append('invalid playback clock telemetry')
            continue
        # These scenarios run at 1x. Allow ordinary sample/PTS jitter, but a
        # seek or discontinuous transport clock is not rendered play time.
        # A controlled capture with such a jump must fail rather than using
        # the jump to satisfy the progress gate.
        tolerance = max(.25, dt * .25)
        discontinuity = ready(a) and ready(b) and (advance > dt + tolerance or advance < -tolerance)
        if discontinuity:
            timestamp_discontinuities += 1
            excluded_clock_jump_seconds += abs(advance)
        elif ready(a) and ready(b):
            progress += max(0, advance)
        if ready(a) and not discontinuity and advance < .05:
            stalled += dt
        if (ready(a)
                and a.get('renderedFrameCount') is not None and b.get('renderedFrameCount') is not None
                and b['renderedFrameCount'] <= a['renderedFrameCount']):
            frozen_renderer += dt
    # Sum per-load maxima, not a final counter that can reset after recovery.
    totals = {}
    for name in ('frameDrops', 'decoderDrops', 'mistimed', 'delayed'):
        by_generation = {}
        for sample in samples:
            generation = sample['generation']
            by_generation[generation] = max(by_generation.get(generation, 0), sample[name])
        totals[name] = sum(by_generation.values())
    buffering_by_generation = {}
    for sample in samples:
        if sample.get('bufferingMs') is not None:
            generation = sample['generation']
            buffering_by_generation[generation] = max(buffering_by_generation.get(generation, 0), sample['bufferingMs'])
    reported_buffering = sum(buffering_by_generation.values()) / 1000 if buffering_by_generation else None
    startup = rendered[0]['elapsedMs'] if rendered else None
    if startup is not None and startup > 15000: failures.append('startup over 15 seconds')
    if progress < seconds * .4: failures.append('insufficient playback progress')
    if timestamp_discontinuities: failures.append('playback clock discontinuity')
    if totals.get('frameDrops', 0) + totals.get('decoderDrops', 0) > max_drops: failures.append('frame drop budget exceeded')
    if stalled > max_stall: failures.append('stall budget exceeded')
    if stalled + rendered_readiness_lost > max_stall: failures.append('interruption budget exceeded')
    if max_gap > 3: failures.append('telemetry gap over 3 seconds')
    if require_buffering_metrics:
        if not samples or any(s.get('bufferingMs') is None for s in samples):
            failures.append('missing buffering duration telemetry')
        elif reported_buffering > max_stall:
            failures.append('buffering duration budget exceeded')
    if require_render_activity:
        if not rendered or any(s.get('renderedFrameCount') is None for s in rendered):
            failures.append('missing renderer activity samples')
        elif max(s['renderedFrameCount'] for s in rendered) < 2:
            failures.append('renderer did not deliver successive frames')
        if frozen_renderer > max_stall: failures.append('renderer freeze budget exceeded')
        if not rendered or any(s.get('windowVisible') is None for s in rendered):
            failures.append('missing renderer window visibility')
        elif sum(bool(s['windowVisible']) for s in rendered) / len(rendered) < .95:
            failures.append('validation window was occluded')
    return dict(passed=not failures, failures=failures, samples=len(samples),
                playbackClockSource='observed-time-pos' if raw_clock else 'legacy-ui-time',
                startupMs=startup, progressSeconds=progress, stalledSeconds=stalled,
                renderedReadinessLostSeconds=rendered_readiness_lost,
                sampledInterruptionSeconds=stalled + rendered_readiness_lost,
                timestampDiscontinuities=timestamp_discontinuities,
                excludedClockJumpSeconds=excluded_clock_jump_seconds,
                reportedBufferingSeconds=reported_buffering,
                rendererFrozenSeconds=frozen_renderer if require_render_activity else None,
                visibleSampleFraction=(sum(bool(s.get('windowVisible')) for s in rendered) / len(rendered))
                    if require_render_activity and rendered else None,
                maxSampleGapSeconds=max_gap, **totals)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--seconds', type=int, default=30)
    parser.add_argument('--profile', choices=PROFILES, default='720p30')
    parser.add_argument('--prepare-only', action='store_true', help='generate/verify the local corpus without building or launching an engine')
    parser.add_argument('--print-fixture-command', action='store_true', help='print the bounded generation command without encoding or launching anything')
    parser.add_argument('--engine', choices=['mpv', 'native', 'gstreamer'], default='mpv')
    parser.add_argument('--configuration', choices=['debug', 'optimized'], default='debug')
    parser.add_argument('--stream-type', choices=['live', 'vod'], default='live')
    parser.add_argument('--ao', choices=['auto', 'coreaudio', 'avfoundation'], default='auto')
    parser.add_argument('--http-retry', action='store_true')
    parser.add_argument('--transport-proxy', action='store_true',
                        help='experimental loopback-only HLS broker: bounded retries of exact media bytes')
    parser.add_argument('--render-no-block', action='store_true')
    parser.add_argument('--startup-reserve', action='store_true')
    parser.add_argument('--startup-target', action='store_true', help='DEBUG trial: hold live playback until measured buffer target')
    parser.add_argument('--native-cache-only', action='store_true', help='DEBUG trial: native cache handling without the app floor')
    parser.add_argument('--live-analysis', type=int, choices=[1, 2], help='DEBUG trial: bounded known-format live stream analysis')
    parser.add_argument('--gst-audio-map', type=int, choices=range(2, 17))
    parser.add_argument('--gst-sink', choices=['avsamplebufferlayersink', 'osxvideosink', 'glimagesink'], default='avsamplebufferlayersink')
    parser.add_argument('--fault', choices=FAULTS, default='none')
    parser.add_argument('--fault-at', type=float, default=12)
    parser.add_argument('--fault-seconds', type=float, default=8)
    parser.add_argument('--max-drops', type=int, default=5)
    parser.add_argument('--max-stall', type=float, default=3)
    args = parser.parse_args()
    if sum((args.startup_reserve, args.startup_target, args.native_cache_only)) > 1:
        parser.error('select one startup experiment')
    if not 10 <= args.seconds <= 300: parser.error('seconds must be 10..300')
    if (not math.isfinite(args.fault_seconds) or not math.isfinite(args.fault_at)
            or args.fault_seconds <= 0 or args.fault_at < 0):
        parser.error('invalid fault schedule')
    if args.print_fixture_command:
        fixture = ROOT / '.local' / f'hls-{args.profile}-{args.seconds + 40}'
        print(shlex.join(fixture_command(args.profile, args.seconds + 40, fixture)))
        return 0
    if not shutil.which('ffmpeg'): parser.error('ffmpeg required (brew install ffmpeg)')
    if not shutil.which('ffprobe'): parser.error('ffprobe required to verify the actual fixture')
    out = ROOT / '.logs' / ('playback-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
    out.mkdir(parents=True)
    if args.prepare_only:
        fixture, _, _, fixture_metadata = prepare_fixture(args.profile, args.seconds, out)
        print(json.dumps(dict(prepared=True, fixture=str(fixture), fixtureMetadata=fixture_metadata), indent=2))
        print(f'Artifacts: {out.relative_to(ROOT)}')
        return 0
    executable = build_config.executable_path(args.configuration)
    metadata = None
    if args.engine != 'mpv' and args.configuration != 'debug':
        parser.error('--configuration selects the full Buffer build and only applies to mpv')
    if args.render_no_block and args.engine != 'mpv':
        parser.error('--render-no-block only applies to the full Buffer experiment')
    if args.startup_reserve and args.engine != 'mpv':
        parser.error('--startup-reserve only applies to the full Buffer experiment')
    if args.startup_target and args.engine != 'mpv':
        parser.error('--startup-target only applies to the full Buffer experiment')
    if args.native_cache_only and args.engine != 'mpv':
        parser.error('--native-cache-only only applies to the full Buffer experiment')
    if args.live_analysis and args.engine != 'mpv':
        parser.error('--live-analysis only applies to the full Buffer experiment')
    if args.engine == 'native':
        if args.ao != 'auto' or args.http_retry: parser.error('mpv-specific options cannot apply to native engine')
        executable = ROOT / '.local/bench/native-player'
        executable.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(['swiftc', '-O', str(ROOT / 'benchmarks/native_player.swift'), '-o', str(executable),
                        '-framework', 'AppKit', '-framework', 'AVFoundation', '-framework', 'AVKit'], check=True, timeout=60)
    if args.engine == 'gstreamer':
        if args.ao != 'auto' or args.http_retry: parser.error('mpv-specific options cannot apply to GStreamer')
        executable = ROOT / '.local/bench/gstreamer-player'
        executable.parent.mkdir(parents=True, exist_ok=True)
        flags = subprocess.check_output(['pkg-config', '--cflags', '--libs', 'gstreamer-1.0', 'gstreamer-video-1.0'], text=True)
        subprocess.run(['clang', '-O2', '-fobjc-arc', str(ROOT / 'benchmarks/gstreamer_player.m'),
                        '-o', str(executable), '-framework', 'AppKit', '-framework', 'AVFoundation',
                        '-framework', 'QuartzCore', '-framework', 'CoreAudio', *shlex.split(flags)], check=True, timeout=60)
    if not executable.exists(): parser.error('build first with scripts/bench.sh')
    if args.engine == 'mpv': metadata = build_config.read_binary_metadata(executable, args.configuration)
    fingerprint = build_config.artifact_fingerprint(executable)
    binary_hash = fingerprint['sha256']
    fixture, segments, ends, fixture_metadata = prepare_fixture(args.profile, args.seconds, out)
    lock = threading.Lock()
    fault_events = []
    request_events = []
    request_totals = dict(total=0, injected=0, dropped=0)
    first_request = [None]
    stream_origin_wall = [None]

    class Handler(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *_): pass
        def send_response(self, code, message=None):
            if hasattr(self, 'validation_request'):
                with lock:
                    self.validation_request['status'] = code
                    self.validation_request['responseElapsed'] = time.monotonic() - first_request[0]
            super().send_response(code, message)
        def do_GET(self):
            with lock:
                if first_request[0] is None:
                    first_request[0] = time.monotonic()
                    stream_origin_wall[0] = time.time() - 20
                elapsed = time.monotonic() - first_request[0]
                inject = args.fault == 'offline' or (args.fault != 'none' and self.path.endswith('.ts')
                    and args.fault_at <= elapsed < args.fault_at + args.fault_seconds)
                self.validation_request = dict(elapsed=elapsed, resource=self.path,
                                               injected=inject, status=None)
                request_totals['total'] += 1
                if len(request_events) < 10000:
                    request_events.append(self.validation_request)
                else:
                    request_totals['dropped'] += 1
                if inject:
                    request_totals['injected'] += 1
                    if len(fault_events) < 10000:
                        fault_events.append(dict(elapsed=elapsed, fault=args.fault,
                                                 resource=self.path, status=injected_status(args.fault)))
            if inject:
                if args.fault == 'stall': time.sleep(args.fault_seconds)
                else:
                    self.send_response(injected_status(args.fault))
                    if args.fault in ('429', '503'):
                        self.send_header('Retry-After', str(max(1, math.ceil(args.fault_seconds))))
                    self.send_header('Content-Length', '0')
                    self.end_headers()
                    return
            if args.stream_type == 'live' and self.path == '/stream.m3u8':
                # A rolling real-time playlist, without ENDLIST. Never advertise
                # future segments: VOD fault behavior is not live HLS recovery.
                body = rolling_playlist(segments, ends, elapsed, stream_origin_wall[0])
                self.send_response(200)
                self.send_header('Content-Type', 'application/vnd.apple.mpegurl')
                self.send_header('Content-Length', str(len(body)))
                self.send_header('Cache-Control', 'no-store')
                self.end_headers()
                try: self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError): pass
                return
            try: super().do_GET()
            except (BrokenPipeError, ConnectionResetError): pass

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Handler, directory=str(fixture)))
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    resources = []
    proc = None
    transport_proxy = None
    transport_evidence = None
    try:
        origin = f'http://127.0.0.1:{server.server_port}'
        if args.transport_proxy:
            transport_proxy = start_local_transport_proxy(origin)
        playback_url = transport_proxy.url() if transport_proxy else origin + '/stream.m3u8'
        with (out / 'stdout.log').open('w') as stdout, (out / 'stderr.log').open('w') as stderr:
            command = [str(executable), '--validate-url',
                playback_url, '--validate-seconds', str(args.seconds),
                '--validate-buffer', '5']
            if args.ao != 'auto': command.extend(['--validate-ao', args.ao])
            if args.http_retry: command.append('--validate-http-retry')
            if args.render_no_block: command.append('--validate-render-no-block')
            if args.startup_reserve: command.append('--validate-startup-reserve')
            if args.startup_target: command.append('--validate-startup-target')
            if args.native_cache_only: command.append('--validate-native-cache-only')
            if args.live_analysis: command.append(f'--validate-live-analysis={args.live_analysis}')
            if args.gst_audio_map: command.extend(['--gst-audio-map', str(args.gst_audio_map)])
            if args.engine == 'gstreamer': command.extend(['--gst-sink', args.gst_sink])
            environment = os.environ.copy()
            if args.engine == 'gstreamer':
                environment['GST_REGISTRY'] = str(ROOT / '.local/bench/gst-registry.bin')
            proc = subprocess.Popen(command, stdout=stdout, stderr=stderr, env=environment)
            deadline = time.monotonic() + args.seconds + 20
            while proc.poll() is None and time.monotonic() < deadline:
                ps = subprocess.run(['ps', '-p', str(proc.pid), '-o', '%cpu=,rss='], capture_output=True, text=True)
                fields = ps.stdout.split()
                if len(fields) == 2: resources.append(dict(cpuPercent=float(fields[0]), rssKiB=int(fields[1])))
                time.sleep(.5)
            if proc.poll() is None:
                proc.terminate()
                proc.wait(timeout=10)
        if transport_proxy:
            transport_proxy.close()
            transport_evidence = transport_proxy.broker.snapshot()
        events = [json.loads(line.removeprefix('BUFFER_PLAYBACK_JSON '))
                  for line in (out / 'stdout.log').read_text().splitlines() if line.startswith('BUFFER_PLAYBACK_JSON ')]
        report = score(events, args.seconds, args.max_drops, args.max_stall,
                       require_render_activity=args.engine == 'mpv',
                       require_buffering_metrics=args.engine == 'mpv')
        rendered = [e for e in events if e.get('event') == 'sample' and e['rendered']]
        outputs = sorted({e.get('audioOutput', 'unavailable') for e in rendered})
        sync = [abs(e['avSyncSeconds']) for e in rendered if e.get('avSyncSeconds') is not None]
        report.update(audioOutputs=outputs, maxAVSyncSeconds=max(sync, default=None))
        if args.startup_reserve and not startup_reserve_confirmed(rendered):
            report['failures'].append('startup reserve experiment lacked actual mpv setting confirmation')
        if args.startup_target and not startup_target_confirmed(rendered, 5):
            report['failures'].append('startup target experiment lacked measured buffer release')
        if args.native_cache_only and (not rendered or any(sample.get('nativeCacheOnlyEnabled') is not True
                or sample.get('cacheFloorPauses') != 0 for sample in rendered)):
            report['failures'].append('native cache-only experiment was not active')
        if args.live_analysis and not live_analysis_confirmed(rendered, args.live_analysis):
            report['failures'].append('live analysis experiment lacked actual option/audio confirmation')
        if args.render_no_block and (not events or events[0].get('renderTimingNoBlock') is not True
                or not rendered or any(event.get('renderTimingNoBlock') is not True for event in rendered)):
            report['failures'].append('render timing experiment was not active')
        if not outputs or any(o in ('unavailable', 'null', '') for o in outputs):
            report['failures'].append('no real audio output')
        if args.ao != 'auto' and outputs != [args.ao]:
            report['failures'].append('requested audio backend not active')
        if args.engine == 'mpv':
            if not sync: report['failures'].append('missing A/V synchronization samples')
            elif max(sync) > .150: report['failures'].append('A/V sync exceeds 150 ms')
        else:
            report['decoderDrops'] = None
            report['mistimed'] = None
            report['delayed'] = None
            probe_name = 'AVPlayer' if args.engine == 'native' else 'GStreamer'
            report['measurementLimitations'] = [f'{probe_name} A/V synchronization, independent buffering duration, and separate decoder drops are not exposed by this probe',
                                                'Readiness loss is sampled; brief buffering between samples can be missed',
                                                f'{probe_name} audio label identifies the engine, not verified physical audio-device output',
                                                'Standalone optimized probe: not an equivalent full Buffer app CPU/memory comparison; decoder/GPU/system costs are outside sampled process metrics']
            if not any(e.get('dropMetricsAvailable') for e in rendered):
                report['failures'].append('missing native dropped-frame metrics')
        latency = [e['liveLatencySeconds'] for e in rendered if e.get('liveLatencySeconds') is not None]
        report['medianLiveLatencySeconds'] = statistics.median(latency) if latency else None
        if args.engine == 'gstreamer':
            fixture_delay = [e['sampleWallTime'] - stream_origin_wall[0] - e['lastFrameStreamTime']
                             for e in rendered if e.get('lastFrameStreamTime') is not None and stream_origin_wall[0] is not None]
            report['medianFixtureLiveDelayEstimateSeconds'] = statistics.median(fixture_delay) if fixture_delay else None
            report['measurementLimitations'].append('GStreamer live delay is a fixture estimate using sink sample stream-time and known playlist origin, not a general provider wall-clock metric')
            actual = sorted({name for event in rendered for name in event.get('elements', [])})
            report['pipelineElements'] = actual
            if 'vtdec_hw' not in actual: report['failures'].append('VideoToolbox hardware decoder not active')
            if 'hlsdemux2' not in actual: report['failures'].append('adaptive HLS demuxer not active')
        if any(e.get('event') == 'error' for e in events):
            report['failures'].append('engine reported an error')
        if proc.returncode != 0:
            report['failures'].append(f'process exit {proc.returncode}')
        if args.fault != 'none' and not request_totals['injected']:
            report['failures'].append('requested fault never injected')
        if request_totals['dropped']:
            report['failures'].append('HTTP request evidence exceeded bounded capture')
        if args.transport_proxy:
            if not transport_evidence or not transport_evidence['originAttempts']:
                report['failures'].append('experimental transport proxy had no actual origin requests')
            elif transport_evidence['internalFailures']:
                report['failures'].append('experimental transport proxy had an internal failure')
            elif transport_evidence['eventDrops']:
                report['failures'].append('experimental transport proxy evidence exceeded bounded capture')
            elif transport_evidence['peakActiveFetches'] > transport_evidence['policy']['max_fetches']:
                report['failures'].append('experimental transport proxy exceeded fetch permits')
            if args.fault in ('502', '503') and request_totals['injected'] and not (transport_evidence or {}).get('retries', 0):
                report['failures'].append('experimental transport proxy did not retry the injected transient failure')
        report.update(schema=5, scenario=vars(args), faultEvents=fault_events,
                      requestEvents=request_events, requestTotals=request_totals,
                      fixtureMetadata=fixture_metadata,
                      transportPolicy='local-fixture-broker-experiment' if args.transport_proxy else 'engine-default',
                      transportProxy=transport_evidence,
                      buildMetadata=metadata, artifactFingerprint=fingerprint,
                      resources=resources, events=events, binarySHA256=binary_hash,
                      peakRSSMiB=max((r['rssKiB'] / 1024 for r in resources), default=0),
                      medianCPUPercent=statistics.median([r['cpuPercent'] for r in resources]) if resources else None)
        report['passed'] = not report['failures']
        (out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps({**{k: v for k, v in report.items() if k not in ('events', 'resources', 'faultEvents', 'requestEvents')},
                          'injectedFaultRequests': request_totals['injected']}, indent=2))
        print(f'Artifacts: {out.relative_to(ROOT)}')
        return 0 if report['passed'] else 2
    finally:
        if proc and proc.poll() is None:
            proc.kill()
            proc.wait()
        if transport_proxy:
            transport_proxy.close()
        server.shutdown()
        server.server_close()

if __name__ == '__main__':
    raise SystemExit(main())

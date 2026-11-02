import copy
import contextlib
import io
import pathlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import playback
from playback import (score, fixture_command, validate_fixture_probe,
                      read_segments, segment_timeline, rolling_playlist,
                      injected_status)


class StartupReserveEvidenceTests(unittest.TestCase):
    def test_live_analysis_needs_actual_unchanged_probe_and_decoded_audio(self):
        sample = dict(liveAnalysisEnabled=True, liveAnalysisRequestedSeconds=2,
                      lavfAnalyzeDurationSeconds=2, lavfProbeSize=2_097_152,
                      lavfProbeInfo='auto', audioSampleRate=48_000)
        self.assertTrue(playback.live_analysis_confirmed([sample], 2))
        for key, value in [('lavfAnalyzeDurationSeconds', 5), ('lavfProbeSize', 65536),
                           ('lavfProbeInfo', 'no'), ('audioSampleRate', None)]:
            with self.subTest(key=key):
                self.assertFalse(playback.live_analysis_confirmed([sample | {key: value}], 2))
        self.assertFalse(playback.live_analysis_confirmed([sample | dict(lavfAnalyzeDurationSeconds=None,
            lavfProbeSize=None, lavfProbeInfo=None)], 2))

    def test_target_timeout_or_underfilled_release_cannot_qualify(self):
        for active, cache, released in [(True, None, None), (False, 4.99, 1000),
                                         (False, float('nan'), 1000), (False, 5, None)]:
            with self.subTest(active=active, cache=cache, released=released):
                self.assertFalse(playback.startup_target_confirmed([dict(startupTargetEnabled=True,
                    startupHoldActive=active, startupHoldReleaseCacheSeconds=cache,
                    startupHoldReleasedAtMs=released)], 5))

    def test_target_requires_actual_release_above_requested_reserve(self):
        self.assertTrue(playback.startup_target_confirmed([dict(startupTargetEnabled=True,
            startupHoldActive=False, startupHoldReleaseCacheSeconds=5.01, startupHoldReleasedAtMs=2000)], 5))

    def test_requested_flag_without_actual_readback_cannot_qualify(self):
        self.assertFalse(playback.startup_reserve_confirmed([dict(startupReserveEnabled=True)]))

    def test_current_item_readback_confirms_after_initial_unknown_samples(self):
        self.assertTrue(playback.startup_reserve_confirmed([
            dict(startupReserveEnabled=True, cachePauseInitial=None, cachePauseWaitSeconds=None),
            dict(startupReserveEnabled=True, cachePauseInitial=True, cachePauseWaitSeconds=None),
            dict(startupReserveEnabled=True, cachePauseInitial=True, cachePauseWaitSeconds=2.5)]))

    def test_disabled_or_invalid_core_settings_cannot_qualify(self):
        for initial, wait in [(False, 2.5), (True, 0), (True, -1), (True, float('nan')),
                              (True, float('inf')), (True, True), (True, None)]:
            with self.subTest(initial=initial, wait=wait):
                self.assertFalse(playback.startup_reserve_confirmed([
                    dict(startupReserveEnabled=True, cachePauseInitial=initial, cachePauseWaitSeconds=wait)]))


class PlaybackFixtureTests(unittest.TestCase):
    def probe(self, profile='2160p5994-hevc10'):
        spec = playback.PROFILES[profile]
        return dict(streams=[dict(codec_type='video', codec_name=spec['codec'],
                                  width=spec['width'], height=spec['height'],
                                  avg_frame_rate=spec['fps'], r_frame_rate=spec['fps'],
                                  pix_fmt='yuv420p10le' if spec['bits'] == 10 else 'yuv420p',
                                  color_space='bt709', color_transfer='bt709', color_primaries='bt709'),
                             dict(codec_type='audio', codec_name='aac', sample_rate='48000', channels=2)])

    def test_actual_hevc_main10_sdr_probe_is_accepted(self):
        metadata = validate_fixture_probe('2160p5994-hevc10', self.probe())
        self.assertEqual(metadata['video']['avg_frame_rate'], '60000/1001')
        self.assertEqual(metadata['content'], 'synthetic SDR test pattern')
        self.assertFalse(metadata['physicalAudioQualification'])

    def test_profile_name_cannot_substitute_for_actual_format(self):
        for field, value in [('codec_name', 'h264'), ('width', 1920), ('height', 1080),
                             ('pix_fmt', 'yuv420p'), ('avg_frame_rate', '50')]:
            with self.subTest(field=field):
                probe = self.probe()
                probe['streams'][0][field] = value
                with self.assertRaises(ValueError):
                    validate_fixture_probe('2160p5994-hevc10', probe)

    def test_main10_sdr_claim_rejects_missing_or_hdr_signaling(self):
        for field, value in [('color_space', None), ('color_transfer', 'smpte2084'),
                             ('color_primaries', 'bt2020')]:
            with self.subTest(field=field):
                probe = self.probe()
                probe['streams'][0][field] = value
                with self.assertRaises(ValueError):
                    validate_fixture_probe('2160p5994-hevc10', probe)

    def test_missing_or_wrong_audio_is_rejected(self):
        for streams in [self.probe()['streams'][:1],
                        [self.probe()['streams'][0], dict(codec_type='audio', codec_name='aac', sample_rate='44100', channels=2)]]:
            with self.subTest(streams=streams):
                with self.assertRaises(ValueError):
                    validate_fixture_probe('2160p5994-hevc10', dict(streams=streams))

    def test_unknown_average_frame_rate_uses_actual_stream_rate(self):
        probe = self.probe()
        probe['streams'][0]['avg_frame_rate'] = '0/0'
        self.assertEqual(validate_fixture_probe('2160p5994-hevc10', probe)['video']['r_frame_rate'], '60000/1001')

    def test_old_h264_fixture_profile_remains_compatible(self):
        probe = self.probe('720p30')
        for field in ('color_space', 'color_transfer', 'color_primaries'):
            probe['streams'][0].pop(field)
        self.assertEqual(validate_fixture_probe('720p30', probe)['video']['codec_name'], 'h264')

    def test_main10_generation_requests_hardware_and_ten_bit_pixels(self):
        command = fixture_command('2160p50-hevc10', 70, pathlib.Path('/tmp/local-fixture'))
        for option, expected in [('-c:v', 'hevc_videotoolbox'), ('-profile:v', 'main10'),
                                 ('-pix_fmt', 'p010le'), ('-allow_sw', '0'), ('-t', '70')]:
            self.assertEqual(command[command.index(option) + 1], expected)
        self.assertIn('testsrc2=size=3840x2160:rate=50', command)
        self.assertEqual(command[command.index('-bsf:v') + 1],
                         'hevc_metadata=colour_primaries=1:transfer_characteristics=1:matrix_coefficients=1:video_full_range_flag=0')

    def test_fractional_frame_rate_is_preserved_in_generation(self):
        command = fixture_command('2160p5994-hevc10', 70, pathlib.Path('/tmp/local-fixture'))
        self.assertIn('testsrc2=size=3840x2160:rate=60000/1001', command)
        self.assertEqual(command[command.index('-g') + 1], '120')

    def test_fractional_segments_do_not_advertise_future_media(self):
        segments = [(f'#EXTINF:2.002,', f'segment-{i:03d}.ts') for i in range(40)]
        ends = segment_timeline(segments)
        body = rolling_playlist(segments, ends, elapsed=0, origin_wall=0).decode()
        self.assertIn('segment-008.ts', body)
        self.assertNotIn('segment-009.ts', body)  # completes at 20.020, beyond 20.000
        self.assertIn('#EXT-X-TARGETDURATION:3', body)
        self.assertIn('1970-01-01T00:00:02.002+00:00', body)
        later = rolling_playlist(segments, ends, elapsed=.025, origin_wall=0).decode()
        self.assertIn('segment-009.ts', later)

    def test_rolling_window_uses_actual_sequence_and_origin(self):
        segments = [('#EXTINF:2.000000,', f'segment-{i:03d}.ts') for i in range(40)]
        body = rolling_playlist(segments, segment_timeline(segments), elapsed=20, origin_wall=0).decode()
        self.assertIn('#EXT-X-MEDIA-SEQUENCE:8', body)
        self.assertIn('1970-01-01T00:00:16.000+00:00', body)
        self.assertNotIn('segment-007.ts', body)
        self.assertNotIn('#EXT-X-ENDLIST', body)

    def test_segment_reader_rejects_invalid_duration_and_escape(self):
        with tempfile.TemporaryDirectory() as directory:
            playlist = pathlib.Path(directory) / 'stream.m3u8'
            for contents in ['#EXTINF:nan,\nsegment-000.ts\n',
                             '#EXTINF:-2,\nsegment-000.ts\n',
                             '#EXTINF:2,\n../segment-000.ts\n']:
                with self.subTest(contents=contents):
                    playlist.write_text(contents)
                    with self.assertRaises(ValueError):
                        read_segments(playlist)

    def test_print_command_does_not_encode_probe_build_or_launch(self):
        with patch('sys.argv', ['playback.py', '--profile', '2160p50-hevc10', '--print-fixture-command']), \
                patch('playback.subprocess.run') as run, patch('playback.subprocess.check_output') as check, \
                patch('playback.subprocess.Popen') as launch, contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(playback.main(), 0)
            self.assertIn('hevc_videotoolbox', output.getvalue())
            run.assert_not_called()
            check.assert_not_called()
            launch.assert_not_called()

    def test_failed_generation_does_not_leave_a_reusable_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            out = root / 'logs'
            out.mkdir()
            def partial_encode(*args, **kwargs):
                fixture = root / '.local/hls-2160p50-hevc10-70'
                (fixture / 'stream.m3u8').write_text('#EXTM3U\n')
                raise subprocess.CalledProcessError(1, args[0])
            with patch('playback.ROOT', root), patch('playback.subprocess.run', side_effect=partial_encode):
                with self.assertRaises(subprocess.CalledProcessError):
                    playback.prepare_fixture('2160p50-hevc10', 30, out)
            self.assertFalse((root / '.local/hls-2160p50-hevc10-70/stream.m3u8').exists())

    def test_fault_status_preserves_auth_throttle_and_transient_classes(self):
        for fault in ('502', '503', '401', '403', '404', '429', '509'):
            self.assertEqual(injected_status(fault), int(fault))
        self.assertEqual(injected_status('offline'), 502)
        self.assertIsNone(injected_status('stall'))

class PlaybackGateTests(unittest.TestCase):
    def clean(self):
        events = [dict(event='start')]
        for i in range(1, 21):
            events.append(dict(event='sample', elapsedMs=i * 500, generation=1,
                rendered=True, width=1280, height=720, time=i / 2,
                windowVisible=True,
                frameDrops=0, decoderDrops=0, mistimed=0, delayed=0))
        return events + [dict(event='end')]

    def test_clean_passes(self):
        self.assertTrue(score(self.clean(), 10)['passed'])

    def test_raw_clock_avoids_ui_quantization_without_relaxing_jump_gate(self):
        events = self.clean()
        for sample in events[1:-1]:
            sample.update(rawTimePos=sample['time'], rawTimePosAgeMs=20)
        events[6]['time'] += 0.4
        self.assertTrue(score(events, 10)['passed'])
        legacy = copy.deepcopy(events)
        for sample in legacy[1:-1]:
            sample.pop('rawTimePos'); sample.pop('rawTimePosAgeMs')
        self.assertIn('playback clock discontinuity', score(legacy, 10)['failures'])
        for sample in events[11:-1]: sample['rawTimePos'] += 100
        self.assertIn('playback clock discontinuity', score(events, 10)['failures'])

    def test_missing_invalid_or_stale_raw_clock_fails_closed(self):
        for field, value in [('rawTimePos', None), ('rawTimePos', float('nan')),
                             ('rawTimePosAgeMs', None), ('rawTimePosAgeMs', 1001)]:
            with self.subTest(field=field, value=value):
                events = self.clean()
                for sample in events[1:-1]:
                    sample.update(rawTimePos=sample['time'], rawTimePosAgeMs=20)
                events[6][field] = value
                self.assertFalse(score(events, 10)['passed'])

    def test_held_raw_position_may_age_without_becoming_fake_progress(self):
        events = self.clean()
        for sample in events[1:-1]:
            sample.update(rawTimePos=1, rawTimePosAgeMs=5000, pause=True,
                          renderedFrameCount=1, playbackRequested=True)
        report = score(events, 10)
        self.assertNotIn('stale raw playback clock telemetry', report['failures'])
        self.assertEqual(report['progressSeconds'], 0)
        self.assertFalse(report['passed'])

    def test_resume_jump_then_user_pause_is_not_playback_progress(self):
        events = self.clean()
        events[1]['time'] = 0
        for event in events[2:-1]: event['time'] = 60
        for event in events[3:-1]: event['playbackRequested'] = False
        report = score(events, 10)
        self.assertEqual(report['progressSeconds'], 0)
        self.assertEqual(report['sampledInterruptionSeconds'], 0)
        self.assertIn('insufficient playback progress', report['failures'])
        self.assertFalse(report['passed'])

    def test_transport_timestamp_jumps_are_excluded_and_fail(self):
        for jump in [95_000, -95_000]:
            with self.subTest(jump=jump):
                events = self.clean()
                for event in events[11:-1]: event['time'] += jump
                report = score(events, 10)
                self.assertEqual(report['progressSeconds'], 9)
                self.assertEqual(report['timestampDiscontinuities'], 1)
                self.assertIn('playback clock discontinuity', report['failures'])
                self.assertFalse(report['passed'])

    def test_new_generation_clock_origin_can_change(self):
        events = self.clean()
        for event in events[1:11]: event['time'] += 95_000
        for event in events[11:-1]:
            event['generation'] = 2
            event['time'] += 60
        report = score(events, 10)
        self.assertEqual(report['progressSeconds'], 9)
        self.assertEqual(report['timestampDiscontinuities'], 0)
        self.assertTrue(report['passed'])

    def test_nonfinite_playback_clock_cannot_pass(self):
        events = self.clean()
        events[8]['time'] = float('nan')
        self.assertIn('invalid playback clock telemetry', score(events, 10)['failures'])

    def test_short_rendered_readiness_loss_is_reported(self):
        events = self.clean()
        for event in events[9:11]: event['rendered'] = False
        report = score(events, 10)
        self.assertEqual(report['renderedReadinessLostSeconds'], 1)
        self.assertEqual(report['sampledInterruptionSeconds'], 1)
        self.assertTrue(report['passed'])

    def test_long_rendered_readiness_loss_exceeds_existing_budget(self):
        events = self.clean()
        for event in events[6:15]: event['rendered'] = False
        report = score(events, 10)
        self.assertEqual(report['renderedReadinessLostSeconds'], 4.5)
        self.assertIn('interruption budget exceeded', report['failures'])
        self.assertFalse(report['passed'])

    def test_startup_and_user_pause_are_not_readiness_interruptions(self):
        events = self.clean()
        for event in events[1:4]: event['rendered'] = False
        for event in events[8:11]:
            event['rendered'] = False
            event['playbackRequested'] = False
        report = score(events, 10)
        self.assertEqual(report['renderedReadinessLostSeconds'], 0)
        self.assertEqual(report['sampledInterruptionSeconds'], 0)
        self.assertTrue(report['passed'])

    def test_diagnostic_record_loss_fails_complete_playback(self):
        for marker in [dict(event='output-failure'),
                       dict(event='output-failure', droppedRecords=3, outputHealthy=False),
                       dict(event='transport', droppedRecords=1),
                       dict(event='transport', outputHealthy=False)]:
            with self.subTest(marker=marker):
                events = self.clean()
                events.insert(3, marker)
                report = score(events, 10)
                self.assertFalse(report['passed'])
                self.assertIn('diagnostic output lost records', report['failures'])

    def test_no_data_fails(self):
        self.assertFalse(score([], 10)['passed'])

    def test_crash_fails(self):
        self.assertFalse(score(self.clean()[:-1], 10)['passed'])

    def test_black_video_fails(self):
        events = self.clean()
        for event in events[1:-1]: event['rendered'] = False
        self.assertFalse(score(events, 10)['passed'])

    def test_stall_fails(self):
        events = self.clean()
        for event in events[1:-1]: event['time'] = 0
        self.assertFalse(score(events, 10)['passed'])

    def test_reconnect_does_not_erase_drops(self):
        events = self.clean()
        for event in events[1:11]: event['frameDrops'] = 10
        for event in events[11:-1]: event['generation'] = 2
        report = score(events, 10)
        self.assertEqual(report['frameDrops'], 10)
        self.assertFalse(report['passed'])

    def test_missing_coverage_fails(self):
        events = self.clean()
        self.assertFalse(score(events[:4] + [dict(event='end')], 10)['passed'])

    def test_missing_renderer_activity_fails_closed(self):
        report = score(self.clean(), 10, require_render_activity=True)
        self.assertIn('missing renderer activity samples', report['failures'])

    def test_frozen_video_with_advancing_audio_fails(self):
        events = self.clean()
        for event in events[1:-1]: event['renderedFrameCount'] = 10
        report = score(events, 10, require_render_activity=True)
        self.assertEqual(report['stalledSeconds'], 0)
        self.assertIn('renderer freeze budget exceeded', report['failures'])

    def test_successive_rendered_frames_pass(self):
        events = self.clean()
        for i, event in enumerate(events[1:-1]): event['renderedFrameCount'] = i * 15 + 1
        self.assertTrue(score(events, 10, require_render_activity=True)['passed'])

    def test_render_count_reset_on_reload_is_valid(self):
        events = self.clean()
        for i, event in enumerate(events[1:-1]):
            event['generation'] = 1 if i < 10 else 2
            event['renderedFrameCount'] = (i % 10) * 15 + 1
        self.assertTrue(score(events, 10, require_render_activity=True)['passed'])

    def test_occluded_renderer_is_not_qualified(self):
        events = self.clean()
        for i, event in enumerate(events[1:-1]):
            event.update(renderedFrameCount=i * 15, windowVisible=False)
        self.assertIn('validation window was occluded', score(events, 10, require_render_activity=True)['failures'])

    def test_short_buffering_events_are_counted_between_samples(self):
        events = self.clean()
        for i, event in enumerate(events[1:-1]): event['bufferingMs'] = i * 250
        report = score(events, 10, require_buffering_metrics=True)
        self.assertEqual(report['stalledSeconds'], 0)
        self.assertEqual(report['reportedBufferingSeconds'], 4.75)
        self.assertIn('buffering duration budget exceeded', report['failures'])

    def test_buffering_counters_survive_generation_reset(self):
        events = self.clean()
        for i, event in enumerate(events[1:-1]):
            event.update(generation=1 if i < 10 else 2, bufferingMs=2000 if i < 10 else 1000)
        self.assertEqual(score(events, 10, require_buffering_metrics=True)['reportedBufferingSeconds'], 3)

    def test_missing_buffering_metrics_fails_closed(self):
        self.assertIn('missing buffering duration telemetry', score(self.clean(), 10, require_buffering_metrics=True)['failures'])

if __name__ == '__main__': unittest.main()

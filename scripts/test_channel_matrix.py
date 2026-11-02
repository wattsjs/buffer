import copy
import importlib.util
import pathlib
import re
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('channel_matrix', pathlib.Path(__file__).with_name('channel-matrix.py'))
matrix = importlib.util.module_from_spec(spec)
spec.loader.exec_module(matrix)
METADATA = dict(schema=1, configuration='Debug-Onone', swiftAssertions='debug', swiftOptimization='unoptimized',
                debugInstrumentation=True, architecture='arm64', executableScope='full-macos-app')


class ChannelMatrixTests(unittest.TestCase):
    def setUp(self):
        self.plan = matrix.validate_plan(dict(cases=[dict(sourceName='Source A', channelName='Sports',
            expectedWidth=1280, expectedHeight=720, expectedFPS=60)]))

    def events(self):
        records = [dict(event='start', schema=1, cases=1, caseSeconds=45, buildMetadata=METADATA),
                   dict(event='case-start', case=0), dict(event='case-prepared', case=0)]
        for i in range(1, 46):
            records.append(dict(event='sample', case=0, elapsedMs=i * 1000, generation=1, time=i,
                width=1280, height=720, fps=59.94, rendered=True, frameDrops=0, decoderDrops=0, mistimed=0, delayed=0,
                renderedFrameCount=i * 60, windowVisible=True, bufferingMs=0, playbackRequested=True,
                audioOutput='avfoundation', audioCodec='aac', audioChannels=2, muted=False, volume=100,
                avSyncSeconds=.01, cache=5, playbackMode='live'))
        return records + [dict(event='case-closed', case=0, backendIdle=True),
                          dict(event='case-end', case=0, captured=True, teardownConfirmed=True),
                          dict(event='end', completedCases=1, restored=True, teardownConfirmed=True)]

    def summarize(self, events=None): return matrix.summarize(events or self.events(), self.plan, METADATA)

    def test_complete_real_state_passes_and_records_coded_dimensions(self):
        report = self.summarize()
        self.assertTrue(report['passed'], report)
        self.assertEqual(report['cases'][0]['codedResolutions'], [(1280, 720)])
        self.assertEqual(report['cases'][0]['codedFrameRates'], [59.94])

    def test_missing_channel_is_failed_case_not_skipped_success(self):
        records = self.events()
        records = [r for r in records if r['event'] not in {'sample', 'case-prepared', 'case-closed'}]
        records[-2].update(captured=False, reason='channel-missing')
        report = self.summarize(records)
        self.assertFalse(report['passed'])
        self.assertIn('channel-missing', report['cases'][0]['failures'])

    def test_transport_loss_fails_even_with_all_video_samples(self):
        records = self.events()
        records.insert(3, matrix.sanitize_event(dict(event='output-failure', reason='queue-limit', droppedRecords=2, outputHealthy=False)))
        report = self.summarize(records)
        self.assertFalse(report['passed'])
        self.assertIn('diagnostic output lost records', report['failures'])

    def test_wrong_actual_resolution_and_frame_rate_fail(self):
        for field, value in [('width', 1920), ('fps', 25)]:
            with self.subTest(field=field):
                records = self.events()
                for record in records:
                    if record['event'] == 'sample': record[field] = value
                self.assertFalse(self.summarize(records)['passed'])

    def test_missing_audio_output_and_av_sync_are_not_healthy(self):
        for field in ['audioOutput', 'audioCodec', 'audioChannels', 'avSyncSeconds', 'volume']:
            with self.subTest(field=field):
                records = self.events()
                for record in records:
                    if record['event'] == 'sample': record[field] = None
                self.assertFalse(self.summarize(records)['passed'])

    def test_opened_but_never_requested_playback_is_explicit_failure(self):
        records = self.events()
        for record in records:
            if record['event'] == 'sample': record['playbackRequested'] = False
        report = self.summarize(records)
        self.assertFalse(report['passed'])
        self.assertIn('playback was never requested after opening', report['cases'][0]['failures'])

    def test_frame_freeze_fails_despite_advancing_timestamps(self):
        records = self.events()
        for record in records:
            if record['event'] == 'sample': record['renderedFrameCount'] = 10
        self.assertFalse(self.summarize(records)['passed'])

    def test_unconfirmed_stop_or_restoration_fails(self):
        for field in ['restored', 'teardownConfirmed']:
            records = self.events(); records[-1][field] = False
            self.assertFalse(self.summarize(records)['passed'])

    def test_configuration_mismatch_fails(self):
        records = self.events(); records[0]['buildMetadata'] = dict(METADATA, configuration='Optimized-Instrumented')
        self.assertFalse(self.summarize(records)['passed'])

    def test_overlapping_or_out_of_order_case_records_fail(self):
        records = self.events()
        records.insert(4, dict(event='case-start', case=0))
        self.assertFalse(self.summarize(records)['passed'])
        records = self.events()
        records[2], records[3] = records[3], records[2]
        self.assertFalse(self.summarize(records)['passed'])

    def test_incomplete_malformed_or_duplicate_evidence_fails(self):
        for records in [self.events()[:-1], self.events() + [self.events()[-1]]]:
            self.assertFalse(self.summarize(records)['passed'])
        records = self.events(); records[3]['time'] = None
        self.assertFalse(self.summarize(records)['passed'])

    def test_private_fields_and_url_selectors_rejected(self):
        for case in [dict(sourceName='A', channelName='B', password='forbidden'),
                     dict(sourceName='http://not-a-selector', channelName='B')]:
            with self.assertRaises(ValueError): matrix.validate_plan(dict(cases=[case]))
        with self.assertRaises(ValueError): matrix.sanitize_event(dict(event='sample', audioOutput='https://forbidden'))
        safe = matrix.sanitize_event(dict(event='sample', case=0, streamURL='http://discarded-field'))
        self.assertNotIn('streamURL', safe)

    def test_case_seconds_defaults_and_override(self):
        self.assertEqual(self.plan['caseSeconds'], 45)
        self.assertEqual(matrix.validate_plan(dict(self.plan, caseSeconds=20))['caseSeconds'], 20)
        self.assertEqual(matrix.validate_plan(dict(self.plan, caseSeconds=25))['caseSeconds'], 25)
        self.assertEqual(matrix.validate_plan(dict(self.plan, caseSeconds=60))['caseSeconds'], 60)
        with self.assertRaises(ValueError): matrix.validate_plan(dict(self.plan, caseSeconds=10))

    def test_fast_preset_covers_sources_modes_resolution_and_frame_rates(self):
        plan = matrix.validate_plan(matrix.PRESETS['sports-mix-fast'])
        self.assertEqual(plan['caseSeconds'], 25)
        self.assertEqual(plan['sourceTimeoutSeconds'], 60)
        self.assertEqual(len(plan['cases']), 7)
        self.assertEqual({case['sourceName'] for case in plan['cases']}, {'Odyssey', 'Infinity'})
        self.assertEqual({case['expectedFPS'] for case in plan['cases'] if 'expectedFPS' in case}, {25, 50, 60})
        self.assertEqual({case['expectedHeight'] for case in plan['cases'] if 'expectedHeight' in case}, {576, 720, 1080, 2160})
        self.assertEqual(sum(case['playbackMode'] == 'catchup' for case in plan['cases']), 1)

    def test_short_capture_retains_playback_gates_and_reports_scope(self):
        self.plan['caseSeconds'] = 25
        records = self.events()
        records[0]['caseSeconds'] = 25
        records = [r for r in records if r['event'] != 'sample' or r['elapsedMs'] <= 25000]
        report = self.summarize(records)
        self.assertTrue(report['passed'], report)
        self.assertTrue(any('sustained playback' in limitation for limitation in report['limitations']))
        for record in records:
            if record['event'] == 'sample': record['renderedFrameCount'] = 1
        self.assertFalse(self.summarize(records)['passed'])

    def test_decoded_codec_description_is_retained_without_urls(self):
        codec = 'h264 (H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10)'
        self.assertEqual(matrix.sanitize_event(dict(event='sample', videoCodec=codec))['videoCodec'], codec)
        for value in ['https://forbidden', 'aac\nprivate']:
            with self.assertRaises(ValueError): matrix.sanitize_event(dict(event='sample', audioCodec=value))

    def test_catchup_plan_defaults_and_invalid_offset(self):
        plan = matrix.validate_plan(dict(cases=[dict(sourceName='A', channelName='B', playbackMode='catchup')]))
        self.assertEqual(plan['cases'][0]['catchupOffsetMinutes'], 60)
        with self.assertRaises(ValueError): matrix.validate_plan(dict(cases=[dict(sourceName='A', channelName='B', catchupOffsetMinutes=60)]))
        with self.assertRaises(ValueError): matrix.validate_plan(dict(cases=[dict(sourceName='A', channelName='B', playbackMode='catchup', catchupOffsetMinutes=0)]))

    def test_catchup_must_show_real_programme_not_live_fallback(self):
        self.plan['cases'][0].update(playbackMode='catchup', catchupOffsetMinutes=120)
        records = self.events()
        self.assertFalse(self.summarize(records)['passed'])
        for record in records:
            if record['event'] == 'sample':
                record.update(playbackMode='catchup', catchupRequested=True, catchupProgrammeStartUnixSeconds=1700000000,
                              catchupProgrammeEndUnixSeconds=1700003600, catchupLoadedStartUnixSeconds=1700000000)
        self.assertTrue(self.summarize(records)['passed'])
        records[3]['catchupLoadedStartUnixSeconds'] += 3600
        self.assertFalse(self.summarize(records)['passed'])

    def test_vod_plan_selectors_and_resume_bounds(self):
        plan = matrix.validate_plan(dict(cases=[dict(sourceName='A', vodID='123', playbackMode='vod', vodResumeSeconds=60)]))
        self.assertEqual(plan['cases'][0]['vodResumeSeconds'], 60)
        for item in [dict(sourceName='A', channelName='B', playbackMode='vod'),
                     dict(sourceName='A', vodName='Movie'),
                     dict(sourceName='A', vodName='Movie', channelName='B', playbackMode='vod'),
                     dict(sourceName='A', vodName='Movie', playbackMode='vod', vodResumeSeconds=0),
                     dict(sourceName='A', vodID='https://not-a-selector', playbackMode='vod'),
                     dict(sourceName='A', vodName='Movie', playbackMode='vod', vodResumeSeconds=float('nan'))]:
            with self.subTest(item=item), self.assertRaises(ValueError): matrix.validate_plan(dict(cases=[item]))

    def test_vod_requires_actual_seekable_timeline_and_resume(self):
        self.plan['cases'][0] = dict(sourceName='A', vodID='123', playbackMode='vod', vodResumeSeconds=60)
        records = self.events()
        self.assertFalse(self.summarize(records)['passed'])
        for record in records:
            if record['event'] == 'sample':
                record.update(playbackMode='vod', vodRequested=True, isSeekable=True, duration=3600,
                              vodResumeSeconds=60, time=60 + record['time'])
        report = self.summarize(records)
        self.assertTrue(report['passed'], report)
        self.assertEqual(report['cases'][0]['onDemandDurations'], [3600])
        for field, value in [('duration', 0), ('isSeekable', False), ('vodRequested', False), ('vodResumeSeconds', 120)]:
            failed = copy.deepcopy(records)
            for record in failed:
                if record['event'] == 'sample': record[field] = value
            self.assertFalse(self.summarize(failed)['passed'], field)
        failed = copy.deepcopy(records)
        for record in failed:
            if record['event'] == 'sample': record['time'] -= 60
        self.assertFalse(self.summarize(failed)['passed'])

    def test_actual_swift_coordinator_stops_before_next_source(self):
        with tempfile.TemporaryDirectory() as folder:
            executable = pathlib.Path(folder) / 'scenario-tests'
            subprocess.run(['swiftc', str(ROOT / 'Buffer/Support/SavedPlaybackScenarioPlan.swift'),
                str(ROOT / 'Buffer/Models/SourceChannelIdentity.swift'), str(ROOT / 'Buffer/Models/Channel.swift'), str(ROOT / 'Buffer/Models/EPGProgram.swift'),
                str(ROOT / 'Buffer/Support/SavedScenarioArchiveSelection.swift'),
                str(ROOT / 'benchmarks/saved_scenario_tests.swift'), '-o', str(executable)],
                capture_output=True, text=True, check=True, timeout=60)
            output = subprocess.check_output([str(executable)], text=True, timeout=15)
            result = re.fullmatch(r'Saved scenario coordinator: (\d+) checks passed\n', output)
            self.assertIsNotNone(result, output)
            self.assertGreaterEqual(int(result.group(1)), 23)


if __name__ == '__main__': unittest.main()

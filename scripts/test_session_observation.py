import importlib.util
import pathlib
import unittest

spec = importlib.util.spec_from_file_location('observe_session', pathlib.Path(__file__).with_name('observe-session.py'))
observe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(observe)


class SessionEvidenceTests(unittest.TestCase):
    def events(self):
        records = [dict(event='start')]
        for i in range(1, 6):
            records.append(dict(event='sample', elapsedMs=i * 1000, tickGapMs=1000,
                physicalFootprintBytes=100 * 1024**2,
                players=[dict(slot=1, generation=1, rendered=True, time=i,
                    playbackRequested=True, frameDrops=0, decoderDrops=0,
                    avSyncSeconds=.01, audioOutput='avfoundation', startupMs=500,
                    recoveryReloads=0)]))
        return records + [dict(event='end', reason='duration')]

    def test_complete_evidence_and_footprint(self):
        report = observe.summarize(self.events(), 5)
        self.assertTrue(report['evidenceComplete'])
        self.assertEqual(report['peakPhysicalFootprintMiB'], 100)
        self.assertEqual(report['players'][0]['sampledStalledSeconds'], 0)

    def test_crash_and_early_exit_are_incomplete(self):
        events = self.events()
        self.assertFalse(observe.summarize(events[:-1], 5)['evidenceComplete'])
        events[-1]['reason'] = 'app-terminated'
        self.assertFalse(observe.summarize(events, 5)['evidenceComplete'])

    def test_idle_has_no_health_claim(self):
        events = self.events()
        for event in events[1:-1]: event['players'] = []
        report = observe.summarize(events, 5)
        self.assertEqual(report['players'], [])
        self.assertNotIn('passed', report)

    def test_user_pause_excluded_from_stalls(self):
        events = self.events()
        for event in events[1:-1]:
            event['players'][0].update(time=0, playbackRequested=False)
        report = observe.summarize(events, 5)
        self.assertEqual(report['players'][0]['sampledStalledSeconds'], 0)
        self.assertIsNone(report['players'][0]['maxAVSyncSeconds'])

    def test_active_stall_detected(self):
        events = self.events()
        for event in events[1:-1]: event['players'][0]['time'] = 0
        self.assertEqual(observe.summarize(events, 5)['players'][0]['sampledStalledSeconds'], 4)

    def test_generation_drops_accumulate(self):
        events = self.events()
        events[1]['players'][0]['frameDrops'] = 7
        for event in events[2:-1]: event['players'][0].update(generation=2, frameDrops=2)
        self.assertEqual(observe.summarize(events, 5)['players'][0]['frameDrops'], 9)

    def test_sparse_capture_incomplete(self):
        events = self.events()
        self.assertFalse(observe.summarize(events[:2] + events[-1:], 5)['evidenceComplete'])

    def test_transport_loss_cannot_pass_complete_capture(self):
        events = self.events()
        events.insert(2, dict(event='output-failure', droppedRecords=1, outputHealthy=False))
        report = observe.summarize(events, 5)
        self.assertFalse(report['evidenceComplete'])
        self.assertIn('diagnostic output lost records', report['failures'])

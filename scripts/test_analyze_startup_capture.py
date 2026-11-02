import unittest

from analyze_startup_capture import analyze_samples


def sample(ms, time, frames, pause=False, **values):
    return dict(elapsedMs=ms, generation=1, time=time, renderedFrameCount=frames,
                rendered=True, width=3840, height=2160, playbackRequested=True,
                windowVisible=True, pause=pause, pausedForCache=False, **values)


class StartupAnnotationsTests(unittest.TestCase):
    def test_initial_picture_hold_is_not_moving_startup(self):
        rows = [sample(0, 0, 1, True), sample(1000, 0, 1, True), sample(2000, 0, 2),
                sample(3000, 1, 52), sample(4000, 2, 102)]
        result = analyze_samples(rows)
        self.assertEqual(result['firstPictureMs'], 0)
        self.assertEqual(result['firstMotionLowerMs'], 2000)
        self.assertEqual(result['sustainedMotionConfirmedMs'], 4000)
        self.assertEqual(result['initialHeldPictureSeconds'], 2)

    def test_quantized_clock_jump_keeps_neighbor_evidence(self):
        rows = [sample(0, 0, 0), sample(260, .26, 13), sample(520, .52, 26),
                sample(781, 1.04, 39), sample(1040, 1.04, 52), sample(1300, 1.30, 65)]
        result = analyze_samples(rows)
        jump = result['discontinuities'][0]
        self.assertAlmostEqual(jump['clockSeconds'], .52)
        self.assertEqual(jump['nextClockAdvance'], 0)
        self.assertAlmostEqual(jump['neighboringWindows'][0]['clockSeconds'], .78)
        self.assertEqual(result['postMotionSimultaneousClockFrameFreezeSeconds'], 0)
        self.assertAlmostEqual(result['postMotionClockNonprogressSeconds'], .259)

    def test_fresh_raw_clock_is_distinguished_from_quantized_ui(self):
        rows = [sample(0, 0, 0, rawTimePos=0, rawTimePosAgeMs=0),
                sample(261, .52, 13, rawTimePos=.261, rawTimePosAgeMs=0),
                sample(520, .52, 26, rawTimePos=.52, rawTimePosAgeMs=0)]
        result = analyze_samples(rows)
        self.assertEqual(result['discontinuities'], [])
        self.assertEqual(result['firstMotionLowerMs'], 0)

    def test_generation_change_cannot_confirm_motion(self):
        rows = [sample(0, 0, 0), sample(260, .26, 13), sample(520, .52, 26)]
        rows[-1]['generation'] = 2
        result = analyze_samples(rows)
        self.assertIsNone(result['firstMotionLowerMs'])


if __name__ == '__main__':
    unittest.main()

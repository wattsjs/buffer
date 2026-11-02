import copy
import unittest
from bench import compare
from build_config import validate_metadata

DEBUG_METADATA = dict(schema=1, configuration='Debug-Onone', swiftAssertions='debug',
    swiftOptimization='unoptimized', debugInstrumentation=True, architecture='arm64',
    executableScope='full-macos-app')
OPTIMIZED_METADATA = dict(DEBUG_METADATA, configuration='Optimized-Instrumented',
    swiftAssertions='release', swiftOptimization='optimized')

class ComparisonTests(unittest.TestCase):
    def setUp(self):
        self.baseline = dict(schema=3, fixture='v1', machine={'arch': 'arm64'}, configuration='Debug-Onone',
            buildMetadata=copy.deepcopy(DEBUG_METADATA),
            measurements=[dict(name='parse', checksum=1000, samplesMs=[10.0] * 7)])

    def test_regression_fails(self):
        changed = copy.deepcopy(self.baseline)
        changed['measurements'][0]['samplesMs'] = [12.0] * 7
        self.assertEqual(compare(changed, self.baseline, .15), ['parse'])

    def test_improvement_passes(self):
        changed = copy.deepcopy(self.baseline)
        changed['measurements'][0]['samplesMs'] = [8.0] * 7
        self.assertEqual(compare(changed, self.baseline, .15), [])

    def test_missing_coverage_rejected(self):
        changed = copy.deepcopy(self.baseline)
        changed['measurements'] = []
        with self.assertRaises(ValueError): compare(changed, self.baseline, .15)

    def test_wrong_output_rejected(self):
        changed = copy.deepcopy(self.baseline)
        changed['measurements'][0]['checksum'] = 999
        with self.assertRaises(ValueError): compare(changed, self.baseline, .15)

    def test_incompatible_fixture_rejected(self):
        changed = copy.deepcopy(self.baseline)
        changed['fixture'] = 'v2'
        with self.assertRaises(ValueError): compare(changed, self.baseline, .15)

    def test_debug_optimized_comparison_rejected(self):
        changed = copy.deepcopy(self.baseline)
        changed.update(configuration='Optimized-Instrumented', buildMetadata=OPTIMIZED_METADATA)
        with self.assertRaisesRegex(ValueError, 'configuration'):
            compare(changed, self.baseline, .15)

    def test_legacy_report_cannot_silently_claim_equivalence(self):
        old = copy.deepcopy(self.baseline)
        del old['buildMetadata']
        with self.assertRaisesRegex(ValueError, 'missing executable build metadata'):
            compare(self.baseline, old, .15)

    def test_configuration_label_must_match_executable_metadata(self):
        changed = copy.deepcopy(self.baseline)
        changed['configuration'] = 'Optimized-Instrumented'
        with self.assertRaisesRegex(ValueError, 'Incompatible executable metadata'):
            compare(changed, self.baseline, .15)

    def test_baseline_architecture_mismatch_rejected(self):
        changed = copy.deepcopy(self.baseline)
        changed['buildMetadata']['architecture'] = 'x86_64'
        with self.assertRaisesRegex(ValueError, 'executable build metadata'):
            compare(changed, self.baseline, .15)

    def test_optimized_equal_profile_comparison_passes(self):
        old = dict(self.baseline, configuration='Optimized-Instrumented', buildMetadata=OPTIMIZED_METADATA)
        self.assertEqual(compare(old, copy.deepcopy(old), .15), [])

if __name__ == '__main__': unittest.main()

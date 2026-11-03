import json
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent


class DiagnosticTransportIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.folder = tempfile.TemporaryDirectory()
        cls.executable = pathlib.Path(cls.folder.name) / 'diagnostic-output-tests'
        subprocess.run(['swiftc', '-O', str(ROOT / 'Shared/Support/DiagnosticOutput.swift'),
            str(ROOT / 'benchmarks/diagnostic_output_tests.swift'), '-o', str(cls.executable)],
            capture_output=True, text=True, check=True, timeout=60)

    @classmethod
    def tearDownClass(cls): cls.folder.cleanup()

    def test_full_pipe_broken_consumer_partial_writes_and_real_fifo(self):
        result = subprocess.run([str(self.executable)], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('17 checks passed', result.stdout)

    def test_stdout_claim_is_exclusive_and_end_is_not_lost(self):
        result = subprocess.run([str(self.executable), '--capture-stdout'], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        events = [json.loads(line.removeprefix('BUFFER_TEST_JSON ')) for line in result.stdout.splitlines()
                  if line.startswith('BUFFER_TEST_JSON ')]
        self.assertEqual([event['event'] for event in events], ['start', 'ownership', 'end'])
        self.assertTrue(events[1]['exclusive'])


if __name__ == '__main__': unittest.main()

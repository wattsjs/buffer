#!/usr/bin/env python3
"""Signing selection/prelaunch tests: fake public identities, no real Keychain."""
import importlib.util
import os
import pathlib
import subprocess
import tempfile
import unittest
from unittest import mock

import local_signing

ROOT = pathlib.Path(__file__).resolve().parent.parent
A = 'A' * 40
B = 'B' * 40


def identities(*rows):
    return '\n'.join(f'  {index}) {fingerprint} "{name}"' for index, (fingerprint, name)
                     in enumerate(rows, 1)) + f'\n  {len(rows)} valid identities found\n'


class SigningSelectionTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.config = pathlib.Path(self.folder.name) / '.local/code-sign-identity'

    def choose(self, output, mode='normal', environment=None):
        return local_signing.choose_identity(output, mode, environment or {}, self.config)

    def test_unique_local_identity_is_pinned_and_reused_by_all_modes(self):
        output = identities((A, 'Buffer Local Development'), (B, 'Apple Development: Example'))
        self.assertEqual(self.choose(output), A)
        self.assertEqual(self.config.read_text(), A + '\n')
        self.assertEqual(self.choose(output, 'synthetic'), A)
        with self.assertRaisesRegex(local_signing.SigningError, 'unavailable'):
            self.choose(identities((B, 'Buffer Local Development')), 'synthetic')
        self.assertEqual(self.config.read_text(), A + '\n')

    def test_missing_identity_only_allows_synthetic_or_explicit_normal_opt_in(self):
        output = identities()
        with self.assertRaisesRegex(local_signing.SigningError, 'stable signing certificate'):
            self.choose(output)
        self.assertEqual(self.choose(output, 'synthetic'), '-')
        self.assertEqual(self.choose(output, environment={'BUFFER_ALLOW_ADHOC_SIGNING': '1'}), '-')
        self.assertFalse(self.config.exists())

    def test_other_certificate_is_never_implicitly_chosen(self):
        with self.assertRaises(local_signing.SigningError):
            self.choose(identities((A, 'Apple Development: Unrelated')))

    def test_ambiguous_names_require_explicit_hash(self):
        output = identities((A, 'Buffer Local Development'), (B, 'Buffer Local Development'))
        for mode in ('normal', 'synthetic'):
            with self.assertRaisesRegex(local_signing.SigningError, 'Multiple valid'):
                self.choose(output, mode)
        self.assertEqual(self.choose(output, environment={'BUFFER_CODE_SIGN_IDENTITY': B.lower()}), B)

    def test_duplicate_keychain_rows_for_same_certificate_are_not_ambiguous(self):
        self.assertEqual(self.choose(identities((A, 'Buffer Local Development'),
                                               (A, 'Buffer Local Development'))), A)

    def test_environment_hash_overrides_local_pin_without_rewriting_it(self):
        self.config.parent.mkdir()
        self.config.write_text(A + '\n')
        output = identities((A, 'Buffer Local Development'), (B, 'Apple Development: Example'))
        self.assertEqual(self.choose(output, environment={'BUFFER_CODE_SIGN_IDENTITY': B}), B)
        self.assertEqual(self.config.read_text(), A + '\n')

    def test_unavailable_configured_identity_never_falls_back(self):
        for mode in ('normal', 'synthetic'):
            with self.assertRaisesRegex(local_signing.SigningError, 'unavailable'):
                self.choose(identities((B, 'Buffer Local Development')), mode,
                            {'BUFFER_CODE_SIGN_IDENTITY': A, 'BUFFER_ALLOW_ADHOC_SIGNING': '1'})

    def test_invalid_input_is_data_and_rejected_before_security_query(self):
        with mock.patch.object(local_signing.subprocess, 'run') as query:
            for text in ('-', '', 'Buffer Local Development', '$(touch /tmp/should-not-run)', A + '\n' + B):
                with self.assertRaisesRegex(local_signing.SigningError, '40-character'):
                    local_signing.resolve('synthetic', {'BUFFER_CODE_SIGN_IDENTITY': text}, self.config)
            query.assert_not_called()

    def test_invalid_config_is_not_sourced_or_silently_replaced(self):
        self.config.parent.mkdir()
        self.config.write_text('export BUFFER_CODE_SIGN_IDENTITY=' + A + '\n')
        with self.assertRaisesRegex(local_signing.SigningError, '40-character'):
            self.choose(identities((A, 'Buffer Local Development')), 'synthetic')

    def test_expired_or_untrusted_rows_are_not_valid_choices(self):
        output = f'  1) {A} "Buffer Local Development" (CSSMERR_TP_CERT_EXPIRED)\n0 valid identities found\n'
        self.assertEqual(self.choose(output, 'synthetic'), '-')

    def test_identity_query_is_public_only_and_failure_is_closed(self):
        with mock.patch.object(local_signing.subprocess, 'run',
                               return_value=subprocess.CompletedProcess([], 0, identities(), '')) as query:
            self.assertEqual(local_signing.resolve('synthetic', {}, self.config), '-')
            self.assertEqual(query.call_args.args[0],
                             ['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning'])
        with mock.patch.object(local_signing.subprocess, 'run',
                               side_effect=subprocess.TimeoutExpired('security', 15)):
            with self.assertRaisesRegex(local_signing.SigningError, 'unverified signing fallback'):
                local_signing.resolve('synthetic', {}, self.config)


class ExistingArtifactTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.config = pathlib.Path(self.folder.name) / 'pin'
        self.app = pathlib.Path(self.folder.name) / 'Buffer.app'

    def result(self, output=''):
        return subprocess.CompletedProcess([], 0, '', output)

    def test_ad_hoc_saved_source_launcher_is_blocked_unless_explicit(self):
        with mock.patch.object(local_signing.subprocess, 'run',
                               side_effect=[self.result(), self.result('Signature=adhoc\n')]):
            with self.assertRaisesRegex(local_signing.SigningError, 'ad hoc signed'):
                local_signing.verify_normal_app(self.app, {}, self.config)
        with mock.patch.object(local_signing.subprocess, 'run',
                               side_effect=[self.result(), self.result('Signature=adhoc\n')]):
            self.assertEqual(local_signing.verify_normal_app(
                self.app, {'BUFFER_ALLOW_ADHOC_SIGNING': '1'}, self.config), '-')

    def test_valid_existing_signed_artifact_does_not_need_private_key(self):
        with mock.patch.object(local_signing.subprocess, 'run',
                               side_effect=[self.result(), self.result('Authority=Buffer Local Development\n')]) as call:
            self.assertEqual(local_signing.verify_normal_app(self.app, {}, self.config), 'signed')
            self.assertTrue(all('/usr/bin/security' not in row.args[0] for row in call.call_args_list))

    def test_pinned_existing_artifact_must_use_same_certificate(self):
        self.config.write_text(A + '\n')
        with mock.patch.object(local_signing.subprocess, 'run',
                               side_effect=[self.result(), self.result('Authority=Buffer Local Development\n'),
                                            self.result()]) as call:
            self.assertEqual(local_signing.verify_normal_app(self.app, {}, self.config), A)
            self.assertEqual(call.call_args.args[0][-2:],
                             [f'-R=certificate leaf = H"{A}" and identifier "com.wattsjs.buffer"', str(self.app)])
        with mock.patch.object(local_signing.subprocess, 'run',
                               side_effect=[self.result(), self.result('Authority=Other Certificate\n'),
                                            subprocess.CalledProcessError(3, 'codesign')]):
            with self.assertRaisesRegex(local_signing.SigningError, 'differs from'):
                local_signing.verify_normal_app(self.app, {}, self.config)

    def test_unsigned_or_invalid_artifact_is_never_launched(self):
        with mock.patch.object(local_signing.subprocess, 'run',
                               side_effect=subprocess.CalledProcessError(1, 'codesign')):
            with self.assertRaisesRegex(local_signing.SigningError, 'invalid, unsigned'):
                local_signing.verify_normal_app(self.app, {'BUFFER_ALLOW_ADHOC_SIGNING': '1'}, self.config)

    def test_observer_checks_signature_before_process_checks_or_artifact_collection(self):
        spec = importlib.util.spec_from_file_location('observe_session', ROOT / 'scripts/observe-session.py')
        observer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(observer)
        with mock.patch.object(observer, 'EXECUTABLE', pathlib.Path('/fake/Buffer.app/Contents/MacOS/Buffer')), \
             mock.patch.object(pathlib.Path, 'exists', return_value=True), \
             mock.patch.object(local_signing, 'verify_normal_app', side_effect=local_signing.SigningError('blocked')), \
             mock.patch.object(observer.subprocess, 'run') as launch, \
             mock.patch('sys.argv', ['observe-session.py', '--seconds', '5']):
            with self.assertRaises(SystemExit) as error:
                observer.main()
            self.assertEqual(error.exception.code, 2)
            launch.assert_not_called()


class ShellEntrypointTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.bin = pathlib.Path(self.folder.name)
        self.fake_python = self.bin / 'python3'
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ.get('PATH', ''))

    def test_normal_run_missing_identity_stops_before_process_termination_or_build(self):
        log = self.bin / 'calls'
        self.fake_python.write_text('#!/bin/bash\nprintf "%s\\n" "$*" >> "$FAKE_CALL_LOG"\nexit 17\n')
        self.fake_python.chmod(0o700)
        result = subprocess.run(['/bin/bash', str(ROOT / 'scripts/build-and-run.sh'), '--verify'],
                                env=dict(self.env, FAKE_CALL_LOG=str(log)), capture_output=True, text=True)
        self.assertEqual(result.returncode, 17)
        self.assertEqual(log.read_text().splitlines(), [str(ROOT / 'scripts/local_signing.py') + ' --mode normal'])

    def test_signing_build_arguments_remain_individual_array_elements(self):
        self.fake_python.write_text('#!/bin/bash\nprintf "%s\\n" "$FAKE_SIGNING_HASH"\n')
        self.fake_python.chmod(0o700)
        script = 'source "$1"; buffer_configure_signing normal; printf "%s\\0" "${BUFFER_SIGNING_ARGS[@]}"'
        for selected, required in ((A, 'YES'), ('-', 'NO')):
            result = subprocess.run(['/bin/bash', '-euc', script, 'bash', str(ROOT / 'scripts/local-signing.sh')],
                                    env=dict(self.env, FAKE_SIGNING_HASH=selected), capture_output=True, check=True)
            self.assertEqual(result.stdout.decode().split('\0')[:-1],
                             ['CODE_SIGN_STYLE=Manual', 'CODE_SIGN_IDENTITY=' + selected, 'DEVELOPMENT_TEAM=',
                              'CODE_SIGNING_ALLOWED=YES', 'CODE_SIGNING_REQUIRED=' + required])

    def test_benchmark_skip_build_preserves_cli_without_resolving_identity(self):
        self.fake_python.write_text('#!/bin/bash\nprintf "%s\\0" "$@"\n')
        self.fake_python.chmod(0o700)
        result = subprocess.run(['/bin/bash', str(ROOT / 'scripts/bench.sh'), '--skip-build',
                                 '--compare', 'baseline with spaces.json', '--tolerance', '0.2'],
                                env=self.env, capture_output=True, check=True)
        self.assertEqual(result.stdout.decode().split('\0')[:-1],
                             ['scripts/bench.py', '--configuration', 'debug', '--compare', 'baseline with spaces.json', '--tolerance', '0.2'])


if __name__ == '__main__':
    unittest.main()

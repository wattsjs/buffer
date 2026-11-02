import json
import os
import pathlib
import subprocess
import tempfile
import unittest
from unittest import mock

import build_config

ROOT = pathlib.Path(__file__).resolve().parent.parent
DEBUG_METADATA = dict(schema=1, configuration='Debug-Onone', swiftAssertions='debug',
    swiftOptimization='unoptimized', debugInstrumentation=True, architecture='arm64',
    executableScope='full-macos-app')


class BinaryMetadataTests(unittest.TestCase):
    def test_profiles_use_separate_artifacts(self):
        debug = build_config.executable_path('debug')
        optimized = build_config.executable_path('optimized')
        self.assertNotEqual(debug, optimized)
        self.assertIn('/DerivedData/Build/', str(debug))
        self.assertIn('/.local/DerivedData-Optimized/Build/', str(optimized))

    def test_wrong_binary_fails_even_if_in_right_path(self):
        with self.assertRaisesRegex(ValueError, 'configuration'):
            build_config.validate_metadata(DEBUG_METADATA, 'optimized')

    def test_release_and_standalone_probe_cannot_claim_instrumented_app(self):
        for field, value in [('debugInstrumentation', False), ('swiftAssertions', 'unchecked'),
                             ('executableScope', 'standalone-probe')]:
            with self.subTest(field=field):
                wrong = dict(DEBUG_METADATA, **{field: value})
                with self.assertRaises(ValueError): build_config.validate_metadata(wrong, 'debug')

    def test_duplicate_metadata_rejected(self):
        line = 'BUFFER_BUILD_JSON ' + json.dumps(DEBUG_METADATA) + '\n'
        with mock.patch('build_config.has_metadata_protocol', return_value=True), \
             mock.patch('build_config.binary_sha256', return_value='hash'), \
             mock.patch('build_config.subprocess.run', return_value=subprocess.CompletedProcess([], 0, line * 2, '')):
            with self.assertRaisesRegex(ValueError, 'duplicate'):
                build_config.read_binary_metadata(pathlib.Path('/unused/Buffer'))

    def test_changed_binary_rejected(self):
        line = 'BUFFER_BUILD_JSON ' + json.dumps(DEBUG_METADATA) + '\n'
        with mock.patch('build_config.has_metadata_protocol', return_value=True), \
             mock.patch('build_config.binary_sha256', side_effect=['before', 'after']), \
             mock.patch('build_config.subprocess.run', return_value=subprocess.CompletedProcess([], 0, line, '')):
            with self.assertRaisesRegex(ValueError, 'changed'):
                build_config.read_binary_metadata(pathlib.Path('/unused/Buffer'))

    def test_old_binary_rejected_without_launch(self):
        with tempfile.TemporaryDirectory() as folder:
            old = pathlib.Path(folder) / 'old-Buffer'
            old.write_bytes(b'old executable without metadata command')
            with mock.patch('build_config.subprocess.run') as launch:
                with self.assertRaisesRegex(ValueError, 'no safe build-metadata protocol'):
                    build_config.read_binary_metadata(old)
                launch.assert_not_called()

    def test_debug_loader_detects_protocol_in_loaded_library(self):
        with tempfile.TemporaryDirectory() as folder:
            executable = pathlib.Path(folder) / 'Buffer'
            executable.write_bytes(b'loader @rpath/Buffer.debug.dylib\0')
            dylib = executable.with_name('Buffer.debug.dylib')
            dylib.write_bytes(b'actual Swift code BUFFER_BUILD_JSON ')
            self.assertTrue(build_config.has_metadata_protocol(executable))
            artifact = build_config.artifact_fingerprint(executable)
            self.assertEqual(set(artifact['components']), {'Buffer', 'Buffer.debug.dylib'})

    def test_swift_source_change_invalidates_unchanged_loader_hash(self):
        with tempfile.TemporaryDirectory() as folder:
            executable = pathlib.Path(folder) / 'Buffer'
            executable.write_bytes(b'loader @rpath/Buffer.debug.dylib\0')
            dylib = executable.with_name('Buffer.debug.dylib')
            dylib.write_bytes(b'first Swift build')
            before = build_config.artifact_fingerprint(executable)
            dylib.write_bytes(b'second Swift build')
            after = build_config.artifact_fingerprint(executable)
            self.assertEqual(before['components']['Buffer'], after['components']['Buffer'])
            self.assertNotEqual(before['sha256'], after['sha256'])

    def test_stale_unlinked_debug_library_cannot_claim_metadata_support(self):
        with tempfile.TemporaryDirectory() as folder:
            executable = pathlib.Path(folder) / 'Buffer'
            executable.write_bytes(b'ordinary old binary')
            executable.with_name('Buffer.debug.dylib').write_bytes(b'BUFFER_BUILD_JSON ')
            self.assertFalse(build_config.has_metadata_protocol(executable))

    def test_missing_linked_debug_library_rejected_without_launch(self):
        with tempfile.TemporaryDirectory() as folder:
            executable = pathlib.Path(folder) / 'Buffer'
            executable.write_bytes(b'loader @rpath/Buffer.debug.dylib\0')
            with mock.patch('build_config.subprocess.run') as launch:
                with self.assertRaisesRegex(ValueError, 'missing Debug code dylib'):
                    build_config.read_binary_metadata(executable)
                launch.assert_not_called()

    def test_app_resource_seal_included_in_fingerprint(self):
        with tempfile.TemporaryDirectory() as folder:
            contents = pathlib.Path(folder) / 'Buffer.app/Contents'
            (contents / 'MacOS').mkdir(parents=True)
            (contents / '_CodeSignature').mkdir()
            executable = contents / 'MacOS/Buffer'
            executable.write_bytes(b'full app code')
            seal = contents / '_CodeSignature/CodeResources'
            seal.write_bytes(b'framework signature seal')
            before = build_config.artifact_fingerprint(executable)
            self.assertIn('Contents/_CodeSignature/CodeResources', before['components'])
            seal.write_bytes(b'changed framework signature seal')
            self.assertNotEqual(before['sha256'], build_config.binary_sha256(executable))

    def test_actual_swift_optimizer_changes_runtime_metadata(self):
        # These small executables test compiler-folded metadata only; they are
        # never used as full-app performance evidence or comparison results.
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            main = root / 'metadata-main.swift'
            main.write_text('import Foundation\n'
                            '@main struct Main { static func main() throws { '
                            'let data = try JSONEncoder().encode(BufferBuildConfiguration.metadata); '
                            'print(BufferBuildConfiguration.outputPrefix + String(decoding: data, as: UTF8.self)) } }\n')
            profiles = [
                (['-Onone', '-D', 'DEBUG'], 'Debug-Onone'),
                (['-O', '-D', 'DEBUG', '-D', 'BUFFER_OPTIMIZED_INSTRUMENTED'], 'Optimized-Instrumented'),
                (['-Onone', '-D', 'DEBUG', '-D', 'BUFFER_OPTIMIZED_INSTRUMENTED'], 'Invalid-Optimized-Instrumented'),
                (['-O', '-D', 'DEBUG'], 'Unsupported-Debug-Optimized'),
            ]
            for index, (flags, expected) in enumerate(profiles):
                with self.subTest(flags=flags):
                    binary = root / f'metadata-{index}'
                    subprocess.run(['swiftc', *flags, str(ROOT / 'Buffer/Support/BufferBuildConfiguration.swift'),
                                    str(main), '-o', str(binary)], capture_output=True, text=True,
                                   timeout=60, check=True)
                    self.assertTrue(build_config.has_metadata_protocol(binary))
                    metadata = json.loads(subprocess.check_output([str(binary)], text=True, timeout=10)
                                          .removeprefix('BUFFER_BUILD_JSON '))
                    self.assertEqual(metadata['configuration'], expected)
                    self.assertTrue(metadata['debugInstrumentation'])


class BenchmarkShellProfileTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.root = pathlib.Path(self.folder.name)
        scripts = self.root / 'scripts'
        scripts.mkdir()
        (scripts / 'bench.sh').write_text((ROOT / 'scripts/bench.sh').read_text())
        (scripts / 'bench.py').write_text('import json, sys\nprint(json.dumps(sys.argv[1:]))\n')
        # No real app build, signing command or launch runs in these tests.
        (scripts / 'local-signing.sh').write_text(
            'buffer_configure_signing() { echo "$1" > signing-mode; BUFFER_SIGNING_ARGS=(STUB_SIGNING=YES); }\n'
            'buffer_verify_signing() { echo "$1" > verified-app; }\n')
        self.fake_bin = self.root / 'bin'
        self.fake_bin.mkdir()
        build = self.fake_bin / 'xcodebuild'
        build.write_text('#!/usr/bin/env python3\nimport json, sys\n'
                         'open("build-args.json", "w").write(json.dumps(sys.argv[1:]))\n')
        build.chmod(0o755)
        self.environment = dict(os.environ, PATH=str(self.fake_bin) + os.pathsep + os.environ['PATH'])

    def run_script(self, *arguments):
        return subprocess.run(['bash', str(self.root / 'scripts/bench.sh'), *arguments],
                              capture_output=True, text=True, env=self.environment, timeout=10)

    def test_default_debug_build_preserves_signing_and_path(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        args = json.loads((self.root / 'build-args.json').read_text())
        self.assertEqual(args[args.index('-derivedDataPath') + 1], 'DerivedData')
        self.assertIn('SWIFT_OPTIMIZATION_LEVEL=-Onone', args)
        self.assertIn('STUB_SIGNING=YES', args)
        self.assertEqual((self.root / 'signing-mode').read_text().strip(), 'synthetic')
        self.assertEqual((self.root / 'verified-app').read_text().strip(),
                         str(self.root / 'DerivedData/Build/Products/Debug/Buffer.app'))
        self.assertEqual(json.loads(result.stdout), ['--configuration', 'debug'])

    def test_optimized_build_keeps_default_artifact_separate(self):
        result = self.run_script('--configuration', 'optimized', '--tolerance', '0.2')
        self.assertEqual(result.returncode, 0, result.stderr)
        args = json.loads((self.root / 'build-args.json').read_text())
        self.assertEqual(args[args.index('-derivedDataPath') + 1], '.local/DerivedData-Optimized')
        self.assertIn('SWIFT_OPTIMIZATION_LEVEL=-O', args)
        self.assertIn('SWIFT_COMPILATION_MODE=wholemodule', args)
        self.assertIn('GCC_OPTIMIZATION_LEVEL=2', args)
        self.assertIn('SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG BUFFER_OPTIMIZED_INSTRUMENTED', args)
        self.assertIn('STUB_SIGNING=YES', args)
        self.assertEqual(json.loads(result.stdout), ['--configuration', 'optimized', '--tolerance', '0.2'])

    def test_skip_build_does_not_resolve_signing_or_rebuild(self):
        # Remove the helper: a skipped build must not even source it, so it
        # cannot prompt for a certificate private key on unattended runs.
        (self.root / 'scripts/local-signing.sh').unlink()
        result = self.run_script('--configuration', 'optimized', '--compare', 'baseline.json', '--skip-build')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / 'build-args.json').exists())
        self.assertFalse((self.root / 'verified-app').exists())
        self.assertEqual(json.loads(result.stdout), ['--configuration', 'optimized', '--compare', 'baseline.json'])

    def test_invalid_profile_cannot_build(self):
        result = self.run_script('--configuration', 'release')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'build-args.json').exists())


if __name__ == '__main__': unittest.main()

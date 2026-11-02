"""Select full-app instrumented artifacts and verify metadata from the binary.

The optimized profile is Debug with -O/WMO and all Debug instrumentation. It is
not a claim that Debug-only behavior equals a distributed Release build.
"""
import hashlib
import json
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent
CONFIGURATIONS = {
    'debug': {'label': 'Debug-Onone', 'derivedData': 'DerivedData', 'assertions': 'debug',
              'optimization': 'unoptimized'},
    'optimized': {'label': 'Optimized-Instrumented', 'derivedData': '.local/DerivedData-Optimized',
                  'assertions': 'release', 'optimization': 'optimized'},
}


def executable_path(configuration='debug', root=ROOT):
    profile = CONFIGURATIONS[configuration]
    return root / profile['derivedData'] / 'Build/Products/Debug/Buffer.app/Contents/MacOS/Buffer'


def validate_metadata(metadata, configuration):
    profile = CONFIGURATIONS[configuration]
    expected = dict(schema=1, configuration=profile['label'], swiftAssertions=profile['assertions'],
                    swiftOptimization=profile['optimization'], debugInstrumentation=True,
                    executableScope='full-macos-app')
    for field, value in expected.items():
        if metadata.get(field) != value:
            raise ValueError(f'Incompatible executable metadata: {field} '
                             f'(expected {value!r}, got {metadata.get(field)!r}). '
                             f'Rebuild with scripts/bench.sh --configuration {configuration}')
    if metadata.get('architecture') not in ('arm64', 'x86_64'):
        raise ValueError('Unsupported executable architecture')
    # The versioned canonical fields are sufficient for equivalent-build
    # checks. Ignore future informational fields rather than relying on paths.
    return {**expected, 'architecture': metadata['architecture']}


def code_component_paths(executable):
    """The Xcode Debug executable can be a loader for sibling Swift code."""
    executable = pathlib.Path(executable)
    components = [executable]
    debug_library = executable.with_name(executable.name + '.debug.dylib')
    # Check the loader's link name, not just the presence of a stale dylib.
    if debug_library.name.encode() in executable.read_bytes():
        if not debug_library.is_file():
            raise ValueError('Executable references a missing Debug code dylib; rebuild the app')
        components.append(debug_library)
    return components


def file_sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as incoming:
        for block in iter(lambda: incoming.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def artifact_fingerprint(executable):
    """Hash the actual app code plus its embedded-resource signature seal.

    A thin Debug loader may remain unchanged when Swift source changes. The
    aggregate identifies its linked Debug code library as well. The resource
    seal identifies signed embedded framework/resources for build provenance;
    this is not a substitute for codesign verification.
    """
    executable = pathlib.Path(executable)
    files = code_component_paths(executable)
    in_app = executable.parent.name == 'MacOS' and executable.parent.parent.name == 'Contents'
    base = executable.parent.parent.parent if in_app else executable.parent
    if in_app:
        seal = executable.parent.parent / '_CodeSignature/CodeResources'
        if seal.is_file(): files.append(seal)
    components = {str(path.relative_to(base)): file_sha256(path) for path in files}
    digest = hashlib.sha256(json.dumps(components, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    return {'schema': 1, 'algorithm': 'sha256-code-components-and-resource-seal-v1',
            'sha256': digest, 'components': components}


def binary_sha256(executable):
    """Aggregate code fingerprint; includes Xcode's linked Debug code dylib."""
    return artifact_fingerprint(executable)['sha256']


def has_metadata_protocol(executable):
    # Fail before launching older binaries that do not recognize the flag.
    # Otherwise a pre-metadata Debug binary could enter normal saved-library
    # bootstrap (and prompt for Keychain access) during a synthetic preflight.
    return any(b'BUFFER_BUILD_JSON ' in component.read_bytes()
               for component in code_component_paths(executable))


def read_binary_metadata(executable, configuration='debug'):
    """Query only the pre-bootstrap metadata path; never hydrate saved sources."""
    if not has_metadata_protocol(executable):
        raise ValueError('Executable has no safe build-metadata protocol; rebuild the app before benchmarking')
    before = binary_sha256(executable)
    result = subprocess.run([str(executable), '--build-metadata'], cwd=ROOT,
                            capture_output=True, text=True, timeout=30, check=True)
    lines = [line.removeprefix('BUFFER_BUILD_JSON ') for line in result.stdout.splitlines()
             if line.startswith('BUFFER_BUILD_JSON ')]
    if len(lines) != 1:
        raise ValueError('Missing or duplicate executable build metadata; rebuild the app')
    metadata = validate_metadata(json.loads(lines[0]), configuration)
    if before != binary_sha256(executable):
        raise ValueError('Measured executable changed while reading build metadata')
    return metadata

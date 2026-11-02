#!/usr/bin/env python3
"""Resolve one stable local code-signing certificate; never read passwords.

The persisted value is a public certificate fingerprint, not executable shell
configuration. Synthetic runs bypass saved sources and may fall back to ad hoc.
"""
import argparse
import os
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CONFIG = ROOT / '.local/code-sign-identity'
LOCAL_IDENTITY_NAME = 'Buffer Local Development'
FINGERPRINT = re.compile(r'[0-9A-Fa-f]{40}')
IDENTITY_ROW = re.compile(r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"([^"\n]+)"\s*$')


class SigningError(ValueError):
    pass


def parse_identities(output):
    """Only rows from `find-identity -v` qualify, never status/error lines."""
    identities = {}
    for line in output.splitlines():
        if match := IDENTITY_ROW.fullmatch(line):
            identities[match[1].upper()] = match[2]
    return identities


def configured_fingerprint(environment, config):
    if 'BUFFER_CODE_SIGN_IDENTITY' in environment:
        value = environment['BUFFER_CODE_SIGN_IDENTITY'].strip()
        origin = 'BUFFER_CODE_SIGN_IDENTITY'
    elif config.exists():
        try:
            value = config.read_text(encoding='ascii').strip()
        except (OSError, UnicodeError) as error:
            raise SigningError(f'Cannot read public signing fingerprint from {config}') from error
        origin = str(config)
    else:
        return None
    if not FINGERPRINT.fullmatch(value):
        raise SigningError(f'{origin} must contain one 40-character certificate SHA-1 fingerprint; '
                           'use BUFFER_ALLOW_ADHOC_SIGNING=1 for an intentional ad hoc normal run.')
    return value.upper()


def choose_identity(output, mode, environment, config):
    identities = parse_identities(output)
    configured = configured_fingerprint(environment, config)
    if configured:
        if configured not in identities:
            raise SigningError('The configured signing certificate is unavailable or invalid. '
                               'Restore its certificate and private key, or deliberately select another identity. '
                               'Refusing to silently switch identities or use ad hoc signing.')
        return configured

    local = [fingerprint for fingerprint, name in identities.items() if name == LOCAL_IDENTITY_NAME]
    if len(local) > 1:
        raise SigningError(f'Multiple valid certificates are named {LOCAL_IDENTITY_NAME!r}; '
                           'select one public fingerprint using BUFFER_CODE_SIGN_IDENTITY.')
    if local:
        # Pin the first selected certificate so a later replacement cannot
        # silently change the app identity and invalidate Keychain permission.
        try:
            config.parent.mkdir(parents=True, exist_ok=True)
            with config.open('x', encoding='ascii') as handle:
                handle.write(local[0] + '\n')
        except FileExistsError:
            # Another build may have pinned it concurrently. Re-check rather
            # than overwriting that decision.
            return choose_identity(output, mode, environment, config)
        except OSError as error:
            raise SigningError(f'Cannot persist public signing fingerprint in {config}') from error
        return local[0]

    if mode == 'synthetic' or environment.get('BUFFER_ALLOW_ADHOC_SIGNING') == '1':
        return '-'
    raise SigningError('Normal Buffer runs need a stable signing certificate to preserve Keychain permission. '
                       f'Create {LOCAL_IDENTITY_NAME!r} once in Keychain Access, or configure a valid certificate '
                       'fingerprint. See docs/local-signing.md. No app was stopped or launched.')


def resolve(mode, environment=None, config=CONFIG):
    environment = os.environ if environment is None else environment
    # Validate configured input before even enumerating public identities.
    configured_fingerprint(environment, config)
    try:
        result = subprocess.run(['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning'],
                                capture_output=True, text=True, timeout=15, check=True)
    except (OSError, subprocess.SubprocessError) as error:
        raise SigningError('Unable to enumerate valid public code-signing identities. '
                           'Refusing an unverified signing fallback.') from error
    return choose_identity(result.stdout, mode, environment, config)


def verify_normal_app(app, environment=None, config=CONFIG):
    """Check the existing artifact, including --skip-build / observation paths.

    A stable already-built app need not have its signing private key installed
    to run. If a fingerprint is pinned, require this artifact to use it.
    """
    environment = os.environ if environment is None else environment
    configured = configured_fingerprint(environment, config)
    try:
        subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)],
                       capture_output=True, text=True, timeout=15, check=True)
        details = subprocess.run(['/usr/bin/codesign', '-dv', '--verbose=4', str(app)],
                                 capture_output=True, text=True, timeout=15, check=True)
        output = details.stdout + '\n' + details.stderr
        if not any(line.startswith('Authority=') for line in output.splitlines()):
            if 'Signature=adhoc' in output and environment.get('BUFFER_ALLOW_ADHOC_SIGNING') == '1':
                return '-'
            raise SigningError('The built app is ad hoc signed and normal saved-source runs may repeat Keychain '
                               'permission dialogs. Build with a stable identity using scripts/build-and-run.sh. '
                               'BUFFER_ALLOW_ADHOC_SIGNING=1 is an explicit temporary opt-in.')
        if configured:
            requirement = f'certificate leaf = H"{configured}" and identifier "com.wattsjs.buffer"'
            subprocess.run(['/usr/bin/codesign', '--verify', '--strict', f'-R={requirement}', str(app)],
                           capture_output=True, text=True, timeout=15, check=True)
    except SigningError:
        raise
    except (OSError, subprocess.SubprocessError) as error:
        raise SigningError('The built app signature is invalid, unsigned, or differs from the configured certificate. '
                           'Rebuild with scripts/build-and-run.sh before a normal saved-source launch.') from error
    return configured or 'signed'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    operation = parser.add_mutually_exclusive_group(required=True)
    operation.add_argument('--mode', choices=['normal', 'synthetic'])
    operation.add_argument('--verify-app', type=pathlib.Path)
    args = parser.parse_args()
    try:
        selected = verify_normal_app(args.verify_app) if args.verify_app else resolve(args.mode)
    except SigningError as error:
        print(f'Local signing: {error}', file=sys.stderr)
        return 1
    if selected == '-':
        print('Local signing: ad hoc (saved-source normal runs require an explicit opt-in).', file=sys.stderr)
    else:
        print(f'Local signing: stable certificate {selected}.', file=sys.stderr)
    print(selected)
    return 0


if __name__ == '__main__':
    sys.exit(main())

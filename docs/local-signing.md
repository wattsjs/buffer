# Stable signing for unattended local Buffer development

Local ad hoc builds identify one exact binary. Rebuilding changes that identity,
so a previously accepted Keychain permission can no longer match. A persistent
code-signing certificate lets macOS recognize later builds as the same app.
Keeping the app in a different folder does not fix a changing signature. Apple
documents this behavior in its [code requirement reference](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/RequirementLang/RequirementLang.html)
and [Keychain tracking policy](https://developer.apple.com/library/archive/technotes/tn2206/_index.html).

## One-time setup on this Mac

An existing Apple Development identity works if its certificate **and private
key** are installed here. Configure its public fingerprint as described below.
Otherwise, Apple's [Certificate Assistant procedure](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Procedures/Procedures.html)
supports a local self-signed code-signing identity:

1. Open **Keychain Access** and choose **Certificate Assistant → Create a Certificate**.
2. Name it **Buffer Local Development**, choose **Self Signed Root** as the identity
   type, and choose **Code Signing** as the certificate type.
3. Select **Let me override defaults**, choose an appropriate validity period,
   continue with the default certificate fields, and save it in the login keychain.
4. Check the available public identities:

   ```bash
   security find-identity -v -p codesigning
   python3 scripts/local_signing.py --mode normal
   ```

The resolver finds that exact, unique certificate name and pins its public
SHA-1 fingerprint in the ignored `.local/code-sign-identity` file. Do not
regenerate the certificate for each build. If it is missing or ambiguous, the
resolver explains the problem and refuses to switch identities silently.

This procedure does not require making a root certificate globally trusted.
Apple explicitly supports self-signed certificates for stable Keychain app
identity. It is for local development; distribution still uses the existing
Developer ID release workflow.

On the first signed build, macOS may ask to let **codesign** use the certificate's
private key; approve that specific use when physically present. The first
normal launch under the new signature may also need **Always Allow** for
Buffer's existing provider-password items. These are separate permissions.
Do not grant every application access to provider passwords. The login keychain
must still be available; stable signing does not unlock a locked keychain.

## Explicitly selecting an existing identity

Copy its 40-character public fingerprint from `security find-identity`:

```bash
BUFFER_CODE_SIGN_IDENTITY=0123456789ABCDEF0123456789ABCDEF01234567 scripts/build-and-run.sh --verify
```

To persist an explicit selection, place that fingerprint alone on one line in
`.local/code-sign-identity`. This file contains no password or private key and is
never sourced as shell code. The environment variable takes precedence without
rewriting a saved fingerprint. Certificate names and the special identity `-`
are deliberately rejected as explicit configuration.

## Build and observe

```bash
scripts/build-and-run.sh --verify
scripts/bench.sh
python3 scripts/observe-session.py --seconds 60
```

Both local app build entrypoints reuse the pinned identity once available. The
Codex Run action and `script/build_and_run.sh` forward to the same normal entrypoint.
Normal Run resolves signing **before** stopping the existing local app, builds
with that identity, and verifies the resulting signature before launching.
Observation also verifies the actual existing app so a stale ad hoc build cannot
bypass the guard through a skipped build. Invalid or unsigned bundles fail.

Synthetic benchmarks skip saved source credentials and may use ad hoc signing
when no stable identity exists. Once an identity is configured, they also fail
if it is unavailable rather than overwriting a stable app with an ad hoc build.
Their existing `--skip-build`, `--compare`, and `--tolerance` options are preserved.

An intentional temporary normal ad hoc run requires explicit opt-in:

```bash
BUFFER_ALLOW_ADHOC_SIGNING=1 scripts/build-and-run.sh --verify
```

This opt-in permits the missing-identity fallback; it does not suppress Keychain
dialogs, override an unavailable configured certificate, or permit invalid
signatures. Avoid it for unattended saved-source use.

## Verify after setup

```bash
codesign -d -r- DerivedData/Build/Products/Debug/Buffer.app
python3 scripts/local_signing.py --verify-app DerivedData/Build/Products/Debug/Buffer.app
python3 scripts/test_local_signing.py
```

The designated requirement should use the signing certificate and app identifier
instead of only `cdhash`. After approving the signed app once, rebuild, rerun,
and confirm the requirement remains stable and the provider loads without a new
password-access prompt. This empirical check must be completed on the Mac after
certificate setup; resolver tests alone do not prove Keychain authorization.

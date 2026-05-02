# Agent Notes

## Deploying Buffer

Use the repository release scripts. A GitHub release by itself is not enough:
Sparkle only advertises a build after the `wattsjs/buffer-updates` appcast is
regenerated and pushed.

### Preflight

1. Confirm the working tree only contains changes intended for the release.
   Do not build from an unrelated dirty tree.

   ```sh
   git status --short --branch
   ```

2. Confirm the latest public release and tags before choosing the next version.

   ```sh
   git fetch origin --tags --force
   gh release list --repo wattsjs/buffer --limit 10
   git tag --sort=-v:refname | head
   ```

3. Confirm release credentials are available on the machine:

   - Developer ID Application certificate, usually in
     `~/Library/Keychains/buffer-signing.keychain-db`.
   - Notary profile `buffer-notary`.
   - Required tools: `gh`, `xcodebuild`, `xcrun`, `create-dmg`, `security`,
     `codesign`, `ditto`, `hdiutil`, and Sparkle's `generate_appcast` download
     cache managed by `scripts/release-sparkle.sh`.

### Standard Release

Run the full release entrypoint from a clean checkout on `main`.

```sh
./scripts/cut-release.sh 1.4.8
```

The script performs the release in this order:

1. Reads current Xcode build settings.
2. Updates `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in
   `Buffer.xcodeproj/project.pbxproj`.
3. Commits the version bump as `chore(release): cut <version> (<build>)`.
4. Pushes `main`.
5. Archives and exports a Developer ID build.
6. Notarizes and staples the app bundle.
7. Creates the Sparkle zip and installer DMG.
8. Notarizes and staples the DMG.
9. Regenerates and pushes `wattsjs/buffer-updates/appcast.xml`.
10. Creates the GitHub release with the DMG, zip, changelog, and checksums.

If only the build number should change, omit the marketing version:

```sh
./scripts/cut-release.sh
```

To append hand-written release notes to the generated changelog:

```sh
EXTRA_NOTES_FILE=/path/to/notes.md ./scripts/cut-release.sh 1.4.8
```

### Recovery

If the release is interrupted, do not immediately rerun the full command.
First check which side effects already happened.

```sh
pgrep -fl 'cut-release|release-sparkle|publish-github-release|xcodebuild|notarytool|create-dmg|generate_appcast' || true
git status --short --branch
git fetch origin --tags --force
gh release list --repo wattsjs/buffer --limit 5
find dist -maxdepth 2 -type f | sort | tail
```

Use the evidence to choose the narrowest recovery:

- If the version bump commit was not pushed, fix the local failure and rerun
  `./scripts/cut-release.sh <version>`.
- If the build artifacts exist but the GitHub release is missing, run
  `./scripts/publish-github-release.sh --skip-build` from the same clean
  checkout.
- If the GitHub release exists but Sparkle still shows the old build, rerun the
  Sparkle path and verify the appcast in `wattsjs/buffer-updates`.
- If local uncommitted user work is present, use a separate clean clone or
  worktree for the release instead of `--allow-dirty`, unless the dirty files
  are explicitly part of the release.

### Verification

After the script finishes, verify all public surfaces:

```sh
gh release view v<version>-build.<build> --repo wattsjs/buffer
gh api repos/wattsjs/buffer-updates/contents/appcast.xml --jq '.download_url'
curl -fsSL https://raw.githubusercontent.com/wattsjs/buffer-updates/main/appcast.xml | rg '<sparkle:version>|<sparkle:shortVersionString>|url='
spctl --assess --type open --context context:primary-signature -v "dist/Buffer-<version>-<build>/Buffer-<version>-<build>.dmg"
```

The release is complete only when the GitHub release exists, both artifacts are
uploaded, the DMG is accepted by Gatekeeper, and the Sparkle appcast advertises
the new build.

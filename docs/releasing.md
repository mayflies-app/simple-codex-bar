# Releasing

## Configuration

`VERSION` supplies the marketing version. The product is `SimpleCodexBar`, the bundle is `SimpleCodexBar.app` and the bundle identifier is `app.mayfiles.SimpleCodexBar`. A `--version` override applies to one build; update `VERSION` for a persistent change.

`macos-app.json` defines the release repository and cask token (`simplecodexbar`). Its `repository` value must match the GitHub repository running the release workflow. Verify that identity, version, resources and repository settings describe the source commit being released.

The manual workflow requires these GitHub Actions secrets:

| Secret | Purpose |
| --- | --- |
| `MACOS_CERTIFICATE` | Base64-encoded Developer ID certificate and private key in PKCS#12 format |
| `MACOS_CERTIFICATE_PASSWORD` | Password for the PKCS#12 file |
| `MACOS_SIGNING_IDENTITY` | Developer ID Application signing identity |
| `MACOS_TEAM_ID` | Signing team's Apple Team ID |
| `APPLE_NOTARIZATION_KEY_ID` | App Store Connect API key ID |
| `APPLE_NOTARIZATION_ISSUER_ID` | API key issuer ID |
| `APPLE_NOTARIZATION_PRIVATE_KEY` | API key private key |
| `HOMEBREW_TAP_TOKEN` | Token with access to update the distribution tap |

The workflow uses its GitHub token for app release assets. The notarization issuer ID and signing Team ID identify different credentials.

## Local Packaging

```sh
./scripts/app.py package
./scripts/app.py package --arch universal --sign developer-id
./scripts/app.py release --dry-run
```

Package defaults to Release, Universal and ad-hoc signing. `--arch native|arm64|x86_64|universal`, `--configuration`, `--build`, `--output` and `--sign auto|ad-hoc|developer-id` select explicit options. Output includes the app under `app/`, a DMG, JSON metadata and SHA-256 checksum. Staged output is verified before replacing the destination.

Developer ID packaging requires an available signing identity and Hardened Runtime. Signing reads `MACOS_SIGNING_IDENTITY`, `MACOS_TEAM_ID` and `CODE_SIGN_KEYCHAIN`. Local packaging validates signed artifacts without submitting notarization or publishing. `release --dry-run` displays the release plan.

## GitHub Actions Release

Use the **macOS release** workflow. It invokes the same `./scripts/app.py release` entrypoint. The version input defaults to `VERSION`; the workflow run number supplies the build number.

- `dry_run: true` previews the plan without building or remote writes.
- `dry_run: false`, `publish: false` builds one Universal package containing arm64 and x86_64, signs with Developer ID, submits its DMG for Apple notarization and staples the accepted result.
- `dry_run: false`, `publish: true` also publishes verified release assets and updates the Homebrew cask.

Authorize notarization and publication explicitly before selecting their execution modes. Publishing requires a clean source checkout. The workflow verifies the release version, source commit, signature, notarization, asset names and downloaded artifact checksums.

### Cache and Execution

Dry-run uses the `preview` job on `ubuntu-latest`, without credentials or build-cache access. Execution follows `preflight → package → notarize → publish → cask`, using the common `./scripts/app.py release --execute --stage <job>` entrypoint. `package` and `notarize` use GitHub-hosted `xcode-27` with Xcode 27; the other jobs use `ubuntu-latest`. Signing secrets are scoped to `package`, notarization secrets and Team ID to `notarize`, Contents write to `publish`, and `HOMEBREW_TAP_TOKEN` to `cask`. `publish=false` stops after notarization. A matching public version reuses verified public assets and skips rebuilding and notarization. Release runs are serialized and never cancel an in-progress execution.

Use **Re-run failed jobs** or re-run a failed job itself to reuse successful upstream work. Jobs download immutable inputs by the producer's artifact ID; the signed app travels in a tar archive preserving executable modes and symlinks. Notarization resumes a retained submission ID after checking the original DMG checksum. Draft publication verifies existing bytes and uploads only missing assets. Empty `starter` placeholders from failed uploads are removed only after all completed assets pass byte verification; an already published release is verified without further writes. Missing artifact IDs stop before download, without falling back to all artifacts. A cask retry only verifies public assets and updates the tap. Build cache saving completes in `package` even if a later job fails.

Keep workflow artifacts until completion. Expired inputs require a new run. If a prior notary execution has no retained submission ID, inspect Apple submission history before starting a new workflow run. Re-running all jobs can produce different signed bytes that cannot reuse the previous checkpoint. See [shared release retries](https://github.com/mayflies-app/homebrew-tap/blob/main/docs/homebrew.md#retry-a-failed-job) for recovery boundaries. Ordinary CI retains tests, bundle builds and release-plan checks.

Debug and Release compilation caches are separate. Keys include actual Xcode, SDK and Swift fingerprints, build configuration, dependency/configuration hashes and the source SHA; fallback stays within the same compiler and dependency prefix. Cache paths exclude `dist` and credentials. Pull requests restore only; successful branch pushes may save Debug caches within GitHub's branch scope. Release dispatches on the default branch may save Release caches. Release cache hits and packaging timings require an executed release; dry-run previews do not exercise the Release compilation cache.

Tracked-input timestamps are reused only when content hashes, modes and checkout paths match the saved cache. Changed inputs still rebuild. Ordinary regression scripts share SDK compiler modules inside the existing build cache; fixtures and test execution are created afresh.

## Homebrew Distribution

The app release workflow updates casks in [mayflies-app/homebrew-tap](https://github.com/mayflies-app/homebrew-tap). With publication enabled, it generates the `simplecodexbar` cask from the verified public Universal DMG and its SHA-256 checksum, with the macOS 14 minimum.

Use the workflow's cask update path for new versions; preserve the bytes and identity of already published releases. See the tap's [distribution guide](https://github.com/mayflies-app/homebrew-tap/blob/main/docs/homebrew.md) for tap permissions and promotion checks.

## Release Diagnostics

Release logs identify stages, failure kinds and external exit codes, with credential-safe
GitHub error annotations. See [shared release diagnostics](https://github.com/mayflies-app/homebrew-tap/blob/main/docs/homebrew.md#release-diagnostics)
for authentication, authorization, repository access, network, concurrency and validation errors.
Tap updates use `HOMEBREW_TAP_TOKEN`, separately from the app workflow token.

A tap failure after successful publication leaves the release assets published. Repair
the cask from those verified public assets; do not rebuild or replace the same version.
Only confirmed concurrent push rejection is rebased and retried.

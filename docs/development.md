# Development

## Requirements

Use Xcode 27 or later, macOS SDK 27 or later, Swift 6.4 or later and Python 3. The deployment minimum is macOS 14.0. Run commands from the repository root.

## Command-Line Workflow

```sh
./scripts/app.py build
./scripts/app.py run
./scripts/app.py test
./scripts/app.py package
./scripts/app.py release --dry-run
```

Build and Run default to Debug, the native architecture and automatic signing. The development bundle is `dist/dev/SimpleCodexBar.app`. Codex Run invokes `./scripts/app.py run`, which builds, normally stops the same development app and launches its replacement. Another running path with the same identity blocks Run; a failed build leaves the running app intact.

Pass app arguments after `--`; `./scripts/app.py run -- --demo` uses isolated demo accounts. `macos-app.json` declares identity, resources and build settings; `VERSION` supplies the marketing version. The CLI uses SwiftPM for builds and tests.

Package defaults to Release, Universal and ad-hoc signing under `dist/release/universal/`. See [Releasing](releasing.md) for signing and release options. Dry-run prints the release plan without building, launching or publishing.

Shared scripts, workflows, and declared design and localization helpers are maintained in `homebrew-tap/templates/macos-app`. The `shared` object in this repository's `macos-app.json` declares helper destinations relative to this repository. Update shared implementation in the tap, then run from the tap checkout root:

```sh
python3 -B scripts/sync_apps.py --check APP_CHECKOUT
python3 -B scripts/sync_apps.py --apply APP_CHECKOUT
```

Replace `APP_CHECKOUT` with this app's checkout directory; multiple explicit checkout arguments are accepted. The check is read-only; apply copies shared files. Review local and staged changes before applying and inspect the resulting diff. Checkouts can live in any directory: do not commit host-specific paths or a workspace layout. App configuration, translations, product behavior and targeted checks stay in this repository. Follow [Shared Maintenance](https://github.com/mayflies-app/homebrew-tap/tree/main/templates/macos-app#shared-maintenance) for validation scope.

## Xcode Workflow

Open `SimpleCodexBar.xcodeproj` and select the `SimpleCodexBar` scheme for Build, Run, Debug or Archive. The native app target consumes the local Swift package libraries. Xcode and the CLI use the same product identity and bundled resources.

Debug and Release use ad-hoc signing by default and do not require an Apple Developer team. Hardened Runtime remains enabled. For Developer ID distribution, explicitly select your signing identity and team in Xcode, or use the command-line and CI workflow in [Releasing](releasing.md).

## Product Checks

`./scripts/app.py test` runs Swift tests for credential ownership, storage, usage parsing, refresh scheduling, localization and failure recovery, followed by `Tests/Tools/test_http_fixtures.py` and `Tests/Tools/test_native_wrapper.py`. HTTP fixtures use loopback endpoints and fake credentials; native-wrapper contract checks use a fake app and helper without opening the GUI. `macos-app.json` lists these additional offline checks in `testScripts`.

For prebuilt native checks:

```sh
./scripts/app.py test --native --case localization \
  --app /Applications/SimpleCodexBar.app --output /private/tmp/simplecodexbar-localization
bash Tests/Tools/verify_native.sh --app "$PWD/dist/dev/SimpleCodexBar.app" \
  --output /private/tmp/simplecodexbar-appearance --case appearance
```

The product runner `Tests/Tools/verify_native.sh` supports `appearance`, `simulation`, `localization` and `shortcuts`; the common `./scripts/app.py test --native` entrypoint supports only `localization`. Add `--appearance standard` to the product runner for the fallback material. They use demo data and save reports, logs and screenshots. `Tests/Tools/verify.sh` builds a native fixture and exercises both appearance modes on a visible desktop. Prebuilt runners require an absolute app path and a new or empty output directory with a writable parent.

The `shortcuts` case queues CGEvent-backed native key events through AppKit and verifies Close Window (`⌘W`), the existing settings gear menu (`⌘,`), standard text editing (`⌘A/C/X/V/Z` and `⇧⌘Z`), and dialog cancellation/default actions. Settings remain a menu; there is no separate settings window. The fixture preserves the clipboard's captured formats and uses isolated accounts. It checks the panel's window scope and nonactivating configuration; it does not establish physical keyboard delivery from another foreground app.

Use `TestResults/` or a temporary directory for local results. Check real browser sign-in, login registration, permissions or live service responses separately when a change affects them; isolated fixtures cover their declared scenarios.

`tools/generate_icon.swift` generates the app icon. Product tools and test fixtures belong in `tools/` and `Tests/`; build and signing use the common CLI.

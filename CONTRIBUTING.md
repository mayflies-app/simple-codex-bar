# Contributing

Focused fixes, documentation improvements and reproducible reports are welcome. Discuss substantial product changes before implementing them.

## Setup

Use Xcode 27 or later, macOS SDK 27 or later, Swift 6.4 or later and Python 3. Follow [Development](docs/development.md) to build and run, [Localization](docs/localization.md) for interface text and [Releasing](docs/releasing.md) for packaging.

## Changes

Preserve read-only credential links, app-managed account ownership and account/workspace identity checks. Keep the last successful reading after partial failures; unavailable usage must remain distinct from zero usage.

Preserve the adaptive panel, its top-edge anchor, visible footer Quit and menu-bar accessory behavior. Use isolated demo data for native checks. Keep upstream attribution in [NOTICE.md](NOTICE.md) and [LICENSE](LICENSE).

Shared scripts, workflows, and declared design and localization helpers are maintained in `macos-app-tooling/templates/macos-app`. This repository declares its repository-relative helper destinations in the `shared` object of `macos-app.json`; app configuration, translations, product behavior and targeted checks belong here. Update shared implementation in macos-app-tooling and synchronize from its root with explicit app checkout arguments after reviewing local and staged changes. Do not commit host-specific paths or assume a workspace layout. See [Shared Maintenance](https://github.com/mayflies-app/macos-app-tooling/tree/main/templates/macos-app#shared-maintenance).

## Validation

Match validation to the change. For documentation only, check links, referenced paths and `git diff --check`; no app build or product test is needed. For executable changes, run `./scripts/app.py test` and the affected checks in [Development](docs/development.md). Build, package or inspect native UI only when the change affects those behaviors.

Reproduce a reported failure before fixing it, and add regression coverage where existing checks leave a meaningful gap. For native interaction changes, include fresh logs or screenshots from isolated fixtures.

Keep generated output, credentials, personal account data and signing material out of commits.

## Submission

Describe the user-visible problem, resulting behavior and validation performed. Reports should include the app version, macOS version, architecture and reproduction steps. Redact personal content and credentials.

For security reports, contact [nshcr](https://github.com/nshcr) without posting secrets publicly. Contributions use the [MIT license](LICENSE).

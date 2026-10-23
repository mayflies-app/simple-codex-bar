# Localization

## Supported Languages

Support Simplified Chinese (`zh-Hans`) and English (`en`). First launch selects the first supported language in macOS preference order, falling back to English. Language choices use their own names: **简体中文** and **English**.

## Runtime Behavior

Save an explicit selection immediately and update existing application windows, menus, notices, errors and accessibility labels without restarting. macOS permission dialogs use the system language independently. Missing translations fall back to English, then to the semantic key when neither language provides a value.

Preserve user-assigned account names and service-provided model or workspace names. Store app-generated notices and error text as semantic `LocalizedText` values so existing cards update when the language changes. Demo language changes use isolated preferences.

## Adding UI Copy

Runtime translations live in `Sources/CodexUsageCore/Resources/en.lproj/` and `zh-Hans.lproj/`, grouped into `Panel.strings`, `Dialogs.strings` and `Core.strings`. Root `Resources/en.lproj/` and `Resources/zh-Hans.lproj/` contain bundle display strings.

`LocalizationResources.swift` is shared source maintained in `macos-app-tooling/templates/macos-app/shared/LocalizationResources.swift`. It prefers the resource bundle embedded in the running app, using the SwiftPM module bundle only when needed. Language directory lookup is case insensitive for both SwiftPM and Xcode output; formatted messages use the selected language’s locale.

Add the same semantic key to both languages and keep format arguments aligned. Resolve text through `LanguageController` or `LocalizedText` using the appropriate table. Use shared terms **Interface Language / 界面语言** and **Launch at Login / 登录时启动**. Use `SimpleCodexBar` for product identity, **Simple Codex Bar** for the English display name and **Codex 用量** for the Chinese display name.

## Validation

Run `./scripts/app.py test` for language selection, persistence, semantic messages, resource key and format completeness, missing-translation fallback and formatted values. Run `./scripts/app.py test --native --case localization --app /Applications/SimpleCodexBar.app --output /private/tmp/simplecodexbar-localization` on a visible desktop to switch existing menus, cards and dialogs between languages, verify accessibility text and preserve account data.

The prebuilt runner uses isolated demo preferences and accounts, preserves production data and settings, and saves `manifest.json`, `localization-flow.json`, logs and screenshots. Use a new or empty absolute output directory with an existing writable parent. A native check does not build or replace the selected app.

For this case, the existing recorder reserves `fixture-data` inside the output and a preference suite derived from the output path. It removes those exact resources after its owned app process exits, including failure, timeout and interruption paths without a final flow report. The manifest records cleanup separately from the flow result.

Set `MACOS_LOCALIZATION_TEST_MODE=fail` to stop with a controlled failure after the real English interface and screenshot checks. Set it to `hold` to wait at that same checkpoint for the CLI timeout or Ctrl-C. Omit the variable for the normal flow. `localization-progress.json` records `stage: english-visible`, the selected language and the owned process ID before either fault mode begins. These fault runs must fail the flow while still completing isolated-resource cleanup. Appearance and simulation cases retain their existing behavior.

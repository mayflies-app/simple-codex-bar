# Third-party notices

Simple Codex Bar uses [CodexBar](https://github.com/steipete/CodexBar), licensed
under MIT, as a reference for Codex OAuth credential formats, authentication,
HTTP transport and subscription-usage parsing.

Copyright (c) 2026 Peter Steinberger (CodexBar reference implementation).
The upstream copyright attribution and MIT license text are retained in
[LICENSE](LICENSE). Both `LICENSE` and this notice are included in the app bundle.

Reference revisions:

- [`412de0700930997fb868a4cb4e3800c4743e13c2`](https://github.com/steipete/CodexBar/tree/412de0700930997fb868a4cb4e3800c4743e13c2)
- [`9699239f0ddc16777c84e5cc6116e526e9a4f71a`](https://github.com/steipete/CodexBar/tree/9699239f0ddc16777c84e5cc6116e526e9a4f71a)
- [`68f6f221a7c2cb3e51e0a4e09fd64e147decdc07`](https://github.com/steipete/CodexBar/tree/68f6f221a7c2cb3e51e0a4e09fd64e147decdc07) (read-only banked reset inventory endpoint, headers and response fields)

The reference modules are under `Sources/CodexBarCore/Providers/Codex/`, including
`CodexOAuthCredentials`, `CodexOAuthUsageFetcher`, `CodexTokenRefresher`,
`CodexAuthenticatedHTTPTransport`, `CodexRateWindowNormalizer`,
`CodexAdditionalRateLimitMapper`, `CodexSpendControlsMonthlyUsage` and
`CodexProviderDescriptor`. Banked reset inventory also references
`Sources/CodexBar/Providers/Codex/UsageStore+CodexResetCredits.swift` and the
upstream `CodexRateLimitResetCreditsTests` contract fixtures.

Simple Codex Bar is independently maintained and packaged. It does not bundle
CodexBar's other providers or third-party dependencies and is not affiliated
with OpenAI or the CodexBar project.

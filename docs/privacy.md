# Privacy

## Local Data

The default data directory is `~/Library/Application Support/SimpleCodexBar/`:

| Path | Contents |
| --- | --- |
| `accounts.json` | Names, identities, source paths, order and refresh preferences; no tokens |
| `usage-cache.json` | Latest successful readings; no tokens or usage history |
| `accounts/<UUID>/auth.json` | OAuth credentials for app-managed accounts |

Language, refresh settings, date display and the selected CLI path use macOS user defaults under `app.mayfiles.SimpleCodexBar`. Private directories use mode `0700` and files use `0600`. Writes use atomic replacement; a process lock prevents concurrent management of the same directory. Private operations reject symlinks and replacement of the opened root.

Credentials are plaintext local files. Other processes running as the same macOS user can read them. Treat backups as credential material and redact account data before sharing. The app does not log bearer tokens or HTTP response bodies.

### Credential ownership

Separate sign-ins use an isolated `CODEX_HOME` with file-based credentials. The app renews these credentials while preserving the normal CLI account. Reauthentication and renewed responses must match the original user and workspace. Local JWT decoding supplies identity and expiry hints; OpenAI's HTTPS services perform authentication.

Linked accounts store the path to an existing `auth.json`. The app rereads the source file without copying, changing, deleting or renewing it. Renew linked credentials through their owning Codex installation. Keychain-only credentials and API-key subscription accounts cannot be linked.

A normal quit waits for an in-flight credential renewal to store its result. Forced termination, power loss or a lost renewal response can require signing in again.

### Account removal

Removing an app-managed account deletes its saved credentials and cached reading. Removing a linked account deletes the link and reading while preserving the source file. Local removal leaves the OpenAI session active.

Quit before deleting the app or its data directory. Deleting the data directory removes all managed sign-ins.

## Network Access

Authenticated requests go directly to OpenAI:

| Endpoint | Purpose |
| --- | --- |
| `https://chatgpt.com/backend-api/wham/usage` | Subscription limits and credits |
| `https://chatgpt.com/backend-api/accounts/<accountId>/spend-controls/current-user/monthly-usage` | Optional workspace monthly-usage supplement |
| `https://auth.openai.com/oauth/token` | Renew app-managed credentials |

The HTTP session is ephemeral, stores no cookies or URL credentials and rejects redirects. Sign-in launches Codex CLI and its browser authentication flow. Usage endpoints are undocumented and may change. Missing usage stays unavailable; a failed optional supplement preserves the main reading.

The app has no telemetry or project-operated server. It does not read conversations, scan sessions or import browser cookies.

## Permissions

The app does not request Accessibility, Screen Recording or Full Disk Access. Launch at Login uses macOS Login Items and may require approval. System permission dialogs follow the macOS language independently of the app language.

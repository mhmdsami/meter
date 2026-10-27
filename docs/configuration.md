# Configuration

meter reads `~/.config/meter/config.json`. The file is created with a sample on
first run and is kept at mode `600`. There is no settings UI; edit the JSON and
restart (or wait for the next refresh).

```json
{
  "interval_minutes": 5,
  "providers": [
    { "type": "opencode", "name": "OpenCode" },
    { "type": "openrouter", "name": "OpenRouter" },
    { "type": "codex", "name": "Codex" },
    { "type": "claude", "name": "Claude" }
  ]
}
```

## Instances

Each entry in `providers` is an instance. `type` selects the fetcher and `name`
is the label shown in the menu. Names must be unique. Repeating a type is the
point: three `opencode` entries with different keys are three rows.

| field | meaning |
| --- | --- |
| `type` | provider type, e.g. `claude`, `codex`, `opencode`, `other` |
| `name` | unique label, also the default keychain slot |
| `enabled` | set to `false` to hide a row without deleting the entry |
| `key` | how to find the credential (see below) |
| `cookie` | browser cookie for OpenCode Zen balances |
| `interval_minutes` | per-instance refresh cadence |
| `options` | provider-specific settings |

`interval_minutes` on an instance overrides the global value. This is useful
for providers that rate-limit, like Claude. It gates network fetches only: the
app wakes every 60 seconds, while local log scans run only when a watched log
changed (plus a 30-minute reconcile).

## Keys

`key` has three forms:

- `"env:NAME"` reads an environment variable. launchd does not inherit your
  shell, so meter falls back to asking an interactive `zsh`; variables set in
  `~/.zshrc` work.
- `"auth:<id>"` reads opencode's credential store: the `credential` table in
  `~/.local/share/opencode/opencode.db` (opencode v2), falling back to
  `~/.local/share/opencode/auth.json` for older installs.
- Anything else names a keychain item, `meter/<value>`. If `key` is omitted,
  the slot is `meter/<name>`.

Seed a keychain slot:

```sh
security add-generic-password -s meter/OpenRouter -a "$USER" -w
```

Read it back (this may prompt once):

```sh
security find-generic-password -s meter/OpenRouter -w
```

Providers that reuse a CLI login (`codex`, `claude`, `antigravity`, `amp`,
`zed`) need no key.

## Provider options

`options` is a string map whose keys depend on the provider. Cloudflare is the
common case:

```json
{
  "type": "cloudflare",
  "name": "Cloudflare AI",
  "key": "env:CLOUDFLARE_AI_GATEWAY",
  "options": { "account_id": "abc123", "gateway_id": "my-gateway" }
}
```

`account_id` and `gateway_id` also fall back to `CLOUDFLARE_ACCOUNT_ID` and
`CLOUDFLARE_GATEWAY_ID`. If no gateway is set, meter asks the API and uses the
only one, or lists the choices in the error.

## OpenCode cookies

OpenCode's Zen balance comes from a web RPC that only accepts a browser
session. For a balance row, set `cookie` on the instance. Copy the `Cookie`
header from any request to `opencode.ai` in your browser's developer tools.
When the cookie expires the balance disappears quietly; the usage windows keep
working from the API key.

## Notifications

```json
{
  "notifications": { "enabled": true, "window_percent": 90, "daily_spend": 50 }
}
```

`window_percent` fires once per window cycle when usage crosses it.
`daily_spend` fires once per day when estimated spend exceeds it; omit it to
disable spend alerts. See [install.md](install.md) for the macOS permission.

## Rate limits

A `429` from any provider arms an automatic backoff that honors `Retry-After`
with a 60-second minimum. The instance keeps its last reading and skips cycles
until the window passes.

# meter

A macOS menu bar app that tracks AI usage and spend, with multiple named
instances of the same provider. Three OpenCode accounts show up as three
rows, not one.

The bar shows total estimated spend today. The dropdown lists one row per
instance: usage windows, reset countdowns, credit balances, and inline
errors. No settings window; you edit a JSON file.

Built with SwiftUI and SwiftPM. Zero third-party dependencies. macOS 14+.

## What it reads

| Provider | Data | Auth |
|---|---|---|
| OpenCode | Go plan windows (rolling/weekly/monthly), Zen credit balance | API key, or browser cookie for balance |
| OpenRouter | credit balance, daily spend, per-key spending cap | API key |
| Codex | session/weekly windows, today's cost from local session logs | reuses `~/.codex/auth.json`; falls back to `codex app-server` RPC when the token is stale |
| Claude | session/weekly windows, today's cost from local project logs | reuses Claude Code credentials |
| Antigravity | Gemini and Claude+GPT quota windows | local `agy` CLI, signed in |
| Amp | free-tier daily meter, subscription pools, credit balance | reuses `amp` CLI login, or an API key |
| Zed | edit-prediction usage, billing cycle | reuses Zed's keychain login |
| Vercel | today's cost from the `fx` AI Gateway log | reuses `~/.fx/usage.jsonl` |

Cost estimates price local token counts at public API rates from
models.dev, cached in `~/.cache/meter/models.json`. These are estimates
of what your subscription usage would cost at list price, not bills.
The scans cover every source on the machine: Codex rollout files
(including threads resumed across days and archived sessions), Claude
project logs plus Claude Desktop's embedded stores, opencode's database,
and the `fx` usage log. The AI Gateway
reports $0 for subscription-billed Codex models, so those are priced
from their logged tokens instead. OpenCode's local spend is attributed
to whichever account its `auth.json` currently holds. The dropdown also
sums the last 7 and 30 days from the same scans (sparkline included).
Historical days price at today's models.dev table, and OpenCode's past
days follow its currently active key. Instances with
nothing to show are hidden.

A few things it deliberately does not do: browser-cookie scraping for the
Codex or Claude web dashboards, notifications, charts, widgets. Claude
Org and OpenAI Admin cost reports need admin API keys, so they are not
included. OpenCode Zen balances have no API-key path yet; balance rows
can use a pasted session cookie.

## Install

```sh
./install.sh
```

This builds the release binary to `~/.local/bin/meter` and loads the
`app.meter.meter` LaunchAgent, which starts meter at login and restarts
it if it crashes.

On first run the script also creates a self-signed `meter codesign`
certificate and signs the binary with it on every build. This matters:
meter reuses credentials stored by other apps (Claude Code, Zed), and
keychain grants are bound to the app's code signature. Without a stable
signature, every rebuild would invalidate those grants and macOS would
re-prompt for keychain access. Expect one "Always Allow" per foreign
credential after the first install; after that, rebuilds are silent.

Check everything from a terminal instead of the menu:

```sh
meter --print
```

## Config

`~/.config/meter/config.json`, created with a sample on first run:

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

Each entry is an instance. `type` picks the fetcher, `name` is the label
and must be unique. Repeat a type as many times as you like.

The `key` field has three forms:

- `"env:NAME"` reads an environment variable. If launchd doesn't have it,
  meter asks your interactive shell, so variables in `~/.zshrc` work.
- `"auth:<id>"` reads one entry of `~/.local/share/opencode/auth.json`.
- Anything else names a keychain item, `meter/<value>`. Omit `key` and it
  uses `meter/<name>`.
- `"interval_minutes"` overrides the global refresh cadence for one
  instance (useful for providers that rate-limit, like Claude).

Seed a keychain slot like this:

```sh
security add-generic-password -s meter/OpenRouter -a $USER -w
```

Read one back (after a possible keychain prompt) with:

```sh
security find-generic-password -s meter/OpenRouter -w
```

API-key providers that reuse CLI credentials (codex, claude, antigravity,
amp, zed) need no key at all.

OpenCode Zen balances use a web RPC that only accepts a browser session,
so an instance needs a `cookie` field for its balance row to appear. Copy
the `Cookie:` header of any request to opencode.ai in your browser's dev
tools and paste it. The row disappears quietly when the cookie expires.

After editing config, quit and relaunch meter, or run:

```sh
launchctl kickstart -k gui/$(id -u)/app.meter.meter
```

A 429 from any provider arms an automatic backoff (honoring `Retry-After`,
minimum 60s): the instance keeps its last reading and skips cycles until
the window passes, instead of hammering the endpoint.

## Adding a provider

A provider is one file in `Sources/meter/Providers/` and one line in the
registry at the top of `Providers.swift`. A fetcher receives a configured
instance and returns an `InstanceReading`: usage windows with percentages
and reset dates, an optional balance note, and an optional today cost.
Errors are thrown; the menu shows them inline per instance.

Read `Providers/OpenRouter.swift` for the shortest complete example.
The tests in `Tests/MeterTests/` cover config decoding and window
formatting; add a fixture test for any parser you write.

## Development

```sh
swift build
swift test
.build/debug/meter --print
```

Swift 6 toolchain, Swift 5 language mode, macOS 14+. SQLite comes from the
system library, linked in `Package.swift`. Keys are read at refresh time
from the keychain, environment, or CLI credential files, and are cached in
memory per launch to avoid repeated keychain prompts.

## License

MIT. See [LICENSE](LICENSE).

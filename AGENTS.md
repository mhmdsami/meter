# AGENTS.md

Notes for anyone (human or agent) working in this repo.

## Commands

```sh
npm install                                            # biome + lefthook, installs git hooks
npm run gate                                           # lint + types + build + tests, all languages
npm run lint                                           # biome over dashboard + scripts
npm run smoke                                          # hit the deployed Worker
npm run deploy                                         # Cloudflare deploy (dashboard)
swift build --package-path menubar                     # debug build
swift test --package-path menubar                      # unit tests
swift build -c release --package-path menubar          # release build
menubar/.build/debug/meter --print                     # one refresh, table to stdout
./install.sh                                           # release build + LaunchAgent
launchctl kickstart -k gui/$(id -u)/app.meter.menubar   # restart the running agent

cd collector && cargo run -- --dry-run                 # scan this host, no push
cd dashboard && npm run dev                            # dashboard + D1 locally
cd dashboard && npm run db:migrate                     # apply D1 migrations
```

`npm run gate` is what pre-push and CI run. The collector leg skips itself
when cargo is not installed; CI has the toolchain, this Mac may not.
`npm run smoke` needs `SMOKE_URL` (the deployment or `http://localhost:3000`).

`--print` is the fastest way to exercise every enabled provider against
live credentials. Network and keychain state make integration flakier
than unit tests; treat parser tests as the source of truth.

## Gates

`lefthook.yml` wires two hooks: pre-commit runs `biome check` on staged
JS/TS/JSON, pre-push runs `npm run gate`. Hooks come from `npm install` at the
repo root; never `--no-verify` around them, fix the gate instead.

- **dashboard**: `biome check`, `tsc --noEmit`, `next build`.
- **menubar**: `swift build`, `swift test`.
- **collector**: `cargo fmt --check`, `cargo clippy -D warnings`, `cargo test`.

`.github/workflows/ci.yml` runs the same three legs on every PR and push.
`.github/workflows/deploy.yml` ships to Cloudflare on pushes to `main`:
typecheck, D1 migrations, `opennextjs-cloudflare deploy`, then `npm run smoke`.
It needs `CLOUDFLARE_API_TOKEN` (secret) and `CLOUDFLARE_ACCOUNT_ID`
(variable). Deploys to the dashboard are not run by hand.

## Layout

```
menubar/
  Package.swift
  Sources/meter/
    MeterApp.swift     @main, MenuBarExtra scene, accessory activation, bar title
    Store.swift        main-actor state: config, readings, summary, poll loop
    Config.swift       config model + decode, keychain/env/auth key resolution
    Keychain.swift     generic + internet-password reads, cached per launch
    HTTP.swift         URLSession helpers, error types, ISO date parsing
    Reading.swift      InstanceReading / UsageWindow models, aggregation
    Providers.swift    registry: type string -> fetcher, fan-out, summary spend
    Summary.swift      /api/summary client, daily buckets, offline cache
    Notifier.swift     threshold alerts (pure decision + UNUserNotificationCenter)
    SQLite.swift       thin readonly libsqlite3 wrapper (credential store)
    PrintMode.swift    --print / --json one-shot modes
    MenuView.swift     dropdown rows, bars, countdowns
    Providers/*.swift  one file per provider type (config `options` holds
                      provider-specific settings, e.g. Cloudflare account/gateway)
  Tests/MeterTests/    XCTest, no host app
collector/           Rust agent that scans every host (Cargo)
dashboard/           Next.js dashboard + ingest/summary APIs (Cloudflare Workers + D1)
docs/                user and development docs
install.sh           menubar build + app bundle + LaunchAgents (app + collector)
```

## Collection

The collector is the only code that scans logs or prices tokens. It runs on
every host, including the Mac, and pushes to the Worker. The menubar fetches
quotas and credits from providers and reads spend from `/api/summary`; it has
no scanners, no pricing table, and does not write the ledger.

## Conventions

- Swift 5 language mode under a Swift 6 toolchain. No strict-concurrency
  churn; the store is @MainActor, fetchers are nonisolated async.
- The menubar has no third-party dependencies. System frameworks only
  (libsqlite3 is linked in `menubar/Package.swift`). The collector and
  dashboard are separate projects with their own dependencies.
- Comments explain non-obvious constraints only (protocol quirks, stale
  file formats, why a fallback exists). Nothing else.
- Never write to credential files owned by CLIs (`~/.codex/auth.json`,
  Claude keychain items). Read-only, always.
- Secrets stay in the keychain, env, or CLI credential files. The config
  file holds references, not keys, and is chmod 600.
- The ledger (`~/.local/share/meter/usage.db`) is user data, not cache: rows
  are upserted by (day, provider), today is provisional and past days are
  final, and a failed ledger write must never block or fail the UI.
- install.sh packages `~/Applications/meter.app`, symlinks `~/.local/bin/meter`
  at its executable, and signs with `-i meter` so the keychain grants made
  before bundling keep matching.
- install.sh signs the binary with a stable self-signed `meter codesign`
  identity. Keychain ACLs key off that signature; stripping the codesign
  step makes every rebuild re-prompt for Claude/Zed credentials.

## Adding a provider

1. Create `menubar/Sources/meter/Providers/YourThing.swift` with a
   `static func fetch(_ instance: ProviderInstance) async throws -> InstanceReading`.
2. Register it in `Providers.all`.
3. Support a config key path if it needs credentials: `env:NAME`,
   `auth:<id>`, or keychain `meter/<name>` (see `Secrets.apiKey`).
4. Throw `ProviderError` for failures; the menu renders the message per
   instance. Return an empty reading rather than an error for "signed in
   but nothing to track" cases.
5. If spend comes from a local log scan, add a `LocalCostSource` in
   `Providers.swift` and decide which instance its device-wide total
   attaches to (`target`).
6. Add a fixture-based test for any parsing logic.

Instance semantics worth preserving: instances are user-named and
repeatable per type, keychain slots are `meter/<name>`, and readings that
carry no windows, balance, spend, or error are hidden from the menu.

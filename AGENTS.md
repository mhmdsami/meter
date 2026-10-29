# AGENTS.md

Notes for anyone (human or agent) working in this repo.

## Commands

```sh
swift build --package-path menubar                     # debug build
swift test --package-path menubar                      # unit tests
swift build -c release --package-path menubar          # release build
menubar/.build/debug/meter --print                     # one refresh, table to stdout
./install.sh                                           # release build + LaunchAgent
launchctl kickstart -k gui/$(id -u)/app.meter.meter   # restart the running agent

cd collector && cargo run -- --dry-run                 # scan this host, no push
cd dashboard && npm run dev                            # dashboard + D1 locally
cd dashboard && npm run db:migrate                      # apply D1 migrations
cd dashboard && npm run deploy                         # deploy the Worker
```

`--print` is the fastest way to exercise every enabled provider against
live credentials. Network and keychain state make integration flakier
than unit tests; treat parser tests as the source of truth.

## Layout

```
menubar/
  Package.swift
  Sources/meter/
    MeterApp.swift     @main, MenuBarExtra scene, accessory activation, bar title
    Store.swift        main-actor state: config, readings, poll loop
    Config.swift       config model + decode, keychain/env/auth key resolution
    Keychain.swift     generic + internet-password reads, cached per launch
    HTTP.swift         URLSession helpers, error types, ISO date parsing
    Reading.swift      InstanceReading / UsageWindow models, aggregation
    Providers.swift    registry: type string -> fetcher, fan-out, cost attachment
    CostScan.swift     today-$ scans: Codex rollouts + gateway codex usage,
                      Claude projects + Desktop stores, opencode.db, pi/OMP
                      sessions, fx gateway log
    Ledger.swift       writable sqlite: daily spend rows + quota snapshots
    Notifier.swift     threshold alerts (pure decision + UNUserNotificationCenter)
    Pricing.swift      models.dev price table, cached in ~/.cache/meter/models.json
    SQLite.swift       thin readonly libsqlite3 wrapper
    PrintMode.swift    --print / --json one-shot modes
    MenuView.swift     dropdown rows, bars, countdowns
    Providers/*.swift  one file per provider type (config `options` holds
                      provider-specific settings, e.g. Cloudflare account/gateway)
  Tests/MeterTests/    XCTest, no host app
collector/           Rust agent for remote hosts (Cargo)
dashboard/           Next.js dashboard + ingest/summary APIs (Cloudflare Workers + D1)
docs/                user and development docs
install.sh           menubar build + app bundle + LaunchAgent
```

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

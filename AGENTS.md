# AGENTS.md

Notes for anyone (human or agent) working in this repo.

## Commands

```sh
swift build                        # debug build
swift test                         # unit tests
swift build -c release             # release build
.build/debug/meter --print         # one refresh cycle, table to stdout, exit code 0
./install.sh                       # release build + LaunchAgent (app.meter.meter)
launchctl kickstart -k gui/$(id -u)/app.meter.meter   # restart the running agent
```

`--print` is the fastest way to exercise every enabled provider against
live credentials. Network and keychain state make integration flakier
than unit tests; treat parser tests as the source of truth.

## Layout

```
Sources/meter/
  MeterApp.swift     @main, MenuBarExtra scene, accessory activation, bar title
  Store.swift        main-actor state: config, readings, poll loop
  Config.swift       config model + decode, keychain/env/auth key resolution
  Keychain.swift     generic + internet-password reads, cached per launch
  HTTP.swift         URLSession helpers, error types, ISO date parsing
  Reading.swift      InstanceReading / UsageWindow models, aggregation
  Providers.swift    registry: type string -> fetcher, fan-out, cost attachment
   CostScan.swift     today-$ scans: Codex rollouts, Claude projects + Desktop
                      stores, opencode.db, pi/OMP sessions, fx usage log
   Pricing.swift      models.dev price table, cached in ~/.cache/meter/models.json
  SQLite.swift       thin readonly libsqlite3 wrapper
  PrintMode.swift    --print rendering
  MenuView.swift     dropdown rows, bars, countdowns
  Providers/*.swift  one file per provider type
Tests/MeterTests/    XCTest, no host app
```

## Conventions

- Swift 5 language mode under a Swift 6 toolchain. No strict-concurrency
  churn; the store is @MainActor, fetchers are nonisolated async.
- No third-party dependencies. System frameworks only (libsqlite3 is
  linked in Package.swift).
- Comments explain non-obvious constraints only (protocol quirks, stale
  file formats, why a fallback exists). Nothing else.
- Never write to credential files owned by CLIs (`~/.codex/auth.json`,
  Claude keychain items). Read-only, always.
- Secrets stay in the keychain, env, or CLI credential files. The config
  file holds references, not keys, and is chmod 600.
- install.sh signs the binary with a stable self-signed `meter codesign`
  identity. Keychain ACLs key off that signature; stripping the codesign
  step makes every rebuild re-prompt for Claude/Zed credentials.

## Adding a provider

1. Create `Sources/meter/Providers/YourThing.swift` with a
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

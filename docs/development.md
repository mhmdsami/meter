# Development

## Commands

```sh
swift build                     # debug build
swift test                      # unit tests (needs Xcode for XCTest)
swift build -c release
.build/debug/meter --print      # one refresh, table to stdout
.build/debug/meter --json       # same data as JSON
./install.sh                    # release build plus the app bundle and agent
```

`--print` is the quickest way to exercise every enabled provider against live
credentials. Network and keychain state make integration flakier than unit
tests, so treat the parser tests as the source of truth.

## Layout

```
Sources/meter/
  MeterApp.swift     menu bar item, popover, activation policy
  Store.swift        main-actor state: config, readings, poll loop
  Config.swift       config model and key resolution
  Keychain.swift     generic and internet-password reads
  HTTP.swift         URLSession helpers and error types
  Reading.swift      InstanceReading and UsageWindow
  Providers.swift    registry, fan-out, local cost attribution
  CostScan.swift     local log and database scans
  Ledger.swift       SQLite ledger writes and reads
  Dashboard.swift    static HTML from the ledger
  Notifier.swift     threshold alerts
  Pricing.swift      models.dev price table
  SQLite.swift       small read-only SQLite wrapper
  PrintMode.swift    --print / --json / --dashboard
  MenuView.swift     dropdown rows and bars
  Providers/*.swift  one file per provider type
Tests/MeterTests/    XCTest, no host app
```

Repository conventions live in [AGENTS.md](../AGENTS.md). The short version:
Swift 5 language mode under a Swift 6 toolchain, no third-party dependencies,
system frameworks only, and comments only where a constraint is not obvious.

## Adding a provider

1. Add `Sources/meter/Providers/YourThing.swift` with a
   `static func fetch(_ instance: ProviderInstance) async throws -> InstanceReading`.
2. Register it in `Providers.all`.
3. If it needs credentials, support `env:NAME`, `auth:<id>`, or a keychain slot
   `meter/<name>`; see `Secrets.apiKey` in `Config.swift`.
4. Throw `ProviderError` for failures. The menu shows the message per instance.
   Return an empty reading for "signed in, nothing to track".
5. If spend comes from a local log scan, add a `LocalCostSource` in
   `Providers.swift` and decide which instance its device-wide total attaches
   to.
6. Add a fixture-based test for any parsing logic.

`Providers/OpenRouter.swift` is the shortest complete example.

## Tests

`Tests/MeterTests/` has parser and ledger tests. They do not launch the app.
Add a fixture test for every new parser; that is what keeps provider quirks
from regressing.

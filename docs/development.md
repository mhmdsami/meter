# Development

## Commands

```sh
swift build --package-path menubar                     # debug build
swift test --package-path menubar                      # unit tests (needs Xcode for XCTest)
swift build -c release --package-path menubar
menubar/.build/debug/meter --print                     # one refresh, table to stdout
menubar/.build/debug/meter --json                      # same data as JSON
./install.sh                                           # release build plus the app bundle and agent
```

`--print` exercises every enabled provider against live credentials. Network
and keychain state make it flakier than the parser tests, which are the source
of truth.

## Layout

```
menubar/
  Package.swift
  Sources/meter/
  MeterApp.swift     menu bar item, popover, activation policy
  Store.swift        main-actor state: config, readings, poll loop
  Config.swift       config model and key resolution
  Keychain.swift     generic and internet-password reads
  HTTP.swift         URLSession helpers and error types
  Reading.swift      InstanceReading and UsageWindow
  Providers.swift    registry, fan-out, summary spend attachment
  Summary.swift      work summary client and cache
  Notifier.swift     threshold alerts
  SQLite.swift       small read-only SQLite wrapper
  PrintMode.swift    --print / --json
  MenuView.swift     dropdown rows and bars
  Providers/*.swift  one file per provider type
  Tests/MeterTests/    XCTest, no host app
collector/           Rust agent: scans a host, pushes rows to the Worker
dashboard/           Next.js dashboard + APIs on Cloudflare Workers/D1
```

Repository conventions live in [AGENTS.md](../AGENTS.md). The short version:
Swift 5 language mode under a Swift 6 toolchain, no third-party dependencies,
system frameworks only, and comments only where a constraint is not obvious.

## Adding a provider

1. Add `menubar/Sources/meter/Providers/YourThing.swift` with a
   `static func fetch(_ instance: ProviderInstance) async throws -> InstanceReading`.
2. Register it in `Providers.all`.
3. If it needs credentials, support `env:NAME`, `auth:<id>`, or a keychain slot
   `meter/<name>`; see `Secrets.apiKey` in `Config.swift`.
4. Throw `ProviderError` for failures. The menu shows the message per instance.
   Return an empty reading for "signed in, nothing to track".
5. Add a fixture-based test for any parsing logic.

`Providers/OpenRouter.swift` is the shortest complete example.

## Tests

`Tests/MeterTests/` has provider parsing and summary tests. They do not launch
the app. Log parsers live in the collector and are tested there with `cargo
test`.

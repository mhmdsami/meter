# meter

A macOS menu bar app for AI usage and spend. It tracks multiple named
instances of the same provider, so three OpenCode accounts are three rows,
not one.

The menu bar shows today's estimated spend. The dropdown lists one row per
instance: quota windows with reset countdowns, credit balances, today's
spend, and errors. There is no settings window; configuration is a JSON file.
A local SQLite ledger records daily totals and powers a static HTML dashboard.

SwiftUI and SwiftPM, no third-party dependencies, macOS 14 or later.

## Install

```sh
./install.sh
```

This builds `~/Applications/meter.app` and loads the `app.meter.meter`
LaunchAgent. The first run may ask for keychain access to credentials owned
by Claude Code or Zed; choose **Always Allow**.

Then edit `~/.config/meter/config.json` to choose your providers, and restart:

```sh
launchctl kickstart -k gui/$(id -u)/app.meter.meter
```

See [docs/install.md](docs/install.md) for the details.

## Command line

```sh
meter --print        # one refresh, table to stdout
meter --json         # the same data as JSON
meter --dashboard    # render the ledger as HTML and open it
meter --test-notify  # ask for notification permission and send a test
```

## Docs

- [Install](docs/install.md)
- [Configuration](docs/configuration.md)
- [Providers](docs/providers.md)
- [Usage data](docs/data.md)
- [Development](docs/development.md)

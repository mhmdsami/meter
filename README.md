# meter

AI usage tracking across machines, in three parts:

| component | what it is |
|---|---|
| [`menubar/`](menubar) | Swift macOS menu bar app: local scans, quota windows, balances, ledger |
| [`collector/`](collector) | Rust agent for remote hosts: scans their logs and pushes rows |
| [`dashboard/`](dashboard) | Next.js on Cloudflare Workers + D1: ingest API, summary API, Google-gated dashboard |

```
laptop (menubar) ──┐
                   ├─ POST /api/ingest → D1 → dashboard
server (collector) ┘        ↑
                      menubar GET /api/summary
```

Each host scans its own logs locally. The menubar and the collector push
`(host, day, provider, project, model, spent, tokens, source)` rows to the
Worker, which replaces each `(host, day, provider)` group atomically. The
dashboard reads D1; the menubar reads the summary API.

## Menubar

A macOS menu bar app for AI usage and spend. It tracks multiple named
instances of the same provider, so three OpenCode accounts are three rows,
not one.

The dropdown lists one row per instance: quota windows with reset countdowns,
credit balances, today's spend, and errors. There is no settings window;
configuration is `~/.config/meter/config.json`. A local SQLite ledger records
daily totals and powers the menubar's history.

```sh
./install.sh
```

This builds `~/Applications/meter.app` and loads the `app.meter.meter`
LaunchAgent. The first run may ask for keychain access to credentials owned by
Claude Code or Zed; choose **Always Allow**.

```sh
meter --print        # one refresh, table to stdout
meter --json         # the same data as JSON
meter --test-notify  # ask for notification permission and send a test
```

The **Dashboard** button in the menu opens the hosted dashboard.

SwiftUI and SwiftPM, no third-party dependencies, macOS 14 or later.

## Collector

Rust, no C toolchain required: SQLite reads use `python3`, HTTP uses `curl`.
Scans opencode, pi/OMP, and Claude Code on a remote host, then pushes to the
dashboard API.

```sh
cd collector
cargo build --release
./target/release/meter-collector --dry-run
```

Config: `~/.config/meter/collector.env`. See
[collector/README.md](collector/README.md) for the systemd timer.

## Dashboard

Next.js on Cloudflare Workers, D1 as the store.

```sh
cd dashboard
npm install
npx wrangler d1 create meter   # put the id in wrangler.jsonc
npm run db:migrate
npm run deploy
```

Secrets: `METER_TOKEN` (ingest + client bearer), `GOOGLE_CLIENT_ID` /
`GOOGLE_CLIENT_SECRET`, `BETTER_AUTH_SECRET`, `BETTER_AUTH_URL`, and
`ALLOWED_EMAILS`. The Google client must allow
`https://<worker-domain>/api/auth/callback/google`. See
[dashboard/README.md](dashboard/README.md).

The menubar only pushes its recent window, so older local history reaches D1
through a one-time backfill:

```sh
node dashboard/scripts/backfill-ledger.mjs \
  --db ~/.local/share/meter/usage.db --host <name> --days 400
```

## Gates and deploy

`npm install` at the repo root installs biome and lefthook and wires the git
hooks: pre-commit lints staged JS/TS/JSON, pre-push runs the full gate.

```sh
npm run gate     # biome + tsc + next build, swift build + test, cargo fmt/clippy/test
SMOKE_URL=https://<deployment> npm run smoke   # health, login, 401s, /preview is prod-only
```

`.github/workflows/ci.yml` runs the same legs on PRs. Pushes to `main` deploy
through `.github/workflows/deploy.yml` (typecheck, D1 migrations,
`opennextjs-cloudflare deploy`, smoke). It needs the `CLOUDFLARE_API_TOKEN`
secret and the `CLOUDFLARE_ACCOUNT_ID` variable.

## Docs

- [Install](docs/install.md)
- [Configuration](docs/configuration.md)
- [Providers](docs/providers.md)
- [Usage data](docs/data.md)
- [Development](docs/development.md)

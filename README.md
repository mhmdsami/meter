# meter

AI usage tracking across machines, in three parts:

| component | what it is |
|---|---|
| [`menubar/`](menubar) | Swift macOS menu bar app: quota windows, balances, and cross-host spend |
| [`collector/`](collector) | Rust agent for every host (macOS, Linux, Windows best effort): scans logs and pushes rows |
| [`dashboard/`](dashboard) | Next.js on Cloudflare Workers + D1: ingest API, summary API, Google-gated dashboard |

```
laptop (collector) ──┐
                     ├─ POST /api/ingest → D1 → dashboard
server (collector) ──┘        ↑
                    menubar GET /api/summary
```

The collector is the only thing that scans logs, and it runs on every host.
It pushes `(host, day, provider, project, model, spent, tokens, source)` rows
to the Worker, which replaces each `(host, day, provider)` group atomically.
The dashboard reads D1; the menubar reads the summary API and caches the last
response for offline use.

## Menubar

A macOS menu bar app for AI usage and spend. It tracks multiple named
instances of the same provider, so three OpenCode accounts are three rows,
not one.

The app does not scan logs. It fetches quota windows and credit balances from
each provider, reads spend from the Worker's summary API, and keeps the last
response on disk so an offline launch still shows numbers. There is no
settings window; configuration is `~/.config/meter/config.json`.

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
Scans Codex rollouts, Claude Code (including the Desktop stores), opencode,
pi/OMP, the Antigravity CLI, and the fx gateway log, then pushes to the API.
Runs on macOS, Linux, and Windows where those tools and `python3` exist.

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

The old local ledger can be imported once with
`dashboard/scripts/backfill-ledger.mjs`; the collector does not read it.

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

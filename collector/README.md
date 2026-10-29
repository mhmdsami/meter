# meter collector (Rust)

Scans local agent logs on a remote host and pushes usage rows to the meter
worker (`POST /api/ingest`). No inbound service, no database, no C toolchain:
SQLite reads shell out to `python3`, HTTP uses `curl`, everything else is pure
Rust.

## Config

`~/.config/meter/collector.env` (chmod 600):

```sh
METER_URL=https://meter.siamasdev.workers.dev
METER_TOKEN=<from the worker secrets>
METER_HOST=space
METER_DAYS=30
```

`METER_HOST` defaults to `/etc/hostname`; `METER_DAYS` defaults to 30 (the
ingest replaces whole day/provider groups, so a 30-day pass reconciles history
without double counting).

## Run

```sh
cargo build --release
./target/release/meter-collector --dry-run   # print rows, no push
./target/release/meter-collector
```

## Sources

- opencode `~/.local/share/opencode/opencode.db` (assistant messages; prices
  tokens when the CLI records no per-message cost, e.g. opencode 2.2+)
- pi / OMP `~/.pi/agent/sessions`, `~/.omp/agent/sessions`
- Claude Code `~/.claude/projects`, `~/.config/claude/projects`

Codex rollouts and the fx gateway log are not ported yet; add them in
`src/scan.rs` next to the existing parsers.

## systemd (user)

`~/.config/systemd/user/meter-collector.service`:

```ini
[Unit]
Description=meter collector

[Service]
Type=oneshot
EnvironmentFile=%h/.config/meter/collector.env
ExecStart=%h/.local/bin/meter-collector
```

`meter-collector.timer`:

```ini
[Unit]
Description=run the meter collector every 10 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=10min
Persistent=true

[Install]
WantedBy=timers.target
```

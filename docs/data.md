# Usage data

## The ledger

Every refresh writes to a SQLite database at
`~/.local/share/meter/usage.db`. It is user data, not a cache: keep it if you
reinstall.

| table | contents |
| --- | --- |
| `daily` | one row per day and provider: spend, source, final flag |
| `breakdown` | spend and tokens per day, provider, project, and model |
| `quota_snapshots` | every quota reading the app has seen, with reset times |
| `meta` | bookkeeping such as the backfill marker and notification keys |

Writes are upserts keyed by day, provider, and (for `breakdown`) project and
model, so a refresh cannot double-count. Past days are marked `final`; today is
provisional. The first run backfills 90 days from the local scans. Normal
refreshes rewrite only today and yesterday; the full 30-day window is
reconciled on launch, on a manual refresh, and every 30 minutes. The log pass
itself is event-driven — an FSEvents watcher on the log roots gates it, so an
idle app does no scanning at all. That keeps older rows stable when a log has
been pruned or edited by hand. Codex session discovery still reaches back 30
days, because a resumed thread appends today's usage to the rollout file created
on its first day.

The `source` column is `reported` when the provider's own billing supplied the
number (opencode, vercel) and `estimated` when it was priced from token counts
at list rates.

## Today and history in the menu

The menu's today total comes from the live scans, merged with the ledger for
the same day. The 7- and 30-day history is built the same way: per day, take
the larger of the ledger total and the sum of the scans. This keeps imported
or already-pruned history visible without double-counting the current scans.

## Dashboard

```sh
meter --dashboard
meter --dashboard --days 30
```

This renders the ledger to a self-contained HTML file at
`~/.local/share/meter/dashboard.html` and opens it. It has spend cards, daily
bars per provider, burn-rate estimates from recent quota snapshots, spend by
project and model, and a per-day table. The menu's Dashboard button does the
same thing.

The page is generated locally and has no network dependencies. Re-run the
command (or click the button) to refresh it.

## Files

| path | purpose |
| --- | --- |
| `~/.config/meter/config.json` | providers and settings |
| `~/.local/share/meter/usage.db` | the ledger |
| `~/.local/share/meter/dashboard.html` | last rendered dashboard |
| `~/.cache/meter/models.json` | models.dev price table |
| `~/.cache/meter/readings.json` | last readings, so the bar doesn't blank on launch |

Deleting `usage.db` loses history; the app will backfill what it can from the
logs that still exist. Deleting the cache only forces a fresh price fetch.

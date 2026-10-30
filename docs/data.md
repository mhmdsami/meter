# Usage data

## Where usage lives

The collector writes rows to the Worker, which stores them in D1 keyed by
`(host, day, provider, project, model)`. D1 is the only store the dashboard
and the menubar read.

`~/.local/share/meter/usage.db` is the old local ledger. Older builds wrote it
and the app no longer updates it; it stays as user data so nothing recorded
before the move is lost.

| legacy table | contents |
| --- | --- |
| `daily` | one row per day and provider: spend, source, final flag |
| `breakdown` | spend and tokens per day, provider, project, and model |
| `quota_snapshots` | every quota reading the app has seen, with reset times |
| `meta` | bookkeeping such as the backfill marker and notification keys |

Ingest replaces each `(host, day, provider)` group, so a re-scan cannot
double-count. The collector pushes a 30-day window every 10 minutes; a resumed
thread that writes into an older day is picked up by the next pass. Rows whose
day is outside the window are left untouched, so history already in D1 stays
put when local logs are pruned.

The `source` column is `reported` when the provider's own billing supplied the
number (vercel, and opencode when it records a per-message cost) and
`estimated` when the collector priced it from token counts at list rates.
opencode 2.2 stopped recording costs, so most of its spend is estimated from
tokens at that provider's rate, with reasoning tokens counted as output.

## Today and history in the menu

The menu's today total and its 7- and 30-day bars come from the summary API,
so they cover every host. The response is cached; without a network the menu
shows the last good numbers.

## Dashboard

The dashboard reads the same D1 store and signs in with Google. The menu's
Dashboard button opens it.

## Files

| path | purpose |
| --- | --- |
| `~/.config/meter/config.json` | providers and settings |
| `~/.local/share/meter/usage.db` | legacy ledger, no longer written |
| `~/.cache/meter/summary.json` | last summary response, for offline |
| `~/.cache/meter/models.json` | models.dev price table (collector) |
| `~/.cache/meter/readings.json` | last readings, so the bar doesn't blank on launch |

Deleting `usage.db` loses only the old local history. Deleting the cache
forces a fresh summary and price fetch.

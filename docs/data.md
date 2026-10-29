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
refreshes rewrite today and yesterday every 10 minutes; the full 30-day window
is reconciled every 6 hours, on launch, and on a manual refresh. Scans are
whole-file, so cadence — not window size — is what keeps them cheap. That also
keeps older rows stable when a log has been pruned or edited by hand. Codex
session discovery still reaches back 30 days, because a resumed thread appends
today's usage to the rollout file created on its first day.

The `source` column is `reported` when the provider's own billing supplied the
number (vercel) and `estimated` when it was priced from token counts at list
rates. opencode used to report a per-message cost; 2.2 stopped doing that, so
its spend is priced from tokens at that provider's rate (reasoning tokens count
as output) and marked `estimated`.

## Today and history in the menu

The menu's today total comes from the live scans, merged with the ledger for
the same day. The 7- and 30-day history is built the same way: per day, take
the larger of the ledger total and the sum of the scans. This keeps imported
or already-pruned history visible without double-counting the current scans.

## Dashboard

The dashboard is hosted at <https://meter.sam1.space>. It reads the Cloudflare
D1 store that the menubar and collector push to, so it shows every host, and
signs in with Google. The menu's Dashboard button opens it.

The local ledger still powers the menubar's today total, history bars, and
notifications; it no longer renders HTML.

## Files

| path | purpose |
| --- | --- |
| `~/.config/meter/config.json` | providers and settings |
| `~/.local/share/meter/usage.db` | the ledger |
| `~/.cache/meter/models.json` | models.dev price table |
| `~/.cache/meter/readings.json` | last readings, so the bar doesn't blank on launch |

Deleting `usage.db` loses history; the app will backfill what it can from the
logs that still exist. Deleting the cache only forces a fresh price fetch.

# Providers

Each provider has a `type` string. You can repeat a type as many times as you
like; every instance gets its own row.

| type | the row shows | credentials |
| --- | --- | --- |
| `opencode` | rolling, weekly, and monthly Go-plan windows; Zen credit balance | API key; cookie for the balance |
| `openrouter` | credit balance, today's spend | API key |
| `codex` | session and weekly windows, today's spend | `~/.codex/auth.json`, or the `codex app-server` RPC |
| `claude` | session and weekly windows, today's spend | Claude Code's keychain item |
| `antigravity` | Gemini and "Others" quota windows | local `agy` CLI login |
| `amp` | free-tier meter, subscription pools, credit balance, today's recorded cost | `amp` CLI login or API key |
| `zed` | edit-prediction usage, billing cycle | Zed's keychain login |
| `vercel` | paid AI Gateway spend from the `fx` log | `~/.fx/usage.jsonl` |
| `straitly` | key balance (`/v1/key`) | API key |
| `cloudflare` | requests, tokens, errors, billed cost, credit balance | API token plus account/gateway ids |
| `other` | catch-all for providers without a dedicated row | none |

`other` is special: it has no fetcher. It collects spend from pi and opencode
messages whose provider is not mapped to a row, and it hides itself while the
total is zero. The menu shows one aggregated "Others" row; the ledger and
dashboard keep the real provider and model.

## Where spend comes from

meter estimates spend from local logs, priced at public list rates from
[models.dev](https://models.dev). The price table is cached in
`~/.cache/meter/models.json` and refreshed daily. These are list-price
estimates of subscription usage, not provider invoices.

The scans cover:

- Codex rollout files, including threads resumed across days and archived
  sessions.
- Claude project logs, plus the project stores embedded in Claude Desktop.
- opencode's database (`session_message` / `session_v2` in v2).
- pi and OMP agent sessions.
- The `fx` AI Gateway usage log.

Attribution rules worth knowing:

- pi and opencode record a provider per message. Messages go to the matching
  row; anything unmapped goes to `other`.
- The AI Gateway reports `$0` for subscription-billed Codex models. Those
  generations are priced from their logged tokens and counted as Codex spend,
  leaving only what the gateway actually billed on the Vercel row.
- opencode's local spend follows whichever account its credential store
  currently holds.
- Rows whose source is the provider's own billing (`opencode`, `vercel`) are
  marked `reported`; everything else is `estimated`.

## What it doesn't do

- No browser-cookie scraping for the Codex or Claude web dashboards.
- No Anthropic Organization or OpenAI Admin cost reports; those need admin API
  keys and are not implemented.
- No widgets.

Notifications, the local ledger, and the HTML dashboard are included; see
[data.md](data.md) and [configuration.md](configuration.md).

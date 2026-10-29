# meter dashboard

Next.js dashboard + ingestion API on Cloudflare Workers, backed by D1.
Hosts push `(host, day, provider, project, model, spent, tokens, source)` rows;
the dashboard aggregates them in the browser.

- Production: <https://meter.sam1.space>
- Design system mirrors `ijra`: Tailwind 4, base-nova shadcn, Geist Mono +
  Instrument Serif, Recharts charts.
- Auth: Google via better-auth, restricted to `ALLOWED_EMAILS`.

## Setup

```sh
cd dashboard
npm install
npx wrangler d1 create meter          # put database_id in wrangler.jsonc
npm run db:migrate                    # 0001 usage rows + 0002 auth tables

npx wrangler secret put METER_TOKEN        # bearer for collectors / menubar
npx wrangler secret put GOOGLE_CLIENT_ID
npx wrangler secret put GOOGLE_CLIENT_SECRET
npx wrangler secret put BETTER_AUTH_SECRET # 32+ random bytes
npx wrangler secret put BETTER_AUTH_URL    # https://meter.sam1.space
npx wrangler secret put ALLOWED_EMAILS     # comma-separated Google emails

npm run deploy
```

The Google OAuth client must allow the redirect URI
`https://meter.sam1.space/api/auth/callback/google` (and
`http://localhost:3000/api/auth/callback/google` for `npm run dev`).

## Local development

Copy `.dev.vars.example` to `.dev.vars`, fill the same values, then `npm run dev`.

## API

- `POST /api/ingest` — `Authorization: Bearer $METER_TOKEN`, body
  `{ "host": "space", "rows": [...] }`. Rows are summed per
  `(host, day, provider, project, model)` and each `(host, day, provider)`
  group is replaced atomically.
- `GET /api/export?days=90&today=YYYY-MM-DD` — breakdown rows (session or bearer).
- `GET /api/summary?days=30&today=YYYY-MM-DD&exclude_host=…` — daily aggregates
  and today totals. `exclude_host` keeps the menubar from counting its own rows.
- `GET /api/health`.

The dashboard is Google-gated; the API accepts either the better-auth session
cookie or the bearer token (for the menubar/collector).

## Assets

`assets/icon.svg` and `assets/og.svg` are the sources; regenerate the committed
PNGs with `node scripts/generate-assets.mjs` (uses sharp).

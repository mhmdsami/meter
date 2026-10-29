#!/usr/bin/env node
// Push historical ledger rows to /api/ingest. The menubar only pushes its
// recent window, so old local history never reaches D1 without this.
//
//   node scripts/backfill-ledger.mjs --db ~/.local/share/meter/usage.db \
//     --url https://<worker-domain> --host <name> --days 90
//
// Token comes from --token or METER_TOKEN. Send one host per run: ingest
// replaces every (host, day, provider) group it receives, so rerunning is
// idempotent.

import { execFileSync } from "node:child_process";
import { parseArgs } from "node:util";

const { values } = parseArgs({
  options: {
    db: { type: "string" },
    url: { type: "string" },
    host: { type: "string" },
    days: { type: "string", default: "90" },
    token: { type: "string" },
    "dry-run": { type: "boolean", default: false },
  },
});

const db = values.db;
const url = (values.url ?? process.env.METER_URL ?? "").replace(/\/$/, "");
const host = values.host;
const days = Number(values.days);
if (!db || !host || !url) {
  console.error("usage: backfill-ledger.mjs --db <path> --host <name> --url <worker> [--days]");
  process.exit(64);
}

const token =
  values.token ??
  process.env.METER_TOKEN ??
  execFileSync("security", ["find-generic-password", "-s", "meter/collector", "-w"], {
    encoding: "utf8",
  }).trim();
if (!token) {
  console.error("no token: pass --token or METER_TOKEN");
  process.exit(64);
}

const sql = `
  SELECT day, provider, project, model, spent, tokens, source
  FROM breakdown
  WHERE day >= date('now', '-${Number.isInteger(days) ? days : 90} day')
  ORDER BY day, provider`;

const raw = execFileSync("sqlite3", ["-json", db, sql], { encoding: "utf8" });
const rows = raw.trim() ? JSON.parse(raw) : [];
if (rows.length === 0) {
  console.error("no rows to send");
  process.exit(1);
}

const byDay = new Map();
for (const row of rows) {
  const list = byDay.get(row.day) ?? [];
  list.push({
    day: row.day,
    provider: row.provider,
    project: row.project ?? "",
    model: row.model ?? "",
    spent: Number(row.spent ?? 0),
    tokens: Number(row.tokens ?? 0),
    source: row.source === "reported" ? "reported" : "estimated",
  });
  byDay.set(row.day, list);
}

const days_ = [...byDay.keys()].sort();
console.log(`${host}: ${rows.length} rows across ${days_.length} days (${days_[0]}..${days_.at(-1)})`);
if (values["dry-run"]) process.exit(0);

let sent = 0;
for (const day of days_) {
  const response = await fetch(`${url}/api/ingest`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
    body: JSON.stringify({ host, rows: byDay.get(day) }),
  });
  const body = await response.text();
  if (!response.ok) {
    console.error(`${day}: ${response.status} ${body}`);
    process.exit(1);
  }
  sent += byDay.get(day).length;
  console.log(`${day}: ${byDay.get(day).length} rows`);
}
console.log(`done: ${sent} rows -> ${url}`);

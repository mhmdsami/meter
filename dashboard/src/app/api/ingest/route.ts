import { bearerOk } from "@/lib/access";
import { db } from "@/lib/db";

export const dynamic = "force-dynamic";

type IncomingRow = Record<string, unknown>;

function bad(message: string) {
  return Response.json({ error: message }, { status: 400 });
}

export async function POST(request: Request) {
  if (!bearerOk(request)) return Response.json({ error: "unauthorized" }, { status: 401 });

  let payload: { host?: unknown; rows?: unknown };
  try {
    payload = await request.json();
  } catch {
    return bad("invalid json");
  }

  const host = typeof payload.host === "string" ? payload.host.trim() : "";
  if (!host || host.length > 64) return bad("bad host");
  if (!Array.isArray(payload.rows) || payload.rows.length > 50_000) return bad("bad rows");

  const now = new Date().toISOString();
  // Scans emit one row per log file; several files can share a key. Sum them
  // first (the ledger does the same) or the primary key rejects the insert.
  type Merged = {
    day: string;
    provider: string;
    project: string;
    model: string;
    spent: number;
    tokens: number;
    source: string;
  };
  const merged = new Map<string, Merged>();
  for (const raw of payload.rows as IncomingRow[]) {
    const day = String(raw.day ?? "");
    if (!/^\d{4}-\d{2}-\d{2}$/.test(day)) return bad("bad day");
    const provider = String(raw.provider ?? "").trim();
    if (!provider || provider.length > 64) return bad("bad provider");
    const spent = Number(raw.spent ?? 0);
    const tokens = Math.trunc(Number(raw.tokens ?? 0));
    if (!Number.isFinite(spent) || !Number.isFinite(tokens)) return bad("bad number");
    const project = String(raw.project ?? "").slice(0, 1024);
    const model = String(raw.model ?? "").slice(0, 256);
    const source = raw.source === "reported" ? "reported" : "estimated";
    const key = [day, provider, project, model].join("\u0000");
    const previous = merged.get(key);
    if (previous) {
      previous.spent += spent;
      previous.tokens += tokens;
      if (source === "reported") previous.source = "reported";
    } else {
      merged.set(key, { day, provider, project, model, spent, tokens, source });
    }
  }

  const groups = new Map<string, Array<[string, string, string, string, number, number, string]>>();
  for (const row of merged.values()) {
    const key = `${row.day}|${row.provider}`;
    const list = groups.get(key) ?? [];
    list.push([row.day, row.provider, row.project, row.model, row.spent, row.tokens, row.source]);
    groups.set(key, list);
  }

  try {
    const database = db();
    const statements: D1PreparedStatement[] = [];
    for (const list of groups.values()) {
      const [day, provider] = [list[0][0], list[0][1]];
      statements.push(
        database
          .prepare("DELETE FROM usage_rows WHERE host = ? AND day = ? AND provider = ?")
          .bind(host, day, provider),
      );
      for (const [d, p, project, model, spent, tokens, source] of list) {
        statements.push(
          database
            .prepare(
              `INSERT INTO usage_rows (host, day, provider, project, model, spent, tokens, source, updated_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
               ON CONFLICT(host, day, provider, project, model) DO UPDATE SET
                 spent = usage_rows.spent + excluded.spent,
                 tokens = usage_rows.tokens + excluded.tokens,
                 source = CASE WHEN excluded.source = 'reported' THEN 'reported' ELSE usage_rows.source END,
                 updated_at = excluded.updated_at`,
            )
            .bind(host, d, p, project, model, spent, tokens, source, now),
        );
      }
    }

    // One or two D1 batches, not one per provider-day: a 500-row push is a
    // single Worker invocation and every extra batch eats the subrequest budget.
    for (let i = 0; i < statements.length; i += 400) {
      await database.batch(statements.slice(i, i + 400));
    }

    return Response.json({
      ok: true,
      host,
      rows: statements.length - groups.size,
      days: [...new Set([...groups.values()].map((list) => list[0][0]))].sort(),
    });
  } catch (error) {
    return Response.json({ error: error instanceof Error ? error.message : String(error) }, { status: 500 });
  }
}

import { authed } from "@/lib/access";
import { env, localToday, MAX_DAYS, validDay } from "@/lib/db";

export const dynamic = "force-dynamic";

export async function GET(request: Request) {
  const url = new URL(request.url);
  if (!(await authed(request))) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }
  const days = Math.min(MAX_DAYS, Math.max(1, Number(url.searchParams.get("days") ?? 30) || 30));
  const today = validDay(url.searchParams.get("today")) ?? localToday();
  const since = new Date(`${today}T00:00:00Z`);
  since.setUTCDate(since.getUTCDate() - (days - 1));
  const start = since.toISOString().slice(0, 10);
  const excludeHost = url.searchParams.get("exclude_host");

  const { results } = await env()
    .DB.prepare(
      `SELECT day, host, provider, SUM(spent) AS spent, SUM(tokens) AS tokens
       FROM usage_rows
       WHERE day >= ? AND day <= ?${excludeHost ? " AND host != ?" : ""}
       GROUP BY day, host, provider
       ORDER BY day, host, provider`,
    )
    .bind(...(excludeHost ? [start, today, excludeHost] : [start, today]))
    .all<{ day: string; host: string; provider: string; spent: number; tokens: number }>();

  const rows = results ?? [];
  const todayByProvider: Record<string, number> = {};
  const todayByHost: Record<string, number> = {};
  for (const row of rows) {
    if (row.day !== today) continue;
    todayByProvider[row.provider] = (todayByProvider[row.provider] ?? 0) + row.spent;
    todayByHost[row.host] = (todayByHost[row.host] ?? 0) + row.spent;
  }

  return Response.json({
    generated_at: new Date().toISOString(),
    today,
    days,
    rows,
    today_by_provider: todayByProvider,
    today_by_host: todayByHost,
    today_total: Object.values(todayByProvider).reduce((a, b) => a + b, 0),
  });
}

import { db, env } from "@/lib/env";
import type { UsageRow } from "./types";
export { db, env };

export const MAX_DAYS = 366;

export function localToday(): string {
  const now = new Date();
  const y = now.getFullYear();
  const m = String(now.getMonth() + 1).padStart(2, "0");
  const d = String(now.getDate()).padStart(2, "0");
  return `${y}-${m}-${d}`;
}

export function dayBefore(day: string, days: number): string {
  const [y, m, d] = day.split("-").map(Number);
  const date = new Date(Date.UTC(y, m - 1, d));
  date.setUTCDate(date.getUTCDate() - days);
  return date.toISOString().slice(0, 10);
}

export function validDay(day: string | null): string | null {
  if (!day || !/^\d{4}-\d{2}-\d{2}$/.test(day)) return null;
  return day;
}

export async function fetchRows(days: number, today: string): Promise<UsageRow[]> {
  const since = dayBefore(today, days - 1);
  const { results } = await env()
    .DB.prepare(
      `SELECT host, day, provider, project, model, spent, tokens, source
       FROM usage_rows WHERE day >= ? AND day <= ?
       ORDER BY day, host, provider, project, model`,
    )
    .bind(since, today)
    .all<UsageRow>();
  return results ?? [];
}

import { authed } from "@/lib/access";
import { fetchRows, localToday, MAX_DAYS, validDay } from "@/lib/db";

export const dynamic = "force-dynamic";

export async function GET(request: Request) {
  const url = new URL(request.url);
  if (!(await authed(request))) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }
  const days = Math.min(MAX_DAYS, Math.max(1, Number(url.searchParams.get("days") ?? 30) || 30));
  const today = validDay(url.searchParams.get("today")) ?? localToday();
  const rows = await fetchRows(days, today);
  return Response.json({ generated_at: new Date().toISOString(), today, days, rows });
}

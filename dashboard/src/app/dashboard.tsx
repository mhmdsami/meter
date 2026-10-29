"use client";

import { LogOut } from "lucide-react";
import { useEffect, useId, useMemo, useState } from "react";
import { Area, AreaChart, CartesianGrid, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { authClient } from "@/lib/auth-client";
import { cn } from "@/lib/utils";

type Row = {
  host: string;
  day: string;
  provider: string;
  project: string;
  model: string;
  spent: number;
  tokens: number;
  source: string;
};

type User = { email: string; name: string; image: string | null };
type Bucket = { spent: number; tokens: number };

const RANGES = [1, 7, 30, 90] as const;
const PALETTE = ["#8fd6b4", "#8fb8ff", "#f3b56b", "#e79ac2", "#b9a5f5", "#7ed3c8", "#f29d9d", "#a7c7e7"];
const HOST_COLORS = ["#8fd6b4", "#8fb8ff", "#f3b56b", "#b9a5f5"];

// Collectors emit the tool that produced the usage ("claude", "codex"); the
// dashboard groups and labels by the company behind it. Keys stay untouched in
// D1 so old rows and future ingest both resolve here.
const PROVIDER_BRANDS: Record<string, { label: string; color: string }> = {
  claude: { label: "anthropic", color: "#d97757" },
  anthropic: { label: "anthropic", color: "#d97757" },
  codex: { label: "openai", color: "#10a37f" },
  openai: { label: "openai", color: "#10a37f" },
  opencode: { label: "opencode", color: "#cfcecd" },
};

const BRAND_COLORS = new Map(Object.values(PROVIDER_BRANDS).map((brand) => [brand.label, brand.color]));

function brandLabel(provider: string): string {
  return PROVIDER_BRANDS[provider.toLowerCase()]?.label ?? provider;
}

function withBrands(rows: Row[]): Row[] {
  return rows.map((row) => ({ ...row, provider: brandLabel(row.provider) }));
}

function dayString(offset = 0): string {
  const d = new Date();
  d.setDate(d.getDate() + offset);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

function shiftDay(day: string, offset: number): string {
  const [y, m, d] = day.split("-").map(Number);
  const date = new Date(Date.UTC(y, m - 1, d));
  date.setUTCDate(date.getUTCDate() + offset);
  return date.toISOString().slice(0, 10);
}

function money(n: number): string {
  return n.toLocaleString("en-US", { style: "currency", currency: "USD", maximumFractionDigits: 2 });
}

function compact(n: number): string {
  if (n >= 1e9) return `${(n / 1e9).toFixed(1)}B`;
  if (n >= 1e6) return `${(n / 1e6).toFixed(1)}M`;
  if (n >= 1e3) return `${(n / 1e3).toFixed(1)}K`;
  return String(Math.round(n));
}

function colorFor(name: string, palette: Map<string, string>): string {
  return palette.get(name) ?? PALETTE[0];
}

function pct(part: number, total: number): number {
  return total > 0 ? Math.round((part / total) * 100) : 0;
}

function add(map: Map<string, Bucket>, key: string, row: Row) {
  const bucket = map.get(key) ?? { spent: 0, tokens: 0 };
  bucket.spent += row.spent;
  bucket.tokens += row.tokens;
  map.set(key, bucket);
}

function ChartTooltip({ active, payload, label }: any) {
  if (!active || !payload?.length) return null;
  const total = payload.reduce((sum: number, item: any) => sum + (item.value ?? 0), 0);
  return (
    <div className="min-w-40 rounded-md border border-border bg-popover px-3 py-2 text-xs shadow-[var(--shadow-overlay)]">
      <div className="mb-1.5 font-medium">{label}</div>
      {payload.map((item: any) => (
        <div key={item.dataKey} className="flex items-center justify-between gap-5 text-muted-foreground">
          <span className="flex items-center gap-1.5">
            <span className="size-1.5 rounded-full" style={{ background: item.color }} />
            {item.dataKey}
          </span>
          <span className="tabular-nums text-foreground">{money(item.value ?? 0)}</span>
        </div>
      ))}
      <div className="mt-1.5 flex items-center justify-between gap-5 border-t border-border pt-1.5 text-foreground">
        <span>Total</span>
        <span className="tabular-nums">{money(total)}</span>
      </div>
    </div>
  );
}

function Spark({
  data,
  color,
  height = 40,
  fill = true,
}: {
  data: { value: number }[];
  color: string;
  height?: number;
  fill?: boolean;
}) {
  const raw = useId();
  const id = `spark-${raw.replace(/[^a-zA-Z0-9_-]/g, "")}`;
  return (
    <ResponsiveContainer width="100%" height={height}>
      <AreaChart data={data} margin={{ top: 2, right: 0, bottom: 0, left: 0 }}>
        <defs>
          <linearGradient id={id} x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor={color} stopOpacity={0.32} />
            <stop offset="100%" stopColor={color} stopOpacity={0} />
          </linearGradient>
        </defs>
        <Area
          type="monotone"
          dataKey="value"
          stroke={color}
          strokeWidth={1.5}
          fill={fill ? `url(#${id})` : "transparent"}
          isAnimationActive={false}
          dot={false}
        />
      </AreaChart>
    </ResponsiveContainer>
  );
}

function StatCard({
  label,
  value,
  sub,
  children,
  className,
  delay,
}: {
  label: string;
  value: string;
  sub?: string;
  children?: React.ReactNode;
  className?: string;
  delay: number;
}) {
  return (
    <div
      className={cn(
        "animate-fade-up flex flex-col justify-between gap-4 rounded-lg border border-border bg-card p-4 shadow-[var(--shadow-card)]",
        className,
      )}
      style={{ animationDelay: `${delay}ms` }}
    >
      <div>
        <div className="text-2xs uppercase tracking-[0.08em] text-muted-foreground">{label}</div>
        <div className="mt-2 text-2xl font-medium tabular-nums tracking-[-0.02em]">{value}</div>
        {sub ? <div className="mt-1 text-xs text-muted-foreground">{sub}</div> : null}
      </div>
      {children}
    </div>
  );
}

function Share({ value, total }: { value: number; total: number }) {
  const share = pct(value, total);
  return (
    <div className="flex items-center justify-end gap-2">
      <div className="hidden h-1.5 w-14 overflow-hidden rounded-full bg-surface-2 sm:block">
        <div className="h-full rounded-full bg-primary" style={{ width: `${share}%` }} />
      </div>
      <span className="w-8 text-right text-xs tabular-nums text-muted-foreground">{share}%</span>
    </div>
  );
}

export default function Dashboard({ user, demoRows }: { user: User; demoRows?: Row[] }) {
  const [rows, setRows] = useState<Row[]>(() => withBrands(demoRows ?? []));
  const [days, setDays] = useState<(typeof RANGES)[number]>(30);
  const [host, setHost] = useState("all");
  const [provider, setProvider] = useState("all");
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const today = dayString(0);

  useEffect(() => {
    if (demoRows) {
      setLoading(false);
      return;
    }
    let cancelled = false;
    setLoading(true);
    fetch(`/api/export?days=90&today=${today}`, { cache: "no-store" })
      .then(async (response) => {
        if (response.status === 401) {
          window.location.href = "/login";
          return null;
        }
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        return response.json();
      })
      .then((json) => {
        if (cancelled || !json) return;
        const data = json as { rows?: Row[] };
        setRows(withBrands(data.rows ?? []));
        setError(null);
      })
      .catch((err) => {
        if (!cancelled) setError(String(err));
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [today, demoRows]);

  const hosts = useMemo(() => [...new Set(rows.map((row) => row.host))].sort(), [rows]);
  const providers = useMemo(() => [...new Set(rows.map((row) => row.provider))].sort(), [rows]);
  const palette = useMemo(() => {
    const map = new Map<string, string>();
    let fallback = 0;
    for (const name of providers) {
      map.set(name, BRAND_COLORS.get(name) ?? PALETTE[fallback++ % PALETTE.length]);
    }
    return map;
  }, [providers]);

  // biome-ignore lint/complexity/useMathMinMax: compares ISO day strings, not numbers
  const latest = useMemo(() => rows.reduce((max, row) => (row.day > max ? row.day : max), today), [rows, today]);
  const todayKey = rows.some((row) => row.day === today) ? today : latest;
  const yesterdayKey = shiftDay(todayKey, -1);

  const inScope = useMemo(
    () =>
      rows.filter((row) => (host === "all" || row.host === host) && (provider === "all" || row.provider === provider)),
    [rows, host, provider],
  );

  const filtered = useMemo(() => {
    const since = dayString(-(days - 1));
    return inScope.filter((row) => row.day >= since);
  }, [inScope, days]);

  const todayRows = useMemo(() => inScope.filter((row) => row.day === todayKey), [inScope, todayKey]);
  const yesterdayRows = useMemo(() => inScope.filter((row) => row.day === yesterdayKey), [inScope, yesterdayKey]);

  const rangeTotal = filtered.reduce((sum, row) => sum + row.spent, 0);
  const rangeTokens = filtered.reduce((sum, row) => sum + row.tokens, 0);
  const todayTotal = todayRows.reduce((sum, row) => sum + row.spent, 0);
  const yesterdayTotal = yesterdayRows.reduce((sum, row) => sum + row.spent, 0);
  const delta = yesterdayTotal > 0 ? ((todayTotal - yesterdayTotal) / yesterdayTotal) * 100 : null;
  const last7 = inScope.filter((row) => row.day >= dayString(-6)).reduce((sum, row) => sum + row.spent, 0);

  const series = useMemo(() => {
    const byDay = new Map<string, Map<string, number>>();
    for (const row of filtered) {
      const map = byDay.get(row.day) ?? new Map<string, number>();
      map.set(row.provider, (map.get(row.provider) ?? 0) + row.spent);
      byDay.set(row.day, map);
    }
    return Array.from({ length: days }, (_, index) => {
      const day = dayString(-(days - 1 - index));
      const parts = byDay.get(day) ?? new Map<string, number>();
      const point: Record<string, number | string> = { day, label: day.slice(5) };
      let total = 0;
      for (const [name, value] of parts) {
        point[name] = value;
        total += value;
      }
      point.total = total;
      return point;
    });
  }, [filtered, days]);

  const providerTotals = useMemo(() => {
    const map = new Map<string, Bucket>();
    for (const row of filtered) add(map, row.provider, row);
    return map;
  }, [filtered]);

  const hostTotals = useMemo(() => {
    const map = new Map<string, Bucket>();
    for (const row of todayRows) add(map, row.host, row);
    if (map.size === 0) for (const row of filtered) add(map, row.host, row);
    return map;
  }, [todayRows, filtered]);

  const modelTotals = useMemo(() => {
    const map = new Map<string, Bucket>();
    for (const row of filtered) add(map, row.model || "(none)", row);
    return map;
  }, [filtered]);

  const projectTotals = useMemo(() => {
    const map = new Map<string, Bucket>();
    for (const row of filtered) add(map, row.project || "(none)", row);
    return map;
  }, [filtered]);

  const daily = useMemo(() => {
    const map = new Map<string, { spent: number; tokens: number; hosts: Map<string, number> }>();
    for (const row of filtered) {
      const entry = map.get(row.day) ?? { spent: 0, tokens: 0, hosts: new Map<string, number>() };
      entry.spent += row.spent;
      entry.tokens += row.tokens;
      entry.hosts.set(row.host, (entry.hosts.get(row.host) ?? 0) + row.spent);
      map.set(row.day, entry);
    }
    return [...map.entries()].sort((a, b) => (a[0] < b[0] ? 1 : -1));
  }, [filtered]);

  const providerList = useMemo(
    () => [...providerTotals.entries()].sort((a, b) => b[1].spent - a[1].spent),
    [providerTotals],
  );

  // 14-day trends stay independent of the selected range so the 1d view
  // still has context in the cards.
  const trend = useMemo(() => {
    const window = Array.from({ length: 14 }, (_, index) => dayString(-13 + index));
    const first = window[0];
    const totals = new Map<string, number>();
    const perProvider = new Map<string, Map<string, number>>();
    for (const row of inScope) {
      if (row.day < first) continue;
      totals.set(row.day, (totals.get(row.day) ?? 0) + row.spent);
      const map = perProvider.get(row.provider) ?? new Map<string, number>();
      map.set(row.day, (map.get(row.day) ?? 0) + row.spent);
      perProvider.set(row.provider, map);
    }
    return {
      total: window.map((day) => ({ value: totals.get(day) ?? 0 })),
      provider: (name: string) => window.map((day) => ({ value: perProvider.get(name)?.get(day) ?? 0 })),
    };
  }, [inScope]);

  async function signOut() {
    await authClient.signOut();
    window.location.href = "/login";
  }

  const initials = (user.name || user.email)
    .split(/[\s@._-]+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((part) => part[0]?.toUpperCase())
    .join("");

  return (
    <main className="mx-auto w-full max-w-6xl px-4 py-6 sm:px-6 lg:py-10">
      <header className="animate-fade-up flex flex-col gap-5 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <h1 className="font-display text-3xl tracking-tight">meter</h1>
          <p className="mt-1 text-xs text-muted-foreground">
            AI usage across {hosts.length || 0} machine{hosts.length === 1 ? "" : "s"}
            {loading ? " · syncing…" : ` · ${rows.length.toLocaleString()} rows`}
          </p>
        </div>
        <div className="flex items-center gap-2">
          <div className="flex items-center rounded-md border border-border p-0.5">
            {RANGES.map((value) => (
              <Button
                key={value}
                size="xs"
                variant={days === value ? "default" : "ghost"}
                onClick={() => setDays(value)}
              >
                {value}d
              </Button>
            ))}
          </div>
          <div className="hidden items-center gap-2 rounded-md border border-border py-1 pl-1 pr-2 sm:flex">
            <span className="grid size-6 place-items-center rounded-sm bg-surface-2 text-2xs font-medium">
              {initials}
            </span>
            <span className="max-w-40 truncate text-xs text-muted-foreground">{user.email}</span>
          </div>
          <Button variant="ghost" size="icon" onClick={signOut} title="Sign out">
            <LogOut />
          </Button>
        </div>
      </header>

      {error ? <p className="mt-4 text-xs text-destructive">{error}</p> : null}

      <section className="mt-6 grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <StatCard
          label="Today"
          value={money(todayTotal)}
          sub={delta === null ? todayKey : `${delta >= 0 ? "+" : ""}${delta.toFixed(0)}% vs yesterday`}
          className="sm:col-span-2"
          delay={0}
        >
          <div className="flex items-end justify-between gap-6">
            <div className="text-xs text-muted-foreground">
              {[...hostTotals.entries()]
                .sort((a, b) => b[1].spent - a[1].spent)
                .map(([name, bucket]) => `${name} ${money(bucket.spent)}`)
                .join(" · ") || "no rows yet"}
            </div>
            <div className="w-28 shrink-0">
              <Spark data={trend.total} color="var(--primary)" />
            </div>
          </div>
        </StatCard>
        <StatCard label="Last 7 days" value={money(last7)} sub="across all filtered hosts" delay={60} />
        <div className="grid grid-cols-2 gap-3 sm:col-span-2 lg:col-span-1 lg:grid-cols-2">
          <StatCard
            label={`Last ${days}d`}
            value={money(rangeTotal)}
            sub={`${filtered.length.toLocaleString()} rows`}
            delay={120}
          />
          <StatCard label="Tokens" value={compact(rangeTokens)} sub="input + output + cache" delay={180} />
        </div>
      </section>

      <section className="mt-5 flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
        <div className="flex items-center gap-1.5 overflow-x-auto pb-1 sm:pb-0">
          <span className="shrink-0 pr-1 text-2xs uppercase tracking-[0.08em] text-text-tertiary">Host</span>
          <Button size="xs" variant={host === "all" ? "secondary" : "ghost"} onClick={() => setHost("all")}>
            All
          </Button>
          {hosts.map((name, index) => (
            <Button key={name} size="xs" variant={host === name ? "secondary" : "ghost"} onClick={() => setHost(name)}>
              <span className="size-1.5 rounded-full" style={{ background: HOST_COLORS[index % HOST_COLORS.length] }} />
              {name}
            </Button>
          ))}
        </div>
        <div className="flex items-center gap-1.5 overflow-x-auto pb-1 sm:pb-0">
          <span className="shrink-0 pr-1 text-2xs uppercase tracking-[0.08em] text-text-tertiary">Provider</span>
          <Button size="xs" variant={provider === "all" ? "secondary" : "ghost"} onClick={() => setProvider("all")}>
            All
          </Button>
          {providers.map((name) => (
            <Button
              key={name}
              size="xs"
              variant={provider === name ? "secondary" : "ghost"}
              onClick={() => setProvider(name)}
            >
              <span className="size-1.5 rounded-full" style={{ background: colorFor(name, palette) }} />
              {name}
            </Button>
          ))}
        </div>
      </section>

      <section className="mt-4">
        <div className="animate-fade-up rounded-lg border border-border bg-card p-4 shadow-[var(--shadow-card)]">
          <div className="flex items-start justify-between gap-4">
            <div>
              <h2 className="text-sm font-medium">{days === 1 ? "Today by provider" : "Daily spend"}</h2>
              <p className="mt-0.5 text-xs text-muted-foreground">
                {days === 1 ? "Share of today's spend" : `Stacked by provider · last ${days} days`}
              </p>
            </div>
            {days === 1 ? null : (
              <div className="flex flex-wrap justify-end gap-x-3 gap-y-1">
                {providers.map((name) => (
                  <span key={name} className="flex items-center gap-1.5 text-2xs text-muted-foreground">
                    <span className="size-1.5 rounded-sm" style={{ background: colorFor(name, palette) }} />
                    {name}
                  </span>
                ))}
              </div>
            )}
          </div>
          {days === 1 ? (
            <div className="mt-8">
              <div className="flex h-10 w-full overflow-hidden rounded-md bg-surface-2">
                {providerList.map(([name, bucket]) => (
                  <div
                    key={name}
                    style={{ width: `${pct(bucket.spent, rangeTotal)}%`, background: colorFor(name, palette) }}
                    title={`${name} · ${money(bucket.spent)}`}
                  />
                ))}
              </div>
              <div className="mt-4 flex flex-wrap gap-x-5 gap-y-2 text-xs">
                {providerList.map(([name, bucket]) => (
                  <span key={name} className="flex items-center gap-1.5 text-muted-foreground">
                    <span className="size-2 rounded-sm" style={{ background: colorFor(name, palette) }} />
                    {name}
                    <span className="tabular-nums text-foreground">{money(bucket.spent)}</span>
                  </span>
                ))}
                {providerList.length === 0 ? <span className="text-muted-foreground">No spend today.</span> : null}
              </div>
            </div>
          ) : (
            <div className="mt-4 h-64 sm:h-72">
              <ResponsiveContainer width="100%" height="100%">
                <AreaChart data={series} margin={{ top: 4, right: 4, bottom: 0, left: -18 }}>
                  <defs>
                    {providers.map((name) => (
                      <linearGradient id={`fill-${name}`} key={name} x1="0" y1="0" x2="0" y2="1">
                        <stop offset="0%" stopColor={colorFor(name, palette)} stopOpacity={0.35} />
                        <stop offset="100%" stopColor={colorFor(name, palette)} stopOpacity={0.02} />
                      </linearGradient>
                    ))}
                  </defs>
                  <CartesianGrid stroke="var(--border)" strokeDasharray="3 3" vertical={false} />
                  <XAxis
                    dataKey="label"
                    tick={{ fill: "var(--text-secondary)", fontSize: 10 }}
                    tickLine={false}
                    axisLine={false}
                    minTickGap={24}
                  />
                  <YAxis
                    tick={{ fill: "var(--text-secondary)", fontSize: 10 }}
                    tickLine={false}
                    axisLine={false}
                    tickFormatter={(value) => `$${value}`}
                    width={54}
                  />
                  <Tooltip content={<ChartTooltip />} cursor={{ stroke: "var(--border)" }} />
                  {providers.map((name) => (
                    <Area
                      key={name}
                      type="monotone"
                      dataKey={name}
                      stackId="spend"
                      stroke={colorFor(name, palette)}
                      strokeWidth={1.5}
                      fill={`url(#fill-${name})`}
                      animationDuration={450}
                      animationEasing="ease-out"
                    />
                  ))}
                </AreaChart>
              </ResponsiveContainer>
            </div>
          )}
        </div>
      </section>

      <section className="mt-4 grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3">
        {providerList.map(([name, bucket], index) => {
          const color = colorFor(name, palette);
          const data = trend.provider(name);
          return (
            <div
              key={name}
              className="animate-fade-up rounded-lg border border-border bg-card p-4 shadow-[var(--shadow-card)] transition-colors hover:border-input/60"
              style={{ animationDelay: `${index * 45}ms` }}
            >
              <div className="flex items-center justify-between">
                <span className="flex items-center gap-2 text-sm font-medium">
                  <span className="size-2 rounded-full" style={{ background: color }} />
                  {name}
                </span>
                <span className="text-2xs tabular-nums text-muted-foreground">{pct(bucket.spent, rangeTotal)}%</span>
              </div>
              <div className="mt-3 flex items-end justify-between gap-3">
                <div>
                  <div className="text-xl font-medium tabular-nums">{money(bucket.spent)}</div>
                  <div className="mt-0.5 text-xs text-muted-foreground">{compact(bucket.tokens)} tokens</div>
                </div>
                <div className="w-24">
                  <Spark data={data} color={color} height={34} />
                </div>
              </div>
            </div>
          );
        })}
      </section>

      <section className="mt-4 grid grid-cols-1 gap-3 lg:grid-cols-2">
        {[
          { title: "By model", map: modelTotals },
          { title: "By project", map: projectTotals },
        ].map(({ title, map }, index) => {
          const rows = [...map.entries()].sort((a, b) => b[1].spent - a[1].spent).slice(0, 8);
          return (
            <div
              key={title}
              className="animate-fade-up rounded-lg border border-border bg-card p-4 shadow-[var(--shadow-card)]"
              style={{ animationDelay: `${index * 60}ms` }}
            >
              <h2 className="text-sm font-medium">{title}</h2>
              <div className="mt-3">
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead className="h-8 px-0 text-2xs uppercase tracking-[0.08em] text-text-tertiary">
                        {title.replace("By ", "")}
                      </TableHead>
                      <TableHead className="h-8 px-0 text-right text-2xs uppercase tracking-[0.08em] text-text-tertiary">
                        Spend
                      </TableHead>
                      <TableHead className="h-8 px-0 pl-4 text-right text-2xs uppercase tracking-[0.08em] text-text-tertiary">
                        Share
                      </TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {rows.map(([label, bucket]) => (
                      <TableRow key={label} className="border-border/60">
                        <TableCell className="px-0 py-2 text-xs">
                          <span className="block max-w-36 truncate sm:max-w-56" title={label}>
                            {label}
                          </span>
                        </TableCell>
                        <TableCell className="whitespace-nowrap px-0 py-2 text-right text-xs tabular-nums">
                          {money(bucket.spent)}
                        </TableCell>
                        <TableCell className="px-0 py-2 pl-4">
                          <Share value={bucket.spent} total={rangeTotal} />
                        </TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
                {rows.length === 0 ? (
                  <p className="mt-2 text-xs text-muted-foreground">No rows in this range.</p>
                ) : null}
              </div>
            </div>
          );
        })}
      </section>

      <section
        className="animate-fade-up mt-4 rounded-lg border border-border bg-card p-4 shadow-[var(--shadow-card)]"
        style={{ animationDelay: "120ms" }}
      >
        <div className="flex items-center justify-between">
          <h2 className="text-sm font-medium">Daily</h2>
          <span className="text-2xs text-muted-foreground">{daily.length} days</span>
        </div>
        <div className="mt-3">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead className="h-8 px-0 text-2xs uppercase tracking-[0.08em] text-text-tertiary">Day</TableHead>
                <TableHead className="h-8 px-0 text-right text-2xs uppercase tracking-[0.08em] text-text-tertiary">
                  Spend
                </TableHead>
                <TableHead className="hidden h-8 px-0 text-right text-2xs uppercase tracking-[0.08em] text-text-tertiary sm:table-cell">
                  Tokens
                </TableHead>
                <TableHead className="hidden h-8 px-0 text-2xs uppercase tracking-[0.08em] text-text-tertiary sm:table-cell">
                  Hosts
                </TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {daily.slice(0, 30).map(([day, entry]) => (
                <TableRow key={day} className="border-border/60">
                  <TableCell className="px-0 py-2 text-xs tabular-nums">
                    {day}
                    <div className="mt-1 flex flex-wrap gap-1 sm:hidden">
                      {[...entry.hosts.entries()]
                        .sort((a, b) => b[1] - a[1])
                        .map(([name, value], index) => (
                          <Badge key={name} variant="outline" className="gap-1.5 text-2xs">
                            <span
                              className="size-1.5 rounded-full"
                              style={{ background: HOST_COLORS[index % HOST_COLORS.length] }}
                            />
                            {name} {money(value)}
                          </Badge>
                        ))}
                    </div>
                  </TableCell>
                  <TableCell className="px-0 py-2 text-right text-xs tabular-nums">{money(entry.spent)}</TableCell>
                  <TableCell className="hidden px-0 py-2 text-right text-xs tabular-nums text-muted-foreground sm:table-cell">
                    {compact(entry.tokens)}
                  </TableCell>
                  <TableCell className="hidden px-0 py-2 sm:table-cell">
                    <div className="flex flex-wrap gap-1">
                      {[...entry.hosts.entries()]
                        .sort((a, b) => b[1] - a[1])
                        .map(([name, value], index) => (
                          <Badge key={name} variant="outline" className="gap-1.5">
                            <span
                              className="size-1.5 rounded-full"
                              style={{ background: HOST_COLORS[index % HOST_COLORS.length] }}
                            />
                            {name} {money(value)}
                          </Badge>
                        ))}
                    </div>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
          {daily.length === 0 && !loading ? (
            <div className="mt-6 rounded-md border border-dashed border-border p-6 text-center">
              <p className="text-sm">No usage yet.</p>
              <p className="mt-1 text-xs text-muted-foreground">
                Push rows from a host: <code className="rounded bg-surface-2 px-1.5 py-0.5">meter-collector</code> on
                space, or the menubar app on your Mac.
              </p>
            </div>
          ) : null}
        </div>
      </section>
    </main>
  );
}

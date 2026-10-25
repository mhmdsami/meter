import Foundation

/// Self-contained HTML dashboard rendered from the ledger. The rows are embedded
/// as JSON and the page filters/aggregates them in the browser, so it works
/// offline with no server and no dependencies.
enum Dashboard {
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/meter/dashboard.html")
    }

    static func writeAndOpen(days: Int) {
        let html = render(days: days)
        let url = defaultURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? html.data(using: .utf8)?.write(to: url, options: .atomic)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = [url.path]
        try? proc.run()
    }

    static func render(days: Int, ledger: Ledger = .shared, now: Date = Date()) -> String {
        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let today = cal.startOfDay(for: now)
        let span = max(1, days)
        guard let start = cal.date(byAdding: .day, value: -(span - 1), to: today) else { return "" }
        let from = fmt.string(from: start)
        let to = fmt.string(from: today)
        let iso = ISO8601DateFormatter()

        let daily: [[String: Any]] = ledger.days(from: from, to: to).map { row in
            ["day": row.day, "provider": row.provider, "account": row.account,
             "spent": row.spent, "source": row.source, "final": row.final ? 1 : 0]
        }
        let breakdown: [[String: Any]] = ledger.breakdownRows(from: from, to: to).map { row in
            ["day": row.day, "provider": row.provider, "project": row.project,
             "model": row.model, "spent": row.spent, "tokens": row.tokens]
        }
        let peaks = ledger.quotaPeaks(from: from)
        let limits: [[String: Any]] = ledger.currentQuotas().map { quota in
            let peak = peaks["\(quota.provider)|\(quota.windowID)"]
            return ["provider": quota.provider, "window": quota.windowID,
                    "used": quota.usedPercent.map { $0 as Any } ?? NSNull(),
                    "resets_at": quota.resetsAt.map { iso.string(from: $0) as Any } ?? NSNull(),
                    "captured_at": iso.string(from: quota.capturedAt),
                    "peak": peak.map { $0 as Any } ?? NSNull()]
        }
        let pace: [[String: Any]] = ledger.pace().map { p in
            ["provider": p.provider, "window": p.window, "used": p.usedPercent,
             "per_hour": p.perHour, "out_hours": p.outHours.map { $0 as Any } ?? NSNull()]
        }

        let payload: [String: Any] = [
            "generated_at": iso.string(from: now),
            "days": span,
            "from": from,
            "to": to,
            "daily": daily,
            "breakdown": breakdown,
            "limits": limits,
            "pace": pace,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        let json = (String(data: data, encoding: .utf8) ?? "{}")
            .replacingOccurrences(of: "</", with: "<\\/")
        return page(json: json)
    }

    private static func page(json: String) -> String {
        #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>meter</title>
<style>
  :root { color-scheme: light dark; --bg: Canvas; --fg: CanvasText; --muted: #888a; --line: #8883; --accent: #5b8def; }
  * { box-sizing: border-box; }
  body { font: 14px -apple-system, system-ui, sans-serif; margin: 0 auto; max-width: 1120px; padding: 26px 18px 64px; background: var(--bg); color: var(--fg); }
  header { display: flex; align-items: baseline; gap: 14px; flex-wrap: wrap; }
  h1 { font-size: 20px; margin: 0; }
  .muted { opacity: .55; }
  .spacer { flex: 1; }
  .seg { display: inline-flex; border: 1px solid var(--line); border-radius: 8px; overflow: hidden; }
  .seg button { border: 0; background: transparent; color: inherit; padding: 6px 12px; font: inherit; cursor: pointer; }
  .seg button.on { background: var(--accent); color: #fff; }
  .controls { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; margin: 16px 0 6px; }
  .chips { display: flex; gap: 6px; flex-wrap: wrap; }
  .chip { border: 1px solid #8886; background: transparent; color: inherit; border-radius: 999px;
          padding: 4px 10px; font: inherit; font-size: 12px; cursor: pointer; opacity: .55; }
  .chip.on { opacity: 1; background: #8882; border-color: #8888; }
  .chip.off { opacity: .35; border-style: dashed; text-decoration: line-through; }
  .chip.all { font-weight: 600; }
  .chip.all.on { background: #2f5fce; border-color: #2f5fce; color: #fff; opacity: 1; }
  .chip .dot { margin-right: 6px; }
  input[type=search] { background: transparent; color: inherit; border: 1px solid var(--line); border-radius: 8px; padding: 6px 10px; font: inherit; min-width: 220px; }
  .cards { display: flex; gap: 12px; flex-wrap: wrap; margin: 16px 0 4px; }
  .card { border: 1px solid var(--line); border-radius: 10px; padding: 10px 14px; min-width: 140px; }
  .card b { display: block; font-size: 20px; margin-top: 4px; }
  h2 { font-size: 14px; margin: 28px 0 8px; }
  .panel { border: 1px solid var(--line); border-radius: 10px; padding: 14px; }
  .chart { display: flex; align-items: flex-end; gap: 2px; height: 200px; }
  .col { flex: 1; display: flex; flex-direction: column-reverse; height: 100%; min-width: 2px; position: relative; }
  .col:hover { background: #8881; }
  .seg-bar { width: 100%; }
  .legend { display: flex; gap: 14px; flex-wrap: wrap; list-style: none; padding: 0; margin: 12px 0 0; font-size: 12px; }
  .legend li { cursor: pointer; user-select: none; }
  .legend li.off { opacity: .35; text-decoration: line-through; }
  .dot { display: inline-block; width: 9px; height: 9px; border-radius: 3px; margin-right: 6px; }
  .limits { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 12px; }
  .limit { border: 1px solid var(--line); border-radius: 10px; padding: 12px 14px; }
  .limit-head { display: flex; justify-content: space-between; align-items: baseline; gap: 8px; margin-bottom: 6px; }
  .limit-head b { font-size: 14px; }
  .limit-row { padding: 9px 0; border-top: 1px solid #8882; }
  .limit-row:first-of-type { border-top: 0; padding-top: 4px; }
  .limit-row-top { display: flex; justify-content: space-between; gap: 8px; align-items: baseline; }
  .limit-row .pct { font-size: 15px; font-weight: 600; }
  .track { height: 7px; border-radius: 4px; background: #8883; margin: 8px 0 6px; overflow: hidden; }
  .fill { height: 100%; border-radius: 4px; }
  .sub { display: flex; justify-content: space-between; gap: 8px; font-size: 12px; }
  .pager { display: flex; align-items: center; gap: 10px; margin-top: 10px; font-size: 12px; }
  .pager button:disabled { opacity: .3; cursor: default; }
  table { width: 100%; border-collapse: collapse; margin-top: 8px; font-size: 13px; }
  th, td { text-align: left; padding: 5px 8px; border-bottom: 1px solid var(--line); }
  th { cursor: pointer; user-select: none; white-space: nowrap; }
  th .arrow { opacity: .45; font-size: 10px; }
  .num { text-align: right; }
  .bar { height: 6px; border-radius: 3px; background: var(--accent); min-width: 1px; }
  button.link { border: 0; background: transparent; color: var(--accent); font: inherit; cursor: pointer; padding: 0; }
  #tip { position: fixed; z-index: 10; display: none; pointer-events: none; background: #111e; color: #fff; border-radius: 7px; padding: 6px 9px; font-size: 12px; line-height: 1.35; max-width: 280px; }
  .empty { padding: 22px; text-align: center; opacity: .55; }
  .tag { font-size: 11px; opacity: .55; }
</style>
</head>
<body>
<header>
  <h1>meter</h1>
  <span class="muted" id="generated"></span>
  <span class="spacer"></span>
  <div class="seg" id="range"></div>
</header>

<div class="controls">
  <div class="chips" id="providers"></div>
  <span class="spacer"></span>
  <input id="search" type="search" placeholder="Search model, project, day…">
</div>

<div class="cards" id="cards"></div>

<h2>Spend over time</h2>
<div class="panel">
  <div class="chart" id="spendChart"></div>
  <ul class="legend" id="spendLegend"></ul>
</div>

<h2>Limits</h2>
<div class="limits" id="limits"></div>

<h2>Usage</h2>
<div class="panel">
  <div class="seg" id="usageBy">
    <button data-by="model">By model</button>
    <button data-by="project">By project</button>
  </div>
  <table id="usageTable"></table>
</div>

<h2>Daily</h2>
<div class="panel">
  <div style="display:flex;align-items:center;gap:12px">
    <span class="muted">Raw rows</span>
    <span class="spacer"></span>
    <button class="link" id="csv">Download CSV</button>
  </div>
  <table id="dailyTable"></table>
  <div class="pager">
    <span class="muted" id="dailyCount"></span>
    <span class="spacer"></span>
    <button class="link" id="prevPage">← Prev</button>
    <span class="muted" id="dailyPage"></span>
    <button class="link" id="nextPage">Next →</button>
  </div>
</div>

<div id="tip"></div>

<script id="data" type="application/json">\#(json)</script>
<script>
const DATA = JSON.parse(document.getElementById("data").textContent);
const COLORS = ["#5b8def","#e0705f","#5fbf8f","#c98be0","#e0b35f","#7fd0e0","#b0b0b0"];
const RANGES = [7, 30, 90].filter(n => n <= DATA.days);
if (!RANGES.includes(DATA.days)) RANGES.push(DATA.days);
RANGES.sort((a, b) => a - b);

const state = {
  days: DATA.days, by: "model", hidden: new Set(), search: "",
  sortUsage: { key: "spent", dir: -1 }, sortDaily: { key: "day", dir: -1 },
  pageDaily: 1, pageSizeDaily: 25,
};

const pad = n => String(n).padStart(2, "0");
const key = d => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
const addDays = (day, delta) => {
  const d = new Date(day + "T12:00:00");
  d.setDate(d.getDate() + delta);
  return key(d);
};
const axis = n => {
  const out = [];
  for (let i = n - 1; i >= 0; i--) out.push(addDays(DATA.to, -i));
  return out;
};
const fromDay = () => addDays(DATA.to, -(state.days - 1));
const money = v => "$" + (v || 0).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const tokens = v => {
  v = v || 0;
  if (v >= 1e9) return (v / 1e9).toFixed(1) + "B";
  if (v >= 1e6) return (v / 1e6).toFixed(1) + "M";
  if (v >= 1e3) return (v / 1e3).toFixed(1) + "K";
  return String(v);
};
const colorFor = (p, i) => {
  const known = ["claude","codex","opencode","antigravity","openrouter","vercel","cloudflare","straitly","amp"];
  const k = known.indexOf(p);
  return COLORS[(k >= 0 ? k : i) % COLORS.length];
};
const short = label => {
  const parts = label.split("/").filter(Boolean);
  return parts.length <= 2 ? label : parts.slice(-2).join("/");
};
const countdown = iso => {
  const t = new Date(iso).getTime();
  if (isNaN(t)) return "—";
  const diff = t - Date.now();
  if (diff <= 0) return "reset";
  const m = Math.round(diff / 60000);
  if (m < 60) return `in ${m}m`;
  const h = Math.floor(m / 60), rm = m % 60;
  if (h < 24) return `in ${h}h ${rm}m`;
  return `in ${Math.floor(h / 24)}d ${h % 24}h`;
};
const esc = s => String(s ?? "").replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

const providers = () => [...new Set(DATA.daily.map(r => r.provider))].sort();
const visible = p => !state.hidden.has(p);
const inRange = r => r.day >= fromDay() && r.day <= DATA.to;
const matches = text => !state.search || String(text || "").toLowerCase().includes(state.search);

function renderAll() {
  renderHeader();
  renderUsageBy();
  renderProviders();
  renderCards();
  renderSpend();
  renderLimits();
  renderUsage();
  renderDaily();
}

function renderHeader() {
  const generated = DATA.generated_at
    ? " · generated " + new Date(DATA.generated_at).toLocaleString() : "";
  document.getElementById("generated").textContent = `${fromDay()} → ${DATA.to}${generated}`;
  document.getElementById("range").innerHTML = RANGES.map(n =>
    `<button data-days="${n}" class="${n === state.days ? "on" : ""}">${n}d</button>`).join("");
}

function renderUsageBy() {
  document.querySelectorAll("#usageBy button").forEach(b =>
    b.classList.toggle("on", b.dataset.by === state.by));
}

function renderProviders() {
  const all = providers();
  const chips = [`<button class="chip all ${state.hidden.size ? "" : "on"}" data-provider="__all">All</button>`]
    .concat(all.map((p, i) => `<button class="chip ${visible(p) ? "on" : "off"}" data-provider="${esc(p)}">` +
      `<span class="dot" style="background:${colorFor(p, i)}"></span>${esc(p)}</button>`));
  document.getElementById("providers").innerHTML = chips.join("");
}

function renderCards() {
  const rows = DATA.daily.filter(r => inRange(r) && visible(r.provider));
  const sum = n => {
    const days = axis(state.days).slice(-n);
    return rows.filter(r => days.includes(r.day)).reduce((a, r) => a + (r.spent || 0), 0);
  };
  document.getElementById("cards").innerHTML = [
    ["Today", sum(1)], [`Last ${Math.min(7, state.days)} days`, sum(7)], [`Last ${state.days} days`, sum(state.days)],
  ].map(([label, v]) => `<div class="card"><span class="muted">${label}</span><b>${money(v)}</b></div>`).join("");
}

function renderSpend() {
  const days = axis(state.days);
  const all = providers();
  const shown = all.filter(visible);
  const byDay = new Map();
  for (const r of DATA.daily) {
    if (!inRange(r) || !visible(r.provider)) continue;
    const d = byDay.get(r.day) || {};
    d[r.provider] = (d[r.provider] || 0) + (r.spent || 0);
    byDay.set(r.day, d);
  }
  const totals = days.map(day => Object.values(byDay.get(day) || {}).reduce((a, b) => a + b, 0));
  const max = Math.max(...totals, 0.01);
  document.getElementById("spendChart").innerHTML = days.map((day, i) => {
    const d = byDay.get(day) || {};
    const segs = shown.map(p => {
      const v = d[p] || 0;
      if (!v) return "";
      return `<div class="seg-bar" style="height:${(v / max) * 100}%;background:${colorFor(p, all.indexOf(p))}" ` +
        `data-tip="${day} · ${esc(p)} · ${money(v)}"></div>`;
    }).join("");
    return `<div class="col" data-tip="${day} · ${money(totals[i])}">${segs}</div>`;
  }).join("");

  const sums = all.map((p, i) => ({
    p, i, v: DATA.daily.filter(r => inRange(r) && r.provider === p).reduce((a, r) => a + (r.spent || 0), 0),
  })).sort((a, b) => b.v - a.v);
  const grand = sums.reduce((a, s) => a + s.v, 0) || 1;
  document.getElementById("spendLegend").innerHTML = sums.map(s =>
    `<li class="${visible(s.p) ? "" : "off"}" data-provider="${esc(s.p)}">` +
    `<span class="dot" style="background:${colorFor(s.p, s.i)}"></span><b>${esc(s.p)}</b> ${money(s.v)} ` +
    `<span class="muted">(${Math.round((s.v / grand) * 100)}%)</span></li>`).join("");
}

function renderLimits() {
  const pace = new Map((DATA.pace || []).map(p => [`${p.provider}|${p.window}`, p]));
  const rows = (DATA.limits || [])
    .filter(l => visible(l.provider) && (matches(l.provider) || matches(l.window)));
  const grouped = new Map();
  for (const l of rows) {
    if (!grouped.has(l.provider)) grouped.set(l.provider, []);
    grouped.get(l.provider).push(l);
  }
  const groups = [...grouped.entries()].map(([provider, windows]) => {
    windows.sort((a, b) => (b.used || 0) - (a.used || 0));
    return { provider, windows, top: Math.max(...windows.map(w => w.used || 0)) };
  }).sort((a, b) => b.top - a.top || a.provider.localeCompare(b.provider));

  const el = document.getElementById("limits");
  if (!groups.length) {
    el.innerHTML = `<div class="panel empty">No limit readings yet</div>`;
    return;
  }
  el.innerHTML = groups.map(g => `
    <div class="limit">
      <div class="limit-head"><b>${esc(g.provider)}</b>` +
      `<span class="muted">${g.windows.length} window${g.windows.length === 1 ? "" : "s"}</span></div>
      ${g.windows.map(l => {
        const used = l.used == null ? 0 : Math.max(0, Math.min(100, l.used));
        const color = used >= 90 ? "#e0705f" : used >= 70 ? "#e0b35f" : "#5fbf8f";
        const peak = l.peak == null ? "—" : `${Math.round(l.peak)}%`;
        const p = pace.get(`${l.provider}|${l.window}`);
        const rate = p ? (p.per_hour > 0 ? `+${p.per_hour.toFixed(1)}%/h` : "idle") : "";
        const out = p && p.out_hours != null ? ` · out ${p.out_hours.toFixed(1)}h` : "";
        const sub = [rate + out, `peak ${peak}`].filter(Boolean).join(" · ");
        return `<div class="limit-row">
          <div class="limit-row-top"><span>${esc(l.window)}</span>` +
          `<span class="pct">${l.used == null ? "—" : Math.round(l.used) + "%"}</span></div>
          <div class="track"><div class="fill" style="width:${used}%;background:${color}"></div></div>
          <div class="sub"><span class="muted">resets ${l.resets_at ? countdown(l.resets_at) : "—"}</span>` +
          `<span class="muted">${sub}</span></div>
        </div>`;
      }).join("")}
    </div>`).join("");
}

function sortRows(rows, sort) {
  return [...rows].sort((a, b) => {
    const x = a[sort.key], y = b[sort.key];
    if (typeof x === "number" || typeof y === "number") return ((x || 0) - (y || 0)) * sort.dir;
    return String(x || "").localeCompare(String(y || "")) * sort.dir;
  });
}

function usageRows() {
  const rows = DATA.breakdown.filter(r => inRange(r) && visible(r.provider) && matches(r[state.by]));
  const labels = new Map();
  for (const r of rows) {
    const label = r[state.by] || "";
    if (!label) continue;
    const cur = labels.get(label) || { label, spent: 0, tokens: 0, providers: new Set() };
    cur.spent += r.spent || 0;
    cur.tokens += r.tokens || 0;
    cur.providers.add(r.provider);
    labels.set(label, cur);
  }
  return sortRows([...labels.values()], state.sortUsage);
}

function renderUsage() {
  const list = usageRows();
  const top = Math.max(...list.map(v => v.spent), 0.01);
  const arrow = k => state.sortUsage.key === k ? `<span class="arrow">${state.sortUsage.dir > 0 ? "▲" : "▼"}</span>` : "";
  const head = `<thead><tr><th data-sort="label">${state.by === "model" ? "Model" : "Project"} ${arrow("label")}</th>` +
    `<th class="num" data-sort="spent">Spend ${arrow("spent")}</th>` +
    `<th class="num" data-sort="tokens">Tokens ${arrow("tokens")}</th><th>Share</th></tr></thead>`;
  const body = list.slice(0, 25).map(v =>
    `<tr><td title="${esc(v.label)}">${esc(short(v.label))} <span class="tag">${esc([...v.providers].join(" · "))}</span></td>` +
    `<td class="num">${money(v.spent)}</td><td class="num muted">${tokens(v.tokens)}</td>` +
    `<td style="width:180px"><div class="bar" style="width:${(v.spent / top) * 100}%"></div></td></tr>`).join("");
  document.getElementById("usageTable").innerHTML = head +
    (body ? `<tbody>${body}</tbody>` : `<tbody><tr><td colspan="4" class="muted">No usage</td></tr></tbody>`);
}

function dailyRows() {
  return DATA.daily.filter(r => inRange(r) && visible(r.provider) &&
    (matches(r.day) || matches(r.provider) || matches(r.account)));
}

function renderDaily() {
  const list = sortRows(dailyRows(), state.sortDaily);
  const pages = Math.max(1, Math.ceil(list.length / state.pageSizeDaily));
  state.pageDaily = Math.min(Math.max(1, state.pageDaily), pages);
  const start = (state.pageDaily - 1) * state.pageSizeDaily;
  const page = list.slice(start, start + state.pageSizeDaily);
  const arrow = k => state.sortDaily.key === k ? `<span class="arrow">${state.sortDaily.dir > 0 ? "▲" : "▼"}</span>` : "";
  const head = `<thead><tr><th data-sort="day">Day ${arrow("day")}</th><th data-sort="provider">Provider ${arrow("provider")}</th>` +
    `<th data-sort="account">Account ${arrow("account")}</th><th class="num" data-sort="spent">Spend ${arrow("spent")}</th>` +
    `<th data-sort="source">Source ${arrow("source")}</th></tr></thead>`;
  const body = page.map(r =>
    `<tr><td>${r.day}</td><td>${esc(r.provider)}</td><td class="muted">${esc(r.account)}</td>` +
    `<td class="num">${money(r.spent)}</td><td class="muted">${esc(r.source)}</td></tr>`).join("");
  document.getElementById("dailyTable").innerHTML = head +
    (body ? `<tbody>${body}</tbody>` : `<tbody><tr><td colspan="5" class="muted">No rows</td></tr></tbody>`);
  document.getElementById("dailyCount").textContent = `${list.length} row${list.length === 1 ? "" : "s"}`;
  document.getElementById("dailyPage").textContent = `page ${state.pageDaily} / ${pages}`;
  document.getElementById("prevPage").disabled = state.pageDaily <= 1;
  document.getElementById("nextPage").disabled = state.pageDaily >= pages;
}

function csvCell(value) {
  const s = String(value ?? "");
  return /[",\n]/.test(s) ? `"${s.replaceAll('"', '""')}"` : s;
}

function downloadCSV() {
  const rows = [["day", "provider", "account", "spent", "source", "final"]]
    .concat(sortRows(dailyRows(), state.sortDaily).map(r =>
      [r.day, r.provider, r.account, r.spent, r.source, r.final]));
  const csv = rows.map(cols => cols.map(csvCell).join(",")).join("\n");
  const blob = new Blob([csv + "\n"], { type: "text/csv" });
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = `meter-${fromDay()}-${DATA.to}.csv`;
  a.click();
  URL.revokeObjectURL(a.href);
}

const tip = document.getElementById("tip");
function showTip(text, ev) {
  tip.textContent = text;
  tip.style.display = "block";
  const x = Math.min(window.innerWidth - 300, ev.clientX + 12);
  const y = Math.min(window.innerHeight - 60, ev.clientY + 12);
  tip.style.left = x + "px";
  tip.style.top = y + "px";
}
function hideTip() { tip.style.display = "none"; }

document.addEventListener("mousemove", ev => {
  const el = ev.target.closest("[data-tip]");
  if (!el) { hideTip(); return; }
  showTip(el.dataset.tip, ev);
});

document.getElementById("range").addEventListener("click", e => {
  const b = e.target.closest("button");
  if (!b) return;
  state.days = Number(b.dataset.days);
  state.pageDaily = 1;
  renderAll();
});
document.getElementById("usageBy").addEventListener("click", e => {
  const b = e.target.closest("button");
  if (!b) return;
  state.by = b.dataset.by;
  renderUsageBy();
  renderUsage();
});
document.getElementById("providers").addEventListener("click", e => {
  const b = e.target.closest("[data-provider]");
  if (!b) return;
  const p = b.dataset.provider;
  if (p === "__all") state.hidden.clear();
  else if (state.hidden.has(p)) state.hidden.delete(p);
  else state.hidden.add(p);
  state.pageDaily = 1;
  renderAll();
});
document.getElementById("spendLegend").addEventListener("click", e => {
  const li = e.target.closest("[data-provider]");
  if (!li) return;
  const p = li.dataset.provider;
  if (state.hidden.has(p)) state.hidden.delete(p); else state.hidden.add(p);
  state.pageDaily = 1;
  renderAll();
});
document.getElementById("search").addEventListener("input", e => {
  state.search = e.target.value.trim().toLowerCase();
  state.pageDaily = 1;
  renderLimits();
  renderUsage();
  renderDaily();
});
document.getElementById("usageTable").addEventListener("click", e => {
  const th = e.target.closest("th[data-sort]");
  if (!th) return;
  const k = th.dataset.sort;
  state.sortUsage = { key: k, dir: state.sortUsage.key === k ? -state.sortUsage.dir : -1 };
  renderUsage();
});
document.getElementById("dailyTable").addEventListener("click", e => {
  const th = e.target.closest("th[data-sort]");
  if (!th) return;
  const k = th.dataset.sort;
  state.sortDaily = { key: k, dir: state.sortDaily.key === k ? -state.sortDaily.dir : (k === "day" ? -1 : 1) };
  state.pageDaily = 1;
  renderDaily();
});
document.getElementById("prevPage").addEventListener("click", () => {
  if (state.pageDaily > 1) { state.pageDaily--; renderDaily(); }
});
document.getElementById("nextPage").addEventListener("click", () => {
  state.pageDaily++;
  renderDaily();
});
document.getElementById("csv").addEventListener("click", downloadCSV);

renderAll();
</script>
</body>
</html>
"""#
    }
}

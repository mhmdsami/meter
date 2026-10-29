#!/usr/bin/env node
// Post-deploy smoke check. Defaults to production; point it elsewhere with
// SMOKE_URL=http://localhost:3000.
const base = (process.env.SMOKE_URL ?? "https://meter.sam1.space").replace(/\/$/, "");

const checks = [
  { path: "/api/health", status: 200 },
  { path: "/login", status: 200, contains: "Continue with Google" },
  { path: "/preview", status: 404 },
  { path: "/api/export", status: 401 },
  { path: "/api/ingest", method: "POST", body: "{}", status: 401 },
];

async function check({ path, status, method = "GET", body, contains }) {
  const deadline = Date.now() + 45_000;
  let last = "no response";
  while (Date.now() < deadline) {
    try {
      const response = await fetch(`${base}${path}`, {
        method,
        body,
        redirect: "manual",
        headers: body ? { "content-type": "application/json" } : undefined,
        signal: AbortSignal.timeout(10_000),
      });
      const text = await response.text();
      if (response.status === status && (!contains || text.includes(contains))) {
        console.log(`smoke: ${method} ${path} ${response.status} ok`);
        return;
      }
      last = `status ${response.status}${contains && !text.includes(contains) ? `, missing ${JSON.stringify(contains)}` : ""}`;
    } catch (error) {
      last = String(error);
    }
    await new Promise((resolve) => setTimeout(resolve, 2_000));
  }
  throw new Error(`${method} ${path}: expected ${status}, got ${last}`);
}

for (const entry of checks) await check(entry);
console.log(`smoke: ${base} ok`);

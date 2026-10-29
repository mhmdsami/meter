import { notFound } from "next/navigation";
import Dashboard from "../dashboard";

export const dynamic = "force-dynamic";

function rows() {
  const out = [] as Array<Record<string, unknown>>;
  const providers = ["claude", "codex", "opencode"] as const;
  const projects = ["~/dev/payload", "~/dev/meter", "~/dev/rex"];
  const models: Record<string, string> = {
    claude: "claude-sonnet-4-6",
    codex: "gpt-5.2",
    opencode: "deepseek-v4.1-flash",
  };
  for (let offset = 29; offset >= 0; offset--) {
    const day = new Date();
    day.setDate(day.getDate() - offset);
    const key = `${day.getFullYear()}-${String(day.getMonth() + 1).padStart(2, "0")}-${String(day.getDate()).padStart(2, "0")}`;
    for (const [index, provider] of providers.entries()) {
      const base = provider === "claude" ? 1.1 : provider === "codex" ? 0.18 : 0.22;
      const wave = 0.55 + Math.sin((offset + index) / 3) * 0.35;
      out.push({
        host: index === 2 ? "space" : "mac",
        day: key,
        provider,
        project: projects[(offset + index) % projects.length],
        model: models[provider],
        spent: Number((base * wave).toFixed(4)),
        tokens: Math.round(800_000 * wave + index * 120_000),
        source: "estimated",
      });
    }
  }
  return out;
}

export default function Preview() {
  if (process.env.NODE_ENV === "production") notFound();
  return (
    <Dashboard
      user={{ email: "srmf2025@gmail.com", name: "Sami", image: null }}
      demoRows={rows() as never}
    />
  );
}

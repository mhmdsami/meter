import { getCloudflareContext } from "@opennextjs/cloudflare";

export interface Env {
  DB: D1Database;
  METER_TOKEN?: string;
  METER_INGEST_TOKEN?: string;
  METER_READ_TOKEN?: string;
  INGEST_RATE?: { limit(options: { key: string }): Promise<{ success: boolean }> };
  BETTER_AUTH_SECRET?: string;
  BETTER_AUTH_URL?: string;
  GOOGLE_CLIENT_ID?: string;
  GOOGLE_CLIENT_SECRET?: string;
  ALLOWED_EMAILS?: string;
}

export function env(): Env {
  return getCloudflareContext().env as unknown as Env;
}

export function db(): D1Database {
  return env().DB;
}

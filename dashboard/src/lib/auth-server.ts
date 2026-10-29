import { betterAuth } from "better-auth";
import { drizzleAdapter } from "better-auth/adapters/drizzle";
import { APIError } from "better-auth/api";
import { drizzle } from "drizzle-orm/d1";
import { env } from "@/lib/env";
import { allowedEmails, isAllowed } from "@/lib/allowlist";
import * as schema from "@/db/schema";

export function googleConfigured(): boolean {
  const e = env();
  return !!e.GOOGLE_CLIENT_ID?.endsWith(".apps.googleusercontent.com")
    && !!e.GOOGLE_CLIENT_SECRET
    && !e.GOOGLE_CLIENT_SECRET.startsWith("local-");
}

export function auth() {
  const e = env();
  const database = drizzle(e.DB, { schema });
  return betterAuth({
    baseURL: e.BETTER_AUTH_URL,
    secret: e.BETTER_AUTH_SECRET,
    database: drizzleAdapter(database, { provider: "sqlite", schema }),
    socialProviders: googleConfigured()
      ? {
          google: {
            clientId: e.GOOGLE_CLIENT_ID!,
            clientSecret: e.GOOGLE_CLIENT_SECRET!,
            scope: ["openid", "email", "profile"],
          },
        }
      : undefined,
    databaseHooks: {
      user: {
        create: {
          before: async (newUser) => {
            if (!isAllowed(newUser.email, allowedEmails())) {
              throw new APIError("FORBIDDEN", { message: "This account is not allowed to sign in." });
            }
            return { data: newUser };
          },
        },
      },
      session: {
        create: {
          before: async (newSession) => {
            const row = await e.DB.prepare("SELECT email FROM user WHERE id = ?")
              .bind(newSession.userId)
              .first<{ email: string }>();
            if (!isAllowed(row?.email, allowedEmails())) {
              throw new APIError("FORBIDDEN", { message: "This account is not allowed to sign in." });
            }
            return { data: newSession };
          },
        },
      },
    },
  });
}

import { env } from "@/lib/env";

export function parseList(value?: string | null): string[] {
  return (value ?? "")
    .split(",")
    .map((part) => part.trim().toLowerCase())
    .filter(Boolean);
}

export function isAllowed(email: string | null | undefined, allowed: string[]): boolean {
  return !!email && allowed.includes(email.trim().toLowerCase());
}

/** Session-time gate so removing an email revokes existing sessions too. */
export function allowedEmails(): string[] {
  return parseList(env().ALLOWED_EMAILS);
}

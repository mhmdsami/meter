import { auth } from "@/lib/auth-server";
import { env } from "@/lib/env";

/// Constant-time comparison: a plain `===` leaks how much of the token
/// matched, which is enough to reconstruct it byte by byte.
function sameSecret(candidate: string, expected: string): boolean {
  const enc = new TextEncoder();
  const a = enc.encode(candidate);
  const b = enc.encode(expected);
  if (a.byteLength !== b.byteLength) return false;
  let diff = 0;
  for (let i = 0; i < a.byteLength; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

export function bearerOk(request: Request): boolean {
  const token = env().METER_TOKEN;
  if (!token) return false;
  const header = request.headers.get("Authorization") ?? "";
  return sameSecret(header, `Bearer ${token}`);
}

export async function sessionOk(request: Request): Promise<boolean> {
  const session = await auth().api.getSession({ headers: request.headers });
  return !!session;
}

export async function authed(request: Request): Promise<boolean> {
  return bearerOk(request) || (await sessionOk(request));
}

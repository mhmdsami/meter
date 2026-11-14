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

function headerTokenMatches(request: Request, token: string | undefined): boolean {
  if (!token) return false;
  const header = request.headers.get("Authorization") ?? "";
  return sameSecret(header, `Bearer ${token}`);
}

/// Machines that push rows. Kept separate from read tokens so a leaked ingest
/// token cannot pull the whole ledger out of /api/export.
export function ingestOk(request: Request): boolean {
  const e = env();
  return headerTokenMatches(request, e.METER_INGEST_TOKEN ?? e.METER_TOKEN);
}

/// Machines and sessions that read aggregates.
export function readOk(request: Request): boolean {
  const e = env();
  return headerTokenMatches(request, e.METER_READ_TOKEN ?? e.METER_TOKEN);
}

export async function sessionOk(request: Request): Promise<boolean> {
  const session = await auth().api.getSession({ headers: request.headers });
  return !!session;
}

export async function authed(request: Request): Promise<boolean> {
  return readOk(request) || (await sessionOk(request));
}

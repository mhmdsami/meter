import { auth } from "@/lib/auth-server";
import { env } from "@/lib/env";

export function bearerOk(request: Request): boolean {
  const token = env().METER_TOKEN;
  if (!token) return false;
  return request.headers.get("Authorization") === `Bearer ${token}`;
}

export async function sessionOk(request: Request): Promise<boolean> {
  const session = await auth().api.getSession({ headers: request.headers });
  return !!session;
}

export async function authed(request: Request): Promise<boolean> {
  return bearerOk(request) || (await sessionOk(request));
}

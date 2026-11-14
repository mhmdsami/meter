import { NextResponse } from "next/server";

// Cloudflare serves the custom domain over both schemes, so a client that uses
// http:// would send the ingest bearer token in clear text. Redirect before any
// handler runs and keep the scheme enforced for a year.
export function middleware(request: Request) {
  const proto = request.headers.get("x-forwarded-proto");
  if (proto === "http") {
    const url = new URL(request.url);
    url.protocol = "https:";
    const host = request.headers.get("host");
    if (host) url.host = host;
    return NextResponse.redirect(url, 308);
  }

  const response = NextResponse.next();
  response.headers.set("strict-transport-security", "max-age=31536000; includeSubDomains");
  response.headers.set("x-content-type-options", "nosniff");
  response.headers.set("referrer-policy", "strict-origin-when-cross-origin");
  return response;
}

export const config = {
  matcher: "/((?!_next/static|_next/image|favicon.ico).*)",
};

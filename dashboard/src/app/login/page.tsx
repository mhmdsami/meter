import { headers } from "next/headers";
import { redirect } from "next/navigation";
import { auth, googleConfigured } from "@/lib/auth-server";
import { GoogleSignIn } from "./google-signin";

export const dynamic = "force-dynamic";
export const metadata = { title: "Sign in" };

export default async function LoginPage({ searchParams }: { searchParams: Promise<{ next?: string }> }) {
  const { next } = await searchParams;
  const session = await auth().api.getSession({ headers: await headers() });
  if (session) redirect("/");

  return (
    <main className="relative flex min-h-dvh items-center justify-center overflow-hidden p-6">
      <div
        aria-hidden
        className="pointer-events-none absolute inset-x-0 top-0 h-[420px] bg-[radial-gradient(60%_100%_at_50%_0%,color-mix(in_oklch,var(--primary)_12%,transparent),transparent)]"
      />
      <div className="animate-fade-up relative w-full max-w-sm rounded-lg border border-border bg-card p-8 shadow-[var(--shadow-card)]">
        <h1 className="font-display text-2xl tracking-tight">meter</h1>
        <p className="mt-1 text-xs text-text-tertiary">AI usage across machines</p>
        <h2 className="mt-7 text-base font-medium">Sign in</h2>
        <div className="mt-6">
          {googleConfigured() ? (
            <GoogleSignIn next={next} />
          ) : (
            <p className="rounded-md border border-destructive/30 bg-destructive/10 p-3 text-xs leading-5 text-destructive">
              Google OAuth is not configured. Set <code>GOOGLE_CLIENT_ID</code> and <code>GOOGLE_CLIENT_SECRET</code> on
              the Worker with the real values from Google Cloud Console.
            </p>
          )}
        </div>
      </div>
    </main>
  );
}

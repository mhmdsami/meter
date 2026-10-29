import { headers } from "next/headers";
import { redirect } from "next/navigation";
import { auth } from "@/lib/auth-server";
import { GoogleSignIn } from "./google-signin";

export const dynamic = "force-dynamic";
export const metadata = { title: "Sign in" };

export default async function LoginPage({
  searchParams,
}: {
  searchParams: Promise<{ next?: string }>;
}) {
  const { next } = await searchParams;
  const session = await auth().api.getSession({ headers: await headers() });
  if (session) redirect("/");

  return (
    <main className="relative flex min-h-dvh items-center justify-center overflow-hidden p-6">
      <div
        aria-hidden
        className="pointer-events-none absolute -top-40 left-1/2 size-[520px] -translate-x-1/2 rounded-full opacity-30 blur-3xl"
        style={{ background: "radial-gradient(circle, var(--primary), transparent 65%)" }}
      />
      <div className="animate-fade-up relative w-full max-w-sm rounded-lg border border-border bg-card p-8 shadow-[var(--shadow-card)]">
        <h1 className="font-display text-3xl tracking-tight">meter</h1>
        <p className="mt-1 text-xs text-tertiary">AI usage across machines</p>
        <h2 className="mt-7 text-base font-medium">Sign in</h2>
        <p className="mt-1 text-xs leading-5 text-muted">Access is limited to approved accounts.</p>
        <div className="mt-6">
          <GoogleSignIn next={next} />
        </div>
      </div>
    </main>
  );
}

import { headers } from "next/headers";
import { redirect } from "next/navigation";
import { auth } from "@/lib/auth-server";
import Dashboard from "./dashboard";

export const dynamic = "force-dynamic";

export default async function Page() {
  const session = await auth().api.getSession({ headers: await headers() });
  if (!session) redirect("/login");
  return (
    <Dashboard
      user={{
        email: session.user.email,
        name: session.user.name,
        image: session.user.image ?? null,
      }}
    />
  );
}

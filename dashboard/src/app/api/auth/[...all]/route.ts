import { auth } from "@/lib/auth-server";

export const dynamic = "force-dynamic";

export const GET = (request: Request) => auth().handler(request);
export const POST = (request: Request) => auth().handler(request);

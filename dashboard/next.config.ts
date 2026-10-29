import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // The repo root has its own package-lock.json for the gate tooling; without
  // this Turbopack walks up and warns about two roots.
  turbopack: { root: import.meta.dirname },
};

export default nextConfig;

// Enables Cloudflare bindings (D1) during `next dev`.
import { initOpenNextCloudflareForDev } from "@opennextjs/cloudflare";

initOpenNextCloudflareForDev();

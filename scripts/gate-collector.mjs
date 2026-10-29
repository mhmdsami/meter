#!/usr/bin/env node
// Rust gate. The collector is built on CI and on hosts that have a toolchain;
// this machine may not, so a missing cargo is a skip rather than a failure.
import { spawnSync } from "node:child_process";

const has = spawnSync("cargo", ["--version"], { stdio: "ignore" }).status === 0;
if (!has) {
  console.log("cargo not installed: skipping collector gate");
  process.exit(0);
}

const steps = [
  ["cargo", ["fmt", "--manifest-path", "collector/Cargo.toml", "--check"]],
  ["cargo", ["clippy", "--manifest-path", "collector/Cargo.toml", "--all-targets", "--", "-D", "warnings"]],
  ["cargo", ["test", "--manifest-path", "collector/Cargo.toml", "--quiet"]],
];

for (const [command, args] of steps) {
  console.log(`> ${command} ${args.join(" ")}`);
  const result = spawnSync(command, args, { stdio: "inherit" });
  if (result.status !== 0) process.exit(result.status ?? 1);
}

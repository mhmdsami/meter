#!/usr/bin/env node
// Rust gate. The collector is built on CI and on hosts that have a toolchain;
// this machine may not, so a missing cargo is a skip rather than a failure.
import { spawnSync } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";

// rustup installs into ~/.cargo/bin without touching PATH, so hooks and IDEs
// that do not source a login shell would otherwise skip this leg.
const cargoBin = join(homedir(), ".cargo", "bin");
const env = { ...process.env, PATH: `${cargoBin}:${process.env.PATH ?? ""}` };

const has = spawnSync("cargo", ["--version"], { stdio: "ignore", env }).status === 0;
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
  const result = spawnSync(command, args, { stdio: "inherit", env });
  if (result.status !== 0) process.exit(result.status ?? 1);
}

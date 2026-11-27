// SPDX-License-Identifier: MPL-2.0
/**
 * Makes invitations for App Review, one per device the reviewer may use, and writes the block of
 * the review notes that says how to connect.
 *
 *   node tools/demo/invites.ts --state ~/lobby-demo/state [--hours 336] [--out notes-block.txt]
 *
 * Each code works once, for one device, as a viewer of the demo household (never a manager), until
 * it expires. 336 hours (14 days) is the server's longest: re-run this before each submission.
 * Earlier invitations made by this script are taken back first, so only the newest set works.
 */
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { Api, option, readSecret, stateDir } from "./lib.ts";

interface Invite {
  id: string;
  code: string;
  expiresAt: number;
  introducer: string | null;
}

const state = stateDir();
const api = new Api(
  option("server", "http://127.0.0.1:8674"),
  readSecret(join(state, "doorman.token")),
);
if (!api.token) throw new Error("No doorman credential: run setup.ts first.");
const hours = Number(option("hours", "336"));
const out = option("out", join(state, "notes-block.txt"));
const issuedFile = join(state, "invites.json");

// Take back the set made before.
if (existsSync(issuedFile)) {
  for (const id of JSON.parse(readFileSync(issuedFile, "utf8")) as string[]) {
    await api.call("DELETE", `/v1/households/owner/invites/${id}`).catch(() => undefined);
  }
}

const devices = ["iPhone", "iPad", "Mac", "Apple TV", "Spare 1", "Spare 2"];
const made: { device: string; invite: Invite }[] = [];
for (const device of devices) {
  const invite = await api.call<Invite>("POST", "/v1/households/owner/invites", {
    access: "viewer",
    inviteHours: hours,
  });
  made.push({ device, invite });
}
writeFileSync(issuedFile, JSON.stringify(made.map((one) => one.invite.id)), { mode: 0o600 });

const introducer = made[0]?.invite.introducer;
const expires = new Date(Math.min(...made.map((one) => one.invite.expiresAt)));
const day = expires.toISOString().slice(0, 10);
const block = [
  "HOW TO CONNECT TO THE DEMO SERVER",
  `On the first screen choose "Pair From Outside" (every platform), then enter:`,
  `  Address: ${introducer?.replace(/^wss:\/\//, "") ?? "(the direct connection is not set up)"}`,
  "  Code, one per device (each code works once):",
  ...made.map((one) => `    ${one.device.padEnd(9)} ${one.invite.code}`),
  `The codes work until ${day}. Then tap "Pair This Device". The demo server approves a device with one of these codes by itself within a few seconds; the six digits shown on screen need no answer.`,
  "",
].join("\n");
writeFileSync(out, block, { mode: 0o600 });
console.log(`${made.length} invitations until ${day}. The notes block is in ${out}.`);

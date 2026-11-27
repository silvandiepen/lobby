// SPDX-License-Identifier: MPL-2.0
/**
 * The demo server's doorman: approves a device that pairs from outside with one of the reviewer's
 * invitations, so App Review can connect without anyone at a manager's screen.
 *
 *   node tools/demo/doorman.ts --state ~/lobby-demo/state
 *
 * For the demo server only. On a household's server a manager compares the six digits on both
 * screens before saying yes; that comparison is what stops someone who learned a code. Here the
 * doorman takes the digits the server shows managers, so whoever has a code is let in, as a
 * viewer of a library of open movies. It approves only requests that came with an invitation
 * (`invited`), never one at a manager's window, and only as what the invitation says (viewer).
 */
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { Api, option, readSecret, stateDir } from "./lib.ts";

interface OutsideRequest {
  id: string;
  deviceName: string;
  platform: string;
  comparison: string;
  invited: boolean;
  access: string | null;
  state: string;
}

const api = new Api(
  option("server", "http://127.0.0.1:8674"),
  readSecret(join(stateDir(), "doorman.token")),
);
if (!api.token) throw new Error("No doorman credential: run setup.ts first.");

const seen = new Set<string>();
for (;;) {
  try {
    const { outsideRequests } = await api.call<{ outsideRequests: OutsideRequest[] }>(
      "GET",
      "/v1/pairing/requests",
    );
    for (const request of outsideRequests) {
      if (!request.invited || request.state !== "waiting" || seen.has(request.id)) continue;
      seen.add(request.id);
      const answer = await api.call<{ role: string }>(
        "POST",
        `/v1/outside/pairing/${request.id}/approve`,
        { comparison: request.comparison },
      );
      console.log(`${new Date().toISOString()} let in a ${request.platform} as ${answer.role}`);
    }
  } catch (error) {
    console.log(
      `${new Date().toISOString()} ${error instanceof Error ? error.message : String(error)}`,
    );
  }
  await sleep(2000);
}

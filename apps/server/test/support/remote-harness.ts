// SPDX-License-Identifier: MPL-2.0
// The real server of this repository on this machine, for the apps' tests of playing on another
// device (apps/apple/MacTests/RemoteFlowTests.swift). Commands come as a line of JSON each,
// answers go the same way.
//
//   node apps/server/test/support/remote-harness.ts
import { join } from "node:path";
import { createInterface } from "node:readline";
import { serve, type ServerType } from "@hono/node-server";
import type { Platform } from "../../src/auth/devices.ts";
import { makeVideo } from "./media.ts";
import { OutsideFixture } from "./outside.ts";

const f = new OutsideFixture();
await f.start();
makeVideo(join(f.dir, "Films", "Balloon (2001).mp4"), { seconds: 40, seed: 1 });
makeVideo(join(f.dir, "Films", "Scary (2002).mp4"), { seconds: 40, seed: 2 });
await f.scan();

const server: ServerType = await new Promise((done) => {
  const made = serve({ fetch: f.home.fetch, hostname: "127.0.0.1", port: 0 }, () => {
    done(made);
  });
});
const address = server.address();
const port = typeof address === "object" && address !== null ? address.port : 0;

type Command = Record<string, unknown>;
const text = (value: unknown): string => (typeof value === "string" ? value : "");

const commands: Record<string, (said: Command) => unknown> = {
  /** A paired device, without pairing: that only lets so many ask in an hour. */
  device: (said) => {
    const made = f.devices.createOutsideViewer(
      text(said["name"]),
      text(said["platform"]) as Platform,
    );
    f.devices.setAllowOutside(made.device.id, false);
    return { id: made.device.id, token: made.token };
  },
  profile: async (said) => {
    const kids = Array.isArray(said["kids"])
      ? {
          allowedGroupIds: [],
          allowedCategoryIds: [],
          allowedItemIds: said["kids"] as string[],
          blockedItemIds: [],
        }
      : undefined;
    const reply = await f.atHome(f.manager.token, "POST", "/v1/profiles", {
      name: text(said["name"]),
      ...(kids ? { kids } : {}),
    });
    return reply.json<{ id: string }>();
  },
  bind: async (said) => {
    const reply = await f.atHome(f.manager.token, "PATCH", `/v1/devices/${text(said["device"])}`, {
      kidsProfileId: said["profile"] ?? null,
    });
    return { status: reply.status };
  },
  items: () => ({
    items: f.items.map((one) => ({
      id: one.id,
      title: one.title,
      asset: one.files[0]?.assetId ?? "",
    })),
  }),
};

const say = (message: object): void => {
  process.stdout.write(`${JSON.stringify(message)}\n`);
};
const stop = async (): Promise<void> => {
  if ("closeAllConnections" in server) server.closeAllConnections();
  await new Promise((done) => server.close(done));
  await f.stop();
  process.exit(0);
};
const lines = createInterface({ input: process.stdin });
lines.on("close", () => void stop());
lines.on("line", (line) => {
  void (async () => {
    const said = JSON.parse(line) as Command;
    try {
      const answer = await commands[text(said["do"])]?.(said);
      say({ ok: true, ...(answer as object) });
    } catch (error) {
      say({ ok: false, error: String(error) });
    }
  })();
});
say({ ok: true, port, manager: f.manager.token });

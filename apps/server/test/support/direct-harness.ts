// SPDX-License-Identifier: MPL-2.0
// The real server, introducer and lobby-direct on this machine, for the apps' end-to-end tests
// (packages/LobbyKit). Commands come as a line of JSON each, answers go the same way.
//
//   node apps/server/test/support/direct-harness.ts
import { randomBytes } from "node:crypto";
import { spawnSync } from "node:child_process";
import { chmodSync, mkdtempSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { serve, type ServerType } from "@hono/node-server";
import { DirectFixture, programs, Shim } from "./direct.ts";
import { makeVideo } from "./media.ts";
import { until } from "./outside.ts";

// Preparing at this many times the film's speed, as on a Pi, instead of as fast as this Mac can.
const readRate = Number(process.env["LOBBY_HARNESS_PREPARE_SPEED"] ?? "");
if (Number.isFinite(readRate) && readRate > 0) {
  const wrapper = join(mkdtempSync(join(tmpdir(), "lobby-ffmpeg-")), "ffmpeg");
  writeFileSync(wrapper, `#!/bin/sh\nexec ffmpeg -readrate ${String(readRate)} "$@"\n`);
  chmodSync(wrapper, 0o700);
  process.env["LOBBY_TEST_FFMPEG"] = wrapper;
}
const found = programs();
if (!found) process.exit(3);
const d = new DirectFixture();
// What the box may send, as `outside.direct.maxUploadMbit` sets it on a Pi.
const cap = Number(process.env["LOBBY_HARNESS_MAX_UPLOAD_MBIT"] ?? "");
await d.start(found.sidecar, Number.isFinite(cap) && cap > 0 ? { maxUploadMbit: cap } : {});
// A device that rings before the program is up is told "unavailable".
await until(() => d.direct.directStatus().running);
const shims: Shim[] = [];
// Why the box says its connections ended, from its own log.
const endings: string[] = [];
const logged = console.log.bind(console);
console.log = (...parts: unknown[]): void => {
  const text = parts.map(String).join(" ");
  const reason = / A direct connection ended .*reason="([^"]*)"/.exec(text)?.[1];
  if (reason !== undefined) endings.push(reason);
  logged(...parts);
};
let homeServer: ServerType | null = null;

const openHome = (port: number): Promise<number> =>
  new Promise((done) => {
    homeServer = serve({ fetch: d.f.home.fetch, hostname: "127.0.0.1", port }, (info) => {
      done(info.port);
    });
  });
const closeHome = async (): Promise<void> => {
  const server = homeServer;
  homeServer = null;
  if (!server) return;
  if ("closeAllConnections" in server) server.closeAllConnections();
  await new Promise((done) => server.close(done));
};

/** Puts bytes in the place of a film that was really scanned. */
const setFilm = (asset: string, path: string, bytes: Buffer): void => {
  writeFileSync(path, bytes);
  const info = statSync(path);
  d.f.db.run("update asset set size = ?, mtime_ms = ? where id = ?", [
    bytes.length,
    Math.floor(info.mtimeMs),
    asset,
  ]);
};

type Command = Record<string, unknown>;
const text = (value: unknown): string => (typeof value === "string" ? value : "");

const commands: Record<string, (said: Command) => unknown> = {
  openHome: async (said) => ({ port: await openHome(Number(said["port"] ?? 0)) }),
  closeHome: async () => {
    await closeHome();
    return {};
  },
  pair: async (said) => {
    const paired = d.f.pair(text(said["name"]), said["outside"] === true);
    await d.told();
    return paired;
  },
  manager: () => ({ id: d.f.manager.id, token: d.f.manager.token }),
  told: async () => {
    await d.told();
    return {};
  },
  allow: async (said) => {
    await d.f.atHome(d.f.manager.token, "PATCH", `/v1/devices/${text(said["id"])}`, {
      allowOutside: said["allow"] === true,
    });
    await d.told();
    return {};
  },
  revoke: async (said) => {
    await d.f.atHome(d.f.manager.token, "DELETE", `/v1/devices/${text(said["id"])}`);
    await d.told();
    return {};
  },
  enabled: async (said) => {
    await d.f.outside.setEnabled(said["on"] === true);
    if (said["on"] === true) await until(() => d.direct.directStatus().introducer);
    return {};
  },
  status: () => d.f.outside.status(),
  kill: () => {
    const { child } = (d.direct as unknown as { sidecar: { child: { pid: number } } }).sidecar;
    process.kill(child.pid, "SIGKILL");
    return {};
  },
  up: async () => {
    await until(() => d.direct.status().open && d.direct.directStatus().introducer);
    return {};
  },
  window: async () =>
    (await d.f.atHome(d.f.manager.token, "POST", "/v1/outside/window", {})).json<object>(),
  requests: () => ({ requests: d.f.outside.status().requests }),
  approve: async (said) => {
    const reply = await d.f.atHome(
      d.f.manager.token,
      "POST",
      `/v1/outside/pairing/${text(said["id"])}/approve`,
      { comparison: text(said["comparison"]) },
    );
    await d.told();
    return { status: reply.status };
  },
  /** Bytes of which every one is known. */
  film: async (said) => {
    const path = join(d.f.dir, "Films", "Known (2020).mp4");
    makeVideo(path);
    await d.f.scan();
    const asset = d.f.db.get<{ id: string }>("select id from asset")?.id ?? "";
    const bytes = randomBytes(Number(said["bytes"]));
    setFilm(asset, path, bytes);
    const copy = join(d.f.dir, "copy.bin");
    writeFileSync(copy, bytes);
    return { asset, copy };
  },
  /** A film that plays, of about 4 Mbit/s (`mbit`). An `mkv` one is prepared before it plays. */
  playable: async (said) => {
    const kind = said["container"] === "mkv" ? "mkv" : "mp4";
    const rate = `${Number(said["mbit"] ?? 4)}M`;
    const path = join(d.f.dir, "Films", `Playable (2021).${kind}`);
    const made = spawnSync(
      "ffmpeg",
      [
        ...["-v", "error", "-y", "-f", "lavfi", "-i"],
        `testsrc2=size=640x360:rate=25:duration=${Number(said["seconds"])},noise=alls=40:allf=t`,
        ...["-f", "lavfi", "-i", `sine=duration=${Number(said["seconds"])}`],
        ...["-c:v", "libx264", "-preset", "ultrafast", "-b:v", rate, "-minrate", rate],
        ...["-maxrate", rate, "-bufsize", "8M", "-pix_fmt", "yuv420p", "-g", "50"],
        ...["-c:a", "aac", ...(kind === "mp4" ? ["-movflags", "+faststart"] : []), path],
      ],
      { encoding: "utf8" },
    );
    if (made.status !== 0) throw new Error(made.stderr);
    await d.f.scan();
    const asset = d.f.db.get<{ id: string }>(
      "select id from asset where rel_path like '%Playable%'",
    )?.id;
    return { asset, bytes: statSync(path).size };
  },
  road: async (said) => {
    const road = await Shim.start({
      oneWayMs: Number(said["oneWayMs"] ?? 0),
      loss: Number(said["loss"] ?? 0),
      mbit: Number(said["mbit"] ?? 1000),
      queueMs: Number(said["queueMs"] ?? 200),
    });
    shims.push(road);
    const port = (sdp: string): number => Number(/127\.0\.0\.1 (\d+)/.exec(sdp)?.[1]);
    return { road: shims.length - 1, offer: port(road.offer("")), answer: port(road.answer("")) };
  },
  roadDown: (said) => {
    shims[Number(said["road"])]?.stop();
    return {};
  },
  endings: () => ({ endings }),
  roadRebind: async (said) => {
    await shims[Number(said["road"])]?.rebind();
    return {};
  },
  roadCounts: (said) => shims[Number(said["road"])]?.counts,
};

const say = (message: object): void => {
  process.stdout.write(`${JSON.stringify(message)}\n`);
};
const stop = async (): Promise<void> => {
  await closeHome();
  await d.stop();
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
say({ ok: true, introducer: d.introducer.url, boxId: d.keys.boxId });

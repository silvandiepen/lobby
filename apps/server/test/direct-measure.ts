// SPDX-License-Identifier: MPL-2.0
// Measures the direct road on this machine, over a road with a delay, a speed, a queue and losses.
//
//   cargo build --release --features measure --bins --examples --manifest-path apps/direct/Cargo.toml
//   node apps/server/test/direct-measure.ts [bbr|cubic|newreno] [maxUploadMbit]
//
// Not a test: the numbers depend on the machine. What they were is in docs/outside.md.
import { randomBytes } from "node:crypto";
import { chmodSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { DirectFixture, programs, Shim, type TestDevice } from "./support/direct.ts";
import { makeVideo } from "./support/media.ts";

process.env["LOBBY_DIRECT_TARGET"] ??= join(import.meta.dirname, "../../direct/target/release");
const cc = process.argv[2] ?? "bbr";
const found = programs();
if (!found) throw new Error("no programs");
console.log = () => undefined; // the server's log
const say = (text: string): void => void process.stdout.write(`${text}\n`);

const ROADS = [
  { name: "40 Mbit/s, 60 ms, queue 100 ms", oneWayMs: 30, mbit: 40, queueMs: 100, loss: 0 },
  {
    name: "40 Mbit/s, 60 ms, queue 100 ms, 1% loss",
    oneWayMs: 30,
    mbit: 40,
    queueMs: 100,
    loss: 0.01,
  },
  { name: "20 Mbit/s, 60 ms, queue 400 ms", oneWayMs: 30, mbit: 20, queueMs: 400, loss: 0 },
];
const SIZE = 48_000_000;

const d = new DirectFixture();
const wrapper = join(d.dataDir, "sidecar.sh");
writeFileSync(wrapper, `#!/bin/sh\nLOBBY_DIRECT_CC=${cc} exec ${found.sidecar}\n`);
chmodSync(wrapper, 0o700);
const cap = process.argv[3] === undefined ? null : Number(process.argv[3]);
await d.start(wrapper, { maxUploadMbit: cap });
const path = join(d.f.dir, "Films", "Known (2020).mp4");
makeVideo(path);
await d.f.scan();
const asset = d.f.db.get<{ id: string }>("select id from asset")?.id ?? "";
writeFileSync(path, randomBytes(SIZE));
d.f.db.run("update asset set size = ?, mtime_ms = ? where id = ?", [
  SIZE,
  Math.floor(statSync(path).mtimeMs),
  asset,
]);
const url = `/v1/assets/${asset}/content`;

const leave = (tv: TestDevice, from: number, after: number): Promise<number> =>
  new Promise((done) => {
    const socket = tv.stream();
    let read = 0;
    socket.on("error", () => undefined);
    socket.on("data", (data: Buffer) => {
      read += data.length;
      if (read < after) return;
      socket.destroy();
      done(read);
    });
    socket.write(
      `GET ${url} HTTP/1.1\r\nHost: lobby.example.test\r\nAuthorization: Bearer ${tv.token}\r\nRange: bytes=${from}-\r\n\r\n`,
    );
  });

for (const road of ROADS) {
  const shim = await Shim.start(road);
  const tv = await d.device(road.name);
  await tv.connect(found.device, { road: shim });
  await tv.ask("GET", "/v1/me");
  const { counts } = shim;
  const at = performance.now();
  const whole = await tv.ask("GET", url, { headers: { Range: `bytes=0-${SIZE - 1}` } });
  const mbit = (whole.body.length * 8) / ((performance.now() - at) * 1000);
  const drops = `${counts.full} dropped of ${counts.waits + counts.full}`;
  const queue = Math.round(counts.waitedMs / counts.waits);
  const wasted: number[] = [];
  const jumps: number[] = [];
  for (let jump = 0; jump < 8; jump += 1) {
    const before = counts.toDevice;
    const read = await leave(tv, jump * 1_000_000, 4_000_000);
    const then = performance.now();
    await tv.ask("GET", url, {
      headers: { Range: `bytes=${20_000_000 + jump * 500_000}-${20_200_000 + jump * 500_000}` },
    });
    jumps.push(Math.round(performance.now() - then));
    await new Promise((done) => setTimeout(done, 1_000));
    wasted.push(Math.round((counts.toDevice - before - read - 200_001) / 1000));
  }
  jumps.sort((a, b) => a - b);
  wasted.sort((a, b) => a - b);
  say(
    `${cc}${cap === null ? "" : `, at most ${cap}`} | ${road.name} | ${mbit.toFixed(1)} Mbit/s | ${drops} | queue ${queue} ms | jump median ${jumps[4] ?? 0} ms, most ${jumps[7] ?? 0} ms | wasted median ${wasted[4] ?? 0} kB, most ${wasted[7] ?? 0} kB`,
  );
  tv.stop();
  shim.stop();
}
await d.stop();
process.exit(0);

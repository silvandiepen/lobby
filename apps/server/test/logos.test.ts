// SPDX-License-Identifier: MPL-2.0
import { createServer } from "node:http";
import { once } from "node:events";
import { mkdirSync, writeFileSync } from "node:fs";
import type { AddressInfo } from "node:net";
import { join } from "node:path";
import { afterEach, beforeEach, expect, it } from "vitest";
import { LOGO_PATH, LogoStore } from "../src/artwork/logos.ts";
import { Devices } from "../src/auth/devices.ts";
import { Database } from "../src/db/database.ts";
import { createApp } from "../src/http/app.ts";
import type { RootConfig } from "../src/config.ts";
import { Catalogue } from "../src/library/catalogue.ts";
import { Categories } from "../src/library/categories.ts";
import { Scanner } from "../src/library/scanner.ts";
import { ItemReader } from "../src/library/items.ts";
import { ProgressStore } from "../src/progress.ts";
import { makeTempDir, removeDir } from "./support/media.ts";

const PNG = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==",
  "base64",
);
let dir: string;

beforeEach(() => {
  dir = makeTempDir();
});
afterEach(() => {
  removeDir(dir);
});

it("fetches logos once, serves them to paired devices and leaves out what failed", async () => {
  let requests = 0;
  const server = createServer((request, response) => {
    requests += 1;
    if (request.url === "/goodlogo1.png") response.end(PNG);
    else if (request.url === "/notapicture.png") response.end("<html>");
    else response.writeHead(404).end();
  }).listen(0);
  await once(server, "listening");
  const base = `http://127.0.0.1:${String((server.address() as AddressInfo).port)}`;
  const roots: RootConfig[] = [
    { path: "/m/a", name: "Pixar", hint: "movies", logo: "/goodlogo1.png" },
    { path: "/m/b", name: "Disney", hint: "movies", logo: "/notapicture.png" },
    { path: "/m/c", name: "Movies", hint: "movies" },
  ];
  const db = new Database(join(dir, "lobby.db"));
  new Scanner(db, new Catalogue(db), {
    stabilityMs: 0,
    probeConcurrency: 1,
    ffprobePath: "ffprobe",
  }).syncSources(roots);
  const categories = new Categories(db);
  const logos = new LogoStore(db, join(dir, "logos"), base);
  try {
    await logos.start();
    expect(categories.view().logos).toEqual({ Pixar: { id: "goodlogo1", width: 1, height: 1 } });

    const devices = new Devices(db, "secret");
    const { token } = devices.createLocalManager("Mac");
    const app = createApp({
      db,
      devices,
      items: new ItemReader(db),
      progress: new ProgressStore(db),
      logos,
      serverName: "Test",
      version: "0",
      isScanning: () => false,
    });
    const headers = { Authorization: `Bearer ${token}` };
    expect((await app.request("/v1/logos/goodlogo1")).status).toBe(401);
    const answer = await app.request("/v1/logos/goodlogo1", { headers });
    expect(answer.headers.get("content-type")).toBe("image/png");
    expect(Buffer.from(await answer.arrayBuffer()).equals(PNG)).toBe(true);
    expect((await app.request("/v1/logos/..%2Flobby", { headers })).status).toBe(404);

    const before = requests;
    const again = new LogoStore(db, join(dir, "logos"), base);
    // The one that failed is not asked for again here; the good one is in the catalogue.
    db.run("update category set logo_id = null where name = 'Disney'");
    db.run("delete from logo where id = 'notapicture'");
    await again.start();
    expect(requests).toBe(before);
  } finally {
    logos.stop();
    db.close();
    server.close();
  }
});

it("only takes a plain picture path", () => {
  expect(LOGO_PATH.test("/1TjvGVDMYsj6JBxOAkUHpPEwLf7.png")).toBe(true);
  for (const bad of ["abc.png", "/../secret.png", "//evil.example/x.png", "/a b.png"]) {
    expect(LOGO_PATH.test(bad)).toBe(false);
  }
});

it("takes the logos over that were kept in the data folder, without fetching them", async () => {
  const db = new Database(join(dir, "lobby.db"));
  db.run("insert into logo (id, remote_path) values ('keptlogo1', '/keptlogo1.png')");
  mkdirSync(join(dir, "logos"));
  writeFileSync(join(dir, "logos", "keptlogo1.png"), PNG);
  const logos = new LogoStore(db, join(dir, "logos"), "http://127.0.0.1:1");
  try {
    await logos.start();
    expect(Buffer.from(logos.read("keptlogo1") ?? []).equals(PNG)).toBe(true);
  } finally {
    logos.stop();
    db.close();
  }
});

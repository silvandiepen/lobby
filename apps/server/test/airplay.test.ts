// SPDX-License-Identifier: MPL-2.0
import { join } from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { AIRPLAY, AirPlayPasses } from "../src/http/airplay.ts";
import { makeVideo } from "./support/media.ts";
import { OutsideFixture } from "./support/outside.ts";

let f: OutsideFixture;
let balloon: { item: string; asset: string };
let scary: { item: string; asset: string };

const film = (title: string): { item: string; asset: string } => {
  const item = f.items.find((one) => one.title === title);
  return { item: item?.id ?? "", asset: item?.files[0]?.assetId ?? "" };
};

/** What an AirPlay receiver sends: no header with a credential, and no cookie. */
const receiver = (
  path: string,
  headers: Record<string, string> = {},
  method = "GET",
): Promise<Response> => Promise.resolve(f.home.request(path, { method, headers }));

const pass = async (
  token: string,
  asset: string,
): Promise<{ prefix: string; expiresAt: number }> => {
  const reply = await f.atHome(token, "POST", `/v1/assets/${asset}/airplay`, {});
  expect(reply.status).toBe(200);
  return reply.json<{ prefix: string; expiresAt: number }>();
};

beforeAll(async () => {
  f = new OutsideFixture();
  await f.start();
  makeVideo(join(f.dir, "Films", "Balloon (2001).mp4"), { seed: 1 });
  makeVideo(join(f.dir, "Films", "Scary (2002).mp4"), { seed: 2 });
  await f.scan();
  balloon = film("Balloon");
  scary = film("Scary");
});

afterAll(async () => {
  await f.stop();
});

describe("an AirPlay pass", () => {
  it("lets a receiver fetch that one file without the credential, with ranges", async () => {
    const tv = f.pair("Phone", false);
    const { prefix, expiresAt } = await pass(tv.token, balloon.asset);
    expect(prefix).toMatch(/^\/v1\/airplay\/[A-Za-z0-9_-]{20,}$/);
    expect(expiresAt).toBeGreaterThan(Date.now() + AIRPLAY.lifetimeMs - 60_000);

    const whole = await receiver(`${prefix}/assets/${balloon.asset}/content`);
    expect(whole.status).toBe(200);
    const bytes = new Uint8Array(await whole.arrayBuffer());
    expect(bytes.length).toBeGreaterThan(1000);

    const part = await receiver(`${prefix}/assets/${balloon.asset}/content`, {
      Range: "bytes=0-99",
    });
    expect(part.status).toBe(206);
    expect((await part.arrayBuffer()).byteLength).toBe(100);

    const head = await receiver(`${prefix}/assets/${balloon.asset}/content`, {}, "HEAD");
    expect(head.status).toBe(200);
    expect(head.headers.get("content-length")).toBe(String(bytes.length));

    // Without the pass the same file needs the credential.
    expect((await receiver(`/v1/assets/${balloon.asset}/content`)).status).toBe(401);
  });

  it("opens nothing but its own file", async () => {
    const tv = f.pair("Phone", false);
    const { prefix } = await pass(tv.token, balloon.asset);
    expect((await receiver(`${prefix}/assets/${scary.asset}/content`)).status).toBe(404);
    expect((await receiver(`${prefix}/assets/${balloon.asset}/../../library`)).status).toBe(404);
    expect((await receiver(`${prefix}/library`)).status).toBe(404);
    expect((await receiver(`${prefix}/me`)).status).toBe(404);
    expect((await receiver(`/v1/airplay/not-a-pass/assets/${balloon.asset}/content`)).status).toBe(
      404,
    );
    // Only reading: anything else is an ordinary request, without a credential.
    expect((await receiver(`${prefix}/assets/${balloon.asset}/playback`, {}, "POST")).status).toBe(
      401,
    );
    // And a credential sent along does not make it more than it is.
    const other = await receiver(`${prefix}/assets/${scary.asset}/content`, {
      Authorization: `Bearer ${f.manager.token}`,
    });
    expect(other.status).toBe(404);
  });

  it("ends with its time and with its device", async () => {
    const tv = f.pair("Phone", false);
    const clock = { now: 1_000 };
    const passes = new AirPlayPasses(f.devices, () => clock.now);
    const issued = passes.issue(tv.id, balloon.asset);
    expect(passes.find(issued.name)).not.toBeNull();
    clock.now += AIRPLAY.lifetimeMs;
    expect(passes.find(issued.name)).toBeNull();

    const again = await pass(tv.token, balloon.asset);
    expect((await receiver(`${again.prefix}/assets/${balloon.asset}/content`)).status).toBe(200);
    f.devices.revoke(tv.id);
    expect((await receiver(`${again.prefix}/assets/${balloon.asset}/content`)).status).toBe(404);
  });

  it("keeps a few per device", async () => {
    const tv = f.pair("Phone", false);
    const first = await pass(tv.token, balloon.asset);
    for (let index = 0; index < AIRPLAY.perDevice; index += 1) await pass(tv.token, balloon.asset);
    expect((await receiver(`${first.prefix}/assets/${balloon.asset}/content`)).status).toBe(404);
  });

  it("holds a kids device to its limits", async () => {
    const kid = (
      await f.atHome(f.manager.token, "POST", "/v1/profiles", {
        name: "Small one",
        kids: {
          allowedGroupIds: [],
          allowedCategoryIds: [],
          allowedItemIds: [balloon.item],
          blockedItemIds: [],
        },
      })
    ).json<{ id: string }>().id;
    const child = f.pair("Tablet", false);
    expect(
      (await f.atHome(f.manager.token, "PATCH", `/v1/devices/${child.id}`, { kidsProfileId: kid }))
        .status,
    ).toBe(200);
    expect(
      (await f.atHome(child.token, "POST", `/v1/assets/${scary.asset}/airplay`, {})).status,
    ).toBe(404);
    const { prefix } = await pass(child.token, balloon.asset);
    expect((await receiver(`${prefix}/assets/${balloon.asset}/content`)).status).toBe(200);
    // Taken away after the pass was made: closed under the pass too.
    await f.atHome(f.manager.token, "PATCH", `/v1/profiles/${kid}`, {
      kids: { allowedGroupIds: [], allowedCategoryIds: [], allowedItemIds: [], blockedItemIds: [] },
    });
    expect((await receiver(`${prefix}/assets/${balloon.asset}/content`)).status).toBe(404);
  });

  it("is not handed out from outside, and cannot be used there", async () => {
    const tv = f.pair("Phone", true);
    const asked = await f.ask("POST", `/v1/assets/${balloon.asset}/airplay`, {
      token: tv.token,
      body: {},
    });
    expect([403, 404]).toContain(asked.status);
    const { prefix } = await pass(tv.token, balloon.asset);
    const used = await f.ask("GET", `${prefix}/assets/${balloon.asset}/content`, {
      token: tv.token,
    });
    expect([403, 404]).toContain(used.status);
  });

  it("is refused for a file that is not there", async () => {
    const tv = f.pair("Phone", false);
    expect((await f.atHome(tv.token, "POST", "/v1/assets/nothing/airplay", {})).status).toBe(404);
  });
});

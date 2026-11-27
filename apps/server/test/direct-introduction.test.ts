// SPDX-License-Identifier: MPL-2.0
import { generateKeyPairSync, randomBytes, X509Certificate, type KeyObject } from "node:crypto";
import { chmodSync, existsSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { Device } from "../src/auth/devices.ts";
import { createBackup, restoreBackup } from "../src/backup.ts";
import { Database } from "../src/db/database.ts";
import { Invites } from "../src/households/invites.ts";
import { readCode } from "../src/outside/code.ts";
import { readOutsideConfig, type OutsideConfig } from "../src/outside/config.ts";
import { fingerprint, makeCertificate } from "../src/outside/direct/certificate.ts";
import {
  agree,
  b64,
  boxIdOf,
  DIRECT,
  enrolledSecret,
  introductionAad,
  introductionKeys,
  newAgreementKey,
  open,
  pairingAad,
  pairingCode,
  pairingCommitment,
  pairingKeys,
  pairingSecrets,
  privateKey,
  rawPublic,
  seal,
  sealBytes,
  transcriptHash,
  unb64,
  type PairingSecrets,
} from "../src/outside/direct/envelope.ts";
import { IntroducerClient } from "../src/outside/direct/introducer.ts";
import { BoxKeys, CERTIFICATE_MS, OVERLAP_MS } from "../src/outside/direct/keys.ts";
import { cleanSdp, isPublicAddress } from "../src/outside/direct/sdp.ts";
import type { OutsideStatus } from "../src/outside/entrance.ts";
import { OutsidePairing, type OutsidePairingRequest } from "../src/outside/pairing.ts";
import {
  DirectFixture,
  Line,
  runIntroducer,
  type Identity,
  type RunningIntroducer,
  type TestDevice,
} from "./support/direct.ts";
import { makeTempDir, removeDir } from "./support/media.ts";
import { until } from "./support/outside.ts";

const VECTORS = join(import.meta.dirname, "../../../docs/direct-vectors.json");
// Nothing here needs the program that makes connections: it is all said before there is one.
const NO_PROGRAM = "/nonexistent/lobby-direct";
const SDP =
  "a=ice-ufrag:abcd\r\na=ice-pwd:abcdefghijklmnopqrstuv\r\na=candidate:1 1 UDP 2122317823 127.0.0.1 9 typ host\r\n";

let d: DirectFixture;

describe("an introduction", () => {
  let tv: TestDevice;

  beforeEach(async () => {
    d = new DirectFixture();
    await d.start(NO_PROGRAM, {
      stun: [{ host: "stun.example.com", port: 3478 }],
      turn: { host: "relay.example.com", port: 3478, secret: "a secret for this test" },
    });
    tv = await d.device("Far TV");
  });
  afterEach(async () => {
    await d.stop();
  });

  const ring = async (): Promise<{ line: Line; session: string }> => {
    const rung = await tv.ringUp();
    if (typeof rung === "number") throw new Error(`refused: ${rung}`);
    return rung;
  };

  it("gives a device what it needs, and an answer to its offer", async () => {
    const { line, session } = await ring();
    const greeted = await tv.greet(line, session);
    expect(greeted?.welcome["fingerprints"]).toEqual(d.keys.fingerprints);
    const ice = greeted?.welcome["ice"] as {
      stun: unknown;
      turn: { host: string; username: string; password: string; until: number };
    };
    expect(ice.stun).toEqual([{ host: "stun.example.com", port: 3478 }]);
    expect(ice.turn).toMatchObject({ host: "relay.example.com", port: 3478 });
    // A password for some hours, that does not say whose it is.
    expect(ice.turn.username).toMatch(/^\d+:device-[0-9a-f]{12}$/);
    expect(Number(ice.turn.username.split(":")[0])).toBeGreaterThan(Date.now() / 1000 + 3_600);
    if (!greeted) return;
    const { nonce, boxNonce } = greeted;
    line.say({ t: "msg", p: tv.sealOffer(session, nonce, boxNonce, SDP) });
    const said = (await line.next()) as Record<string, unknown>;
    // Here there is no program to make the connection.
    expect(tv.openAnswer(session, nonce, boxNonce, said["p"])).toEqual({
      t: "error",
      error: "unavailable",
    });
  });

  it("gives no answer to anything that was changed or is for another place", async () => {
    const flip = (payload: string): string => {
      const data = Buffer.from(payload, "base64url");
      data[20] = (data[20] ?? 0) ^ 1;
      return b64(data);
    };
    for (const faults of [
      { hello: flip },
      { hello: () => b64(randomBytes(100)) },
      { hello: () => "AA" },
      { session: "A".repeat(22) },
    ]) {
      const { line, session } = await ring();
      expect(await tv.greet(line, session, faults)).toBeNull();
      line.close();
    }
    // Another device that is let in, with this one's hello.
    const pad = await d.device("Far iPad");
    const first = await ring();
    const greeted = await tv.greet(first.line, first.session);
    const second = await pad.ringUp();
    if (typeof second === "number" || !greeted) throw new Error("no line");
    second.line.say({ t: "msg", p: greeted.payload });
    expect(await second.line.silent()).toBe(true);
    // With its own hello, in another's key.
    const { secret } = pad;
    pad.secret = tv.secret;
    expect(await pad.greet(second.line, second.session)).toBeNull();
    pad.secret = secret;
  });

  it("does not take the same thing twice", async () => {
    const { line, session } = await ring();
    const greeted = await tv.greet(line, session);
    if (!greeted) throw new Error("no welcome");
    const offer = tv.sealOffer(session, greeted.nonce, greeted.boxNonce, SDP);
    // The hello again is no offer.
    line.say({ t: "msg", p: greeted.payload });
    expect(await line.silent()).toBe(true);
    line.say({ t: "msg", p: offer });
    await line.next();
    line.say({ t: "msg", p: offer });
    expect(await line.silent()).toBe(true);
    // All of it again, by an introducer that kept it and gives the conversation the same name.
    let replies = 0;
    const heard = (payload: string): void => {
      (
        d.direct as unknown as {
          heard: (message: object, reply: () => void) => void;
        }
      ).heard({ session, key: tv.ringKey, payload }, () => (replies += 1));
    };
    heard(greeted.payload);
    // A welcome that only who made that hello can read, with something new in it…
    expect(replies).toBe(1);
    heard(offer);
    // …so the old offer is nothing.
    expect(replies).toBe(1);
  });

  it("cannot be turned round, nor said in another's place", () => {
    const place = { boxId: "box", ringKey: "ring", session: "session" };
    const secret = randomBytes(32);
    const [a, b] = [randomBytes(32), randomBytes(32)];
    const key = introductionKeys.session(secret, a, b, "d2b");
    const sealed = seal(key, introductionAad(place, "d2b", 1), { t: "offer" });
    expect(open(key, introductionAad(place, "d2b", 1), sealed)).toEqual({ t: "offer" });
    for (const other of [
      introductionAad(place, "b2d", 1),
      introductionAad(place, "d2b", 2),
      introductionAad({ ...place, session: "other" }, "d2b", 1),
      introductionAad({ ...place, boxId: "other" }, "d2b", 1),
      introductionAad({ ...place, ringKey: "other" }, "d2b", 1),
    ]) {
      expect(open(key, other, sealed)).toBeNull();
    }
    for (const other of [
      introductionKeys.session(secret, a, b, "b2d"),
      introductionKeys.session(secret, b, a, "d2b"),
      introductionKeys.session(randomBytes(32), a, b, "d2b"),
    ]) {
      expect(open(other, introductionAad(place, "d2b", 1), sealed)).toBeNull();
    }
  });

  it("is not for a device that is removed or only for home, whatever the introducer does", async () => {
    const asked = async (device: TestDevice): Promise<number> => {
      let replies = 0;
      const session = b64(randomBytes(16));
      const payload = seal(
        introductionKeys.hello(device.secret),
        introductionAad(
          { boxId: device.identity.boxId, ringKey: device.ringKey, session },
          "d2b",
          0,
        ),
        { t: "hello", nonce: b64(randomBytes(32)) },
      );
      (d.direct as unknown as { heard: (message: object, reply: () => void) => void }).heard(
        { session, key: device.ringKey, payload },
        () => (replies += 1),
      );
      await Promise.resolve();
      return replies;
    };
    expect(await asked(tv)).toBe(1);
    d.f.devices.setAllowOutside(tv.id, false);
    expect(await asked(tv)).toBe(0);
    d.f.devices.setAllowOutside(tv.id, true);
    expect(await asked(tv)).toBe(1);
    const home = await d.device("Home iPad", false);
    expect(await asked(home)).toBe(0);
    expect(await home.ringUp()).toBe(4001);
    d.f.devices.revoke(tv.id);
    expect(await asked(tv)).toBe(0);
    expect(d.f.db.all("select * from direct_device where device_id = ?", [tv.id])).toEqual([]);
    await d.told();
    expect(await tv.ringUp()).toBe(4001);
  });

  it("is limited per device", () => {
    let answered = 0;
    for (let line = 0; line < 2; line += 1) {
      const heard = (
        d.direct as unknown as { heard: (message: object, reply: () => void) => void }
      ).heard.bind(d.direct);
      for (let count = 0; count < 40; count += 1) {
        const session = b64(randomBytes(16));
        const place = { boxId: tv.identity.boxId, ringKey: tv.ringKey, session };
        heard(
          {
            session,
            key: tv.ringKey,
            payload: seal(introductionKeys.hello(tv.secret), introductionAad(place, "d2b", 0), {
              t: "hello",
              nonce: b64(randomBytes(32)),
            }),
          },
          () => (answered += 1),
        );
      }
    }
    expect(answered).toBe(40);
  });

  it("goes on when the introducer was away", async () => {
    const { port } = d.introducer;
    await d.introducer.stop();
    await until(() => !d.direct.directStatus().introducer);
    expect(d.direct.status()).toMatchObject({ open: false });
    d.introducer = await runIntroducer([d.keys.boxId], port);
    await until(() => d.direct.directStatus().introducer);
    await d.told();
    const { line, session } = await ring();
    expect(await tv.greet(line, session)).not.toBeNull();
  });
});

describe("enrolling", () => {
  beforeEach(async () => {
    d = new DirectFixture();
    await d.start(NO_PROGRAM);
  });
  afterEach(async () => {
    await d.stop();
  });

  it("is for paired devices at home, gives nothing secret away and keeps none in the open", async () => {
    const tv = await d.device("TV");
    expect(tv.identity).toMatchObject({
      introducer: d.introducer.url,
      boxId: d.keys.boxId,
      boxKey: b64(d.keys.boxPublic),
      fingerprints: d.keys.fingerprints,
      name: "lobby.example.test",
    });
    expect(boxIdOf(d.keys.boxPublic)).toBe(tv.identity.boxId);
    const reply = await d.f.atHome(tv.token, "GET", "/v1/me/direct");
    expect(reply.json()).toEqual({ ...tv.identity, ringKey: tv.ringKey, allowed: true });
    expect(JSON.stringify(reply.json())).not.toContain(b64(tv.secret));
    const row = d.f.db.get<{ wrapped: string }>("select * from direct_device");
    expect(JSON.stringify(row)).not.toContain(b64(tv.secret));
    expect(readFileSync(join(d.f.dir, "lobby.db")).includes(b64(tv.secret))).toBe(false);
    const anonymous = await d.f.home.request("/v1/me/direct", { method: "PUT", body: "{}" });
    expect(anonymous.status).toBe(401);
    for (const method of ["GET", "PUT"]) {
      const outside = await d.f.ask(method, "/v1/me/direct", {
        token: tv.token,
        ...(method === "PUT" ? { body: {} } : {}),
      });
      expect(outside.status).toBe(403);
    }
  });

  it("refuses keys that are none, and another device's", async () => {
    const tv = await d.device("TV");
    const pad = await d.device("iPad");
    const good = b64(rawPublic(newAgreementKey()));
    for (const body of [
      {},
      { ringKey: tv.ringKey },
      { ringKey: "x", agreementKey: good },
      { ringKey: `${tv.ringKey}=`, agreementKey: good },
      // Nothing comes of this key, whatever the other is.
      { ringKey: b64(randomBytes(32)), agreementKey: b64(Buffer.alloc(32)) },
      { ringKey: pad.ringKey, agreementKey: good },
    ]) {
      const reply = await d.f.atHome(tv.token, "PUT", "/v1/me/direct", body);
      expect([body, reply.status]).toEqual([body, 400]);
    }
    expect((await d.f.atHome(tv.token, "GET", "/v1/me/direct")).json()).toMatchObject({
      ringKey: tv.ringKey,
    });
  });

  it("again takes the place of what was there", async () => {
    const tv = await d.device("TV");
    const before = tv.ringKey;
    const again = await d.f.atHome(tv.token, "PUT", "/v1/me/direct", {
      ringKey: b64(randomBytes(32)),
      agreementKey: b64(rawPublic(newAgreementKey())),
    });
    expect(again.status).toBe(200);
    expect(again.json<{ ringKey: string }>().ringKey).not.toBe(before);
    await d.told();
    expect(await tv.ringUp()).toBe(4001);
  });

  it("is possible for a child's device", async () => {
    const tv = await d.device("Child's iPad", false);
    d.f.db.run(
      `insert into profile (id, name, color, created_at, kids_json) values ('kid', 'Kid', 'red', 1, '{"blockedItemIds":[]}')`,
    );
    d.f.db.run("update device set kids_profile_id = 'kid' where id = ?", [tv.id]);
    expect((await d.f.atHome(tv.token, "GET", "/v1/me/direct")).status).toBe(200);
  });

  it("comes to nothing after a restore, and with another server's keys", async () => {
    const tv = await d.device("TV");
    const backup = await createBackup(d.f.db, join(d.f.dir, "backups"), null);
    expect(existsSync(join(backup.path, "direct"))).toBe(false);
    const target = makeTempDir("lobby-restored-");
    try {
      restoreBackup(backup.path, target);
      const db = new Database(join(target, "lobby.db"));
      expect(db.all("select * from direct_device")).toEqual([]);
      db.close();
    } finally {
      removeDir(target);
    }
    const { DirectIdentities } = await import("../src/outside/direct/identities.ts");
    const elsewhere = makeTempDir("lobby-other-");
    try {
      const other = new DirectIdentities(d.f.db, new BoxKeys(elsewhere), "wss://x", "x");
      expect(d.direct.identities.find(tv.ringKey)?.secret).toEqual(tv.secret);
      expect(other.find(tv.ringKey)).toBeNull();
    } finally {
      removeDir(elsewhere);
    }
  });
});

/** A new device with nothing but a code. */
class Newcomer {
  readonly ring = generateKeyPairSync("ed25519").privateKey;
  readonly agreement = newAgreementKey();
  readonly nonce = randomBytes(32);
  line!: Line;
  session = "";
  room = "";
  key!: Buffer;
  secrets!: PairingSecrets;

  async enter(introducer: string, code: string): Promise<number | null> {
    const { room, key } = await pairingCode(readCode(code) ?? "");
    this.room = room;
    this.key = key;
    return this.come(introducer);
  }

  async come(introducer: string): Promise<number | null> {
    this.line = new Line(`${introducer}/v1/pair/${this.room}`);
    const ready = await this.line.next();
    if (typeof ready === "number") return ready;
    this.session = String(ready["session"]);
    return null;
  }

  say(key: Buffer, step: string, value: object): void {
    this.line.say({ t: "msg", p: seal(key, pairingAad(this.room, this.session, step), value) });
  }

  get commitment(): Buffer {
    return pairingCommitment(rawPublic(this.agreement), this.nonce);
  }

  async hear(key: Buffer, step: string): Promise<Record<string, unknown> | null> {
    const said = await this.line.next(1_500).catch(() => null);
    if (said === null || typeof said === "number") return null;
    const value = open(key, pairingAad(this.room, this.session, step), said["p"]);
    if (!value) throw new Error("not from the box");
    return value;
  }

  /** Until the six digits. */
  async begin(reveal: object = {}, agreement: KeyObject = this.agreement): Promise<string | null> {
    this.say(pairingKeys.code(this.key, "d2b"), "start", { commitment: b64(this.commitment) });
    const box = await this.hear(pairingKeys.code(this.key, "b2d"), "key");
    const boxAgreement = unb64(box?.["agreementKey"], 32);
    const boxNonce = unb64(box?.["nonce"], 32);
    const boxKey = unb64(box?.["boxKey"], 32);
    if (!boxAgreement || !boxNonce || !boxKey) return null;
    const said = {
      agreementKey: b64(rawPublic(agreement)),
      nonce: b64(this.nonce),
      ringKey: b64(rawPublic(this.ring)),
      deviceName: "Far Apple TV",
      platform: "tvos",
      ...reveal,
    };
    this.say(pairingKeys.code(this.key, "d2b"), "reveal", said);
    this.secrets = pairingSecrets(
      agree(agreement, boxAgreement),
      this.key,
      transcriptHash({
        room: this.room,
        commitment: this.commitment,
        boxAgreement,
        boxNonce,
        boxKey,
        deviceAgreement: rawPublic(agreement),
        deviceNonce: this.nonce,
        ringKey: rawPublic(this.ring),
        deviceName: said.deviceName,
        platform: said.platform,
      }),
    );
    const waiting = await this.hear(this.secrets.b2d, "waiting");
    return waiting?.["status"] === "pending" ? this.secrets.comparison : null;
  }

  async collect(more: object = {}): Promise<Record<string, unknown> | null> {
    const nonce = b64(randomBytes(16));
    this.say(this.secrets.d2b, "collect", { nonce, ...more });
    return this.hear(this.secrets.b2d, `answer|${nonce}`);
  }
}

describe("pairing from outside through the introducer", () => {
  let code: string;

  beforeEach(async () => {
    d = new DirectFixture();
    await d.start(NO_PROGRAM);
    code = await window();
  });
  afterEach(async () => {
    await d.stop();
  });

  const window = async (): Promise<string> => {
    const reply = await d.f.atHome(d.f.manager.token, "POST", "/v1/outside/window", {});
    expect(reply.status).toBe(201);
    const opened = reply.json<{ code: string; direct: { introducer: string } }>();
    expect(opened.direct).toEqual({ introducer: d.introducer.url });
    const { room } = await pairingCode(readCode(opened.code) ?? "");
    // The room is open a moment later.
    await until(async () => {
      const line = new Line(`${d.introducer.url}/v1/pair/${room}`);
      const said = await line.next();
      line.close();
      return typeof said !== "number";
    });
    await new Promise((done) => setTimeout(done, 100));
    return opened.code;
  };
  const requests = async (): Promise<OutsidePairingRequest[]> =>
    (await d.f.atHome(d.f.manager.token, "GET", "/v1/outside")).json<OutsideStatus>().requests;

  it("ends with a viewer that can ring", async () => {
    const tv = new Newcomer();
    expect(await tv.enter(d.introducer.url, code.toLowerCase().replaceAll("-", " "))).toBeNull();
    const digits = await tv.begin();
    expect(digits).toMatch(/^\d{6}$/);
    const [waiting] = await requests();
    expect(waiting).toMatchObject({
      deviceName: "Far Apple TV",
      platform: "tvos",
      address: null,
      comparison: digits,
    });
    expect(await tv.collect()).toMatchObject({ status: "pending" });
    const approved = await d.f.atHome(
      d.f.manager.token,
      "POST",
      `/v1/outside/pairing/${waiting?.id ?? ""}/approve`,
      { comparison: digits },
    );
    expect(approved.status).toBe(200);
    const answer = (await tv.collect()) as unknown as {
      status: string;
      device: Device;
      token: string;
      direct: Identity;
    };
    expect(answer.status).toBe("approved");
    expect(answer.device).toMatchObject({ role: "viewer", allowOutside: true });
    expect(answer.direct).toMatchObject({ boxId: d.keys.boxId, introducer: d.introducer.url });
    expect(d.f.devices.authenticate(answer.token).id).toBe(answer.device.id);
    // The line broke before it got that: it comes back, and is told again.
    tv.line.close();
    expect(await tv.come(d.introducer.url)).toBeNull();
    expect(await tv.collect()).toMatchObject({ token: answer.token });
    expect(await tv.collect({ done: true })).toEqual({ status: "done" });
    expect(await tv.line.next()).toBe(1000);
    expect(await tv.come(d.introducer.url)).toBe(1006);
    // It is known by what both worked out, with nothing of it ever said.
    const ringKey = b64(rawPublic(tv.ring));
    expect(d.direct.identities.find(ringKey)).toEqual({
      deviceId: answer.device.id,
      ringKey,
      secret: tv.secrets.secret,
    });
    for (const text of tv.line.seen) expect(text).not.toContain("Far Apple TV");
  });

  it("is nothing without the code", async () => {
    const tv = new Newcomer();
    expect(await tv.enter(d.introducer.url, "AAAA-AAAA-AAAA-AAAA")).toBe(1006);
    // Who knows the room, which is the introducer, still does not know the key.
    const guess = new Newcomer();
    await guess.enter(d.introducer.url, code);
    guess.key = randomBytes(32);
    expect(await guess.begin()).toBeNull();
    expect(await requests()).toEqual([]);
    // And the one with the code is not held up by it.
    const good = new Newcomer();
    await good.enter(d.introducer.url, code);
    expect(await good.begin()).not.toBeNull();
  });

  it("refuses a device that chose its half after seeing the box's", async () => {
    const tv = new Newcomer();
    await tv.enter(d.introducer.url, code);
    expect(await tv.begin({}, newAgreementKey())).toBeNull();
    expect(await requests()).toEqual([]);
    for (const wrong of [
      { platform: "cli" },
      { deviceName: "" },
      { ringKey: "x" },
      { nonce: b64(randomBytes(32)) },
    ]) {
      const next = new Newcomer();
      await next.enter(d.introducer.url, code);
      expect([wrong, await next.begin(wrong)]).toEqual([wrong, null]);
      next.line.close();
    }
    expect(await requests()).toEqual([]);
    // Five tries were five: whoever has the code and goes on is stopped.
    const late = new Newcomer();
    await late.enter(d.introducer.url, code);
    expect(await late.begin()).toBeNull();
  });

  it("gives an introducer in the middle other digits, even with the code", async () => {
    // It has the code, and speaks to each side as if it were the other.
    const toBox = new Newcomer();
    await toBox.enter(d.introducer.url, code);
    const boxDigits = await toBox.begin();
    const device = { agreement: newAgreementKey(), nonce: randomBytes(32) };
    const middle = { agreement: newAgreementKey(), nonce: randomBytes(32) };
    const toDevice = pairingSecrets(
      agree(device.agreement, rawPublic(middle.agreement)),
      toBox.key,
      transcriptHash({
        room: toBox.room,
        commitment: pairingCommitment(rawPublic(device.agreement), device.nonce),
        boxAgreement: rawPublic(middle.agreement),
        boxNonce: middle.nonce,
        boxKey: d.keys.boxPublic,
        deviceAgreement: rawPublic(device.agreement),
        deviceNonce: device.nonce,
        ringKey: rawPublic(toBox.ring),
        deviceName: "Far Apple TV",
        platform: "tvos",
      }),
    );
    expect(toDevice.comparison).not.toBe(boxDigits);
    // The manager types what is on the device's screen, and the box turns it away.
    const [waiting] = await requests();
    const reply = await d.f.atHome(
      d.f.manager.token,
      "POST",
      `/v1/outside/pairing/${waiting?.id ?? ""}/approve`,
      { comparison: toDevice.comparison },
    );
    expect(reply.status).toBe(409);
    expect(await toBox.collect()).toEqual({ status: "refused" });
  });

  it("works once, for one device", async () => {
    const one = new Newcomer();
    await one.enter(d.introducer.url, code);
    expect(await one.begin()).not.toBeNull();
    const two = new Newcomer();
    await two.enter(d.introducer.url, code);
    expect(await two.begin()).toBeNull();
    // The relay's way in is the same window, so that is over too.
    const http = await d.f.ask("POST", "/v1/outside-pairing", {
      body: { code, deviceName: "Third", platform: "ios" },
    });
    expect(http.status).toBe(404);
    await d.f.atHome(d.f.manager.token, "DELETE", "/v1/outside/window");
    expect(await one.line.next()).toBe(1000);
  });

  it("brings an invited household's first device in as its manager", async () => {
    // The owner's window is closed first: the room then is the invitation's.
    await d.f.atHome(d.f.manager.token, "DELETE", "/v1/outside/window");
    const made = await d.f.atHome(d.f.manager.token, "POST", "/v1/households", {
      name: "The neighbours",
    });
    expect(made.status).toBe(201);
    const { household, invite } = made.json<{
      household: { id: string };
      invite: { code: string; link: string };
    }>();
    const link = new URL(invite.link);
    expect([link.protocol, link.host]).toEqual(["lobby:", "pair"]);
    expect(link.searchParams.get("c")).toBe(invite.code);
    expect(link.searchParams.get("i")).toBe(d.introducer.url);
    expect(invite.link).toContain("h=The%20neighbours");
    // After a restart, the pairing knows it again from the catalogue, with its room.
    const { room } = await pairingCode(readCode(invite.code) ?? "");
    const again = new OutsidePairing(d.f.devices, d.f.now, {
      invites: new Invites(d.f.db, d.f.now),
    });
    expect(again.openings().map((one) => [one.householdId, one.room])).toEqual([
      [household.id, room],
    ]);
    await until(async () => {
      const line = new Line(`${d.introducer.url}/v1/pair/${room}`);
      const said = await line.next();
      line.close();
      return typeof said !== "number";
    });
    const phone = new Newcomer();
    expect(await phone.enter(d.introducer.url, invite.code)).toBeNull();
    const digits = await phone.begin();
    const [waiting] = await requests();
    expect(waiting).toMatchObject({ householdId: household.id, invited: true, comparison: digits });
    const approved = await d.f.atHome(
      d.f.manager.token,
      "POST",
      `/v1/outside/pairing/${waiting?.id ?? ""}/approve`,
      { comparison: digits },
    );
    expect(approved.json<{ access: string }>().access).toBe("householdAdmin");
    const answer = (await phone.collect()) as unknown as { status: string; device: Device };
    expect(answer.status).toBe("approved");
    expect(answer.device).toMatchObject({
      role: "viewer",
      access: "householdAdmin",
      householdId: household.id,
    });
  });

  it("is over when the window is, when the manager says no and when all is turned off", async () => {
    const denied = new Newcomer();
    await denied.enter(d.introducer.url, code);
    await denied.begin();
    const [waiting] = await requests();
    await d.f.atHome(d.f.manager.token, "DELETE", `/v1/outside/pairing/${waiting?.id ?? ""}`);
    expect(await denied.collect()).toEqual({ status: "refused" });

    code = await window();
    const late = new Newcomer();
    await late.enter(d.introducer.url, code);
    d.f.clock.ahead += 11 * 60_000;
    expect(await late.line.next()).toBe(1000);
    d.f.clock.ahead = 0;

    code = await window();
    const off = new Newcomer();
    await off.enter(d.introducer.url, code);
    await d.f.outside.setEnabled(false);
    expect(await off.line.next()).toBeTypeOf("number");
  });
});

/** Whether a device with this code finds a room at the introducer now. */
async function roomIsOpen(introducer: string, code: string): Promise<boolean> {
  const { room } = await pairingCode(readCode(code) ?? "");
  const line = new Line(`${introducer}/v1/pair/${room}`);
  const said = await line.next();
  line.close();
  return typeof said !== "number";
}

/** Several codes of one server, and of two, open at the same time. */
describe("pairing with several codes open", () => {
  const servers: DirectFixture[] = [];
  let shared: RunningIntroducer | null = null;
  afterEach(async () => {
    for (const one of servers.splice(0)) await one.stop();
    await shared?.stop();
    shared = null;
  });

  const server = async (env?: Record<string, string>): Promise<DirectFixture> => {
    const one = new DirectFixture();
    servers.push(one);
    if (env !== undefined) shared = await runIntroducer([one.keys.boxId], 0, env);
    await one.start(NO_PROGRAM, {}, shared ?? undefined);
    return one;
  };
  const invite = async (at: DirectFixture): Promise<{ id: string; code: string }> => {
    const made = await at.f.atHome(at.f.manager.token, "POST", "/v1/households/owner/invites", {
      access: "viewer",
    });
    expect(made.status).toBe(201);
    return made.json<{ id: string; code: string }>();
  };
  const window = async (at: DirectFixture): Promise<string> => {
    const made = await at.f.atHome(at.f.manager.token, "POST", "/v1/outside/window", {});
    expect(made.status).toBe(201);
    return made.json<{ code: string }>().code;
  };
  const allOpen = async (at: DirectFixture, codes: string[]): Promise<void> => {
    await until(async () => {
      for (const code of codes) if (!(await roomIsOpen(at.introducer.url, code))) return false;
      return true;
    });
  };
  const asked = async (at: DirectFixture): Promise<OutsidePairingRequest[]> =>
    (await at.f.atHome(at.f.manager.token, "GET", "/v1/outside")).json<OutsideStatus>().requests;
  /** Pairs a device with each code, all at the same time, and the manager says yes to each. */
  const pairAll = async (at: DirectFixture, codes: string[]): Promise<void> => {
    const devices = codes.map(() => new Newcomer());
    expect(
      await Promise.all(
        devices.map((one, index) => one.enter(at.introducer.url, codes[index] ?? "")),
      ),
    ).toEqual(codes.map(() => null));
    const digits = await Promise.all(devices.map((one) => one.begin()));
    for (const one of digits) expect(one).toMatch(/^\d{6}$/);
    // This server's, and only those.
    expect((await asked(at)).map((one) => one.comparison).sort()).toEqual([...digits].sort());
    for (const [index, one] of devices.entries()) {
      const waiting = (await asked(at)).find((request) => request.comparison === digits[index]);
      const approved = await at.f.atHome(
        at.f.manager.token,
        "POST",
        `/v1/outside/pairing/${waiting?.id ?? ""}/approve`,
        { comparison: digits[index] },
      );
      expect(approved.status).toBe(200);
      expect(await one.collect()).toMatchObject({ status: "approved" });
      expect(await one.collect({ done: true })).toEqual({ status: "done" });
      one.line.close();
    }
  };

  it("lets every code pair, the oldest too, all at the same time", async () => {
    const at = await server();
    const first = await invite(at);
    const second = await invite(at);
    const opened = await window(at);
    const last = await invite(at);
    const codes = [first.code, second.code, opened, last.code];
    await allOpen(at, codes);
    await pairAll(at, codes);
    // Each was used once, and its room is gone with it.
    for (const code of codes) expect(await roomIsOpen(at.introducer.url, code)).toBe(false);
  });

  it("closes only the room of the code that is taken back", async () => {
    const at = await server();
    const [one, two, three] = [await invite(at), await invite(at), await invite(at)];
    await allOpen(at, [one.code, two.code, three.code]);
    const taken = await at.f.atHome(
      at.f.manager.token,
      "DELETE",
      `/v1/households/owner/invites/${two.id}`,
    );
    expect(taken.status).toBe(204);
    await until(async () => !(await roomIsOpen(at.introducer.url, two.code)));
    expect(await roomIsOpen(at.introducer.url, one.code)).toBe(true);
    expect(await roomIsOpen(at.introducer.url, three.code)).toBe(true);
    await pairAll(at, [three.code, one.code]);
  });

  it("says every room again when the introducer was away, and when the road was off", async () => {
    const at = await server();
    const codes = [(await invite(at)).code, (await invite(at)).code, (await invite(at)).code];
    await allOpen(at, codes);
    const { port } = at.introducer;
    await at.introducer.stop();
    await until(() => !at.direct.directStatus().introducer);
    at.introducer = await runIntroducer([at.keys.boxId], port);
    await until(() => at.direct.directStatus().introducer);
    await allOpen(at, codes);
    // Off closes every room. Invitations outlive it: their rooms are there again when it is on.
    await at.f.outside.setEnabled(false);
    await until(async () => !(await roomIsOpen(at.introducer.url, codes[0] ?? "")));
    for (const code of codes) expect(await roomIsOpen(at.introducer.url, code)).toBe(false);
    await at.f.outside.setEnabled(true);
    await until(() => at.direct.directStatus().introducer);
    await allOpen(at, codes);
    await pairAll(at, codes);
  });

  it("keeps two servers' codes apart at one introducer", async () => {
    const one = new DirectFixture();
    const two = new DirectFixture();
    servers.push(one, two);
    shared = await runIntroducer([one.keys.boxId, two.keys.boxId]);
    await one.start(NO_PROGRAM, {}, shared);
    await two.start(NO_PROGRAM, {}, shared);
    const ofOne = [(await invite(one)).code, await window(one), (await invite(one)).code];
    const ofTwo = [(await invite(two)).code, (await invite(two)).code, await window(two)];
    await allOpen(one, ofOne);
    await allOpen(two, ofTwo);
    // Everyone at once, and each server hears only its own.
    await Promise.all([pairAll(one, ofOne), pairAll(two, ofTwo)]);
  });

  it("still lets the newest code pair with an introducer of one room, as before", async () => {
    const at = await server({ ROOMS_PER_BOX: "1" });
    const older = await invite(at);
    const newest = await invite(at);
    await allOpen(at, [newest.code]);
    expect(await roomIsOpen(at.introducer.url, older.code)).toBe(false);
    await pairAll(at, [newest.code]);
    // Then the older one has the room.
    await allOpen(at, [older.code]);
    await pairAll(at, [older.code]);
  });
});

describe("the box's line", () => {
  it("waits longer every time, and not as long as any other", async () => {
    const dir = makeTempDir("lobby-keys-");
    let tries = 0;
    const server = createServer((_request, response) => {
      response.end();
    });
    server.on("upgrade", (_request, socket) => {
      tries += 1;
      socket.destroy();
    });
    await new Promise<void>((done) => server.listen(0, "127.0.0.1", done));
    const bound = server.address();
    const port = bound !== null && typeof bound === "object" ? bound.port : 0;
    const client = new IntroducerClient({
      url: `ws://127.0.0.1:${port}`,
      keys: new BoxKeys(dir),
      ringKeys: () => [],
      heard: () => undefined,
      random: () => 0,
    });
    client.start();
    // Half a second, one, two: the fourth would come after three and a half.
    await new Promise((done) => setTimeout(done, 2_700));
    client.stop();
    expect(tries).toBe(3);
    await new Promise((done) => setTimeout(done, 2_200));
    expect(tries).toBe(3);
    await new Promise((done) => server.close(done));
    removeDir(dir);
  });
});

describe("the box's keys", () => {
  let dir: string;
  beforeEach(() => (dir = makeTempDir("lobby-keys-")));
  afterEach(() => {
    removeDir(dir);
  });

  it("are for nobody else on the machine, and stay the same", () => {
    const keys = new BoxKeys(dir);
    const path = join(dir, "direct", "keys.json");
    expect(statSync(path).mode & 0o777).toBe(0o600);
    expect(statSync(join(dir, "direct")).mode & 0o777).toBe(0o700);
    const again = new BoxKeys(dir);
    expect([again.boxId, again.fingerprints]).toEqual([keys.boxId, keys.fingerprints]);
    chmodSync(path, 0o644);
    expect(() => new BoxKeys(dir)).toThrow(/mode/);
    chmodSync(path, 0o600);
    writeFileSync(path, "{");
    // Never replaced by itself: that would lock every device out without a word.
    expect(() => new BoxKeys(dir)).toThrow(/cannot be read/);
    expect(readFileSync(path, "utf8")).toBe("{");
  });

  it("have a certificate that Node and TLS libraries read, and whose key fits", () => {
    const made = makeCertificate(Date.UTC(2026, 10, 25));
    const read = new X509Certificate(made.certificate);
    expect(read.subject).toBe("CN=lobby-direct");
    expect(read.subjectAltName).toBe("DNS:lobby-direct");
    expect(read.verify(read.publicKey)).toBe(true);
    expect(read.validFromDate.getTime()).toBe(Date.UTC(2026, 10, 24));
    expect(read.fingerprint256.replaceAll(":", "").toLowerCase()).toBe(
      Buffer.from(fingerprint(made.certificate), "base64url").toString("hex"),
    );
    expect(fingerprint(makeCertificate(0).certificate)).not.toBe(fingerprint(made.certificate));
  });

  it("give every certificate time to be known before it is used", () => {
    let now = Date.UTC(2026, 0, 1);
    const keys = new BoxKeys(dir, () => now);
    const [first, second] = keys.fingerprints;
    now += CERTIFICATE_MS - 1;
    expect(keys.rotateIfDue()).toBe(false);
    now += 1;
    expect(keys.rotateIfDue()).toBe(true);
    expect(keys.fingerprints[0]).toBe(second);
    expect(keys.fingerprints).not.toContain(first);
    expect(new BoxKeys(dir).fingerprints).toEqual(keys.fingerprints);
    // By hand, twice in a row: the one after is new, and waits its time.
    keys.rotate();
    now += CERTIFICATE_MS;
    expect(keys.rotateIfDue()).toBe(true);
    expect(OVERLAP_MS).toBeLessThan(CERTIFICATE_MS);
  });
});

describe("descriptions", () => {
  it("are made again from what is known in them", () => {
    const dirty = [
      "v=0",
      "a=ice-ufrag:abcd",
      "a=ice-pwd:abcdefghijklmnopqrstuv",
      "a=ice-options:ice2",
      "a=candidate:1 1 UDP 2122317823 192.168.1.20 5000 typ host",
      "a=candidate:2 1 UDP 1678769919 8.8.4.4 5001 typ srflx raddr 192.168.1.20 rport 5000",
      "a=candidate:3 1 UDP 1678769919 home.example.com 5001 typ host",
      "a=candidate:4 1 TCP 1678769919 8.8.4.4 5001 typ host tcptype active",
      "a=candidate:5 1 UDP 1678769919 8.8.4.4 0 typ host",
      "a=candidate:6 1 UDP 1678769919 2a00:1450:4009::1 5002 typ host",
      "a=candidate:7 2 UDP 1678769919 8.8.4.4 5001 typ host",
    ].join("\r\n");
    expect(cleanSdp(dirty, isPublicAddress)).toBe(
      [
        "a=ice-ufrag:abcd",
        "a=ice-pwd:abcdefghijklmnopqrstuv",
        "a=candidate:2 1 UDP 1678769919 8.8.4.4 5001 typ srflx raddr 0.0.0.0 rport 0",
        "a=candidate:6 1 UDP 1678769919 2a00:1450:4009::1 5002 typ host",
        "a=end-of-candidates",
        "",
      ].join("\r\n"),
    );
    for (const wrong of [
      null,
      "",
      "a=ice-ufrag:abcd",
      `${dirty}\r\na=ice-ufrag:other`,
      "a".repeat(9_000),
    ]) {
      expect(cleanSdp(wrong, isPublicAddress)).toBeNull();
    }
  });

  it("know an address of the internet from one that is not", () => {
    for (const address of [
      "8.8.8.8",
      "100.128.0.1",
      "172.32.0.1",
      "2a00:1450::1",
      "2606:4700::1",
    ]) {
      expect([address, isPublicAddress(address)]).toEqual([address, true]);
    }
    for (const address of [
      "10.0.0.1",
      "100.64.0.1",
      "127.0.0.1",
      "169.254.1.1",
      "172.16.0.1",
      "192.168.0.1",
      "192.0.0.8",
      "198.18.0.1",
      "203.0.113.7",
      "224.0.0.1",
      "255.255.255.255",
      "0.0.0.0",
      "::1",
      "::",
      "fe80::1",
      "fd7a:115c:a1e0::1",
      "ff02::1",
      "::ffff:192.168.0.1",
      "64:ff9b::a00:1",
      "2001:db8::1",
      "2002:a00:1::1",
      "name.local",
    ]) {
      expect([address, isPublicAddress(address)]).toEqual([address, false]);
    }
  });
});

describe("the config", () => {
  const read = (direct: unknown): OutsideConfig | null =>
    readOutsideConfig(
      { enabled: true, name: "lobby.example.com", direct },
      { host: "127.0.0.1", port: 8674 },
      (path) => `/base/${path}`,
    );

  it("has no direct road unless it says so", () => {
    expect(read(undefined)?.direct).toBeNull();
    expect(read({ introducer: "wss://introducer.example.com/" })?.direct).toEqual({
      introducer: "wss://introducer.example.com",
      stun: [],
      turn: null,
      bind: null,
      maxUploadMbit: null,
      binary: "/base/bin/lobby-direct",
    });
  });

  it("says what is wrong", () => {
    const introducer = "wss://introducer.example.com";
    const turn = { host: "relay.example.com", secret: "a secret of enough length" };
    expect(read({ introducer, turn })?.direct?.turn).toEqual({ ...turn, port: 3478 });
    for (const [wrong, why] of [
      [5, /must be an object/],
      [{}, /introducer/],
      [{ introducer: "https://introducer.example.com" }, /introducer/],
      [{ introducer: "ws://introducer.example.com" }, /introducer/],
      [{ introducer: "wss://user:pass@introducer.example.com" }, /introducer/],
      [{ introducer, stun: "stun.example.com" }, /stun/],
      [{ introducer, stun: [{ host: "" }] }, /stun\[0\].host/],
      [{ introducer, stun: [{ host: "stun.example.com", port: 0 }] }, /stun\[0\].port/],
      [{ introducer, turn: { host: "relay.example.com" } }, /secret/],
      [{ introducer, turn: { ...turn, secret: "short" } }, /secret/],
      [{ introducer, turn: { ...turn, host: "turn.cloudflare.com" } }, /never Cloudflare/],
      [{ introducer, bind: "eth0" }, /bind/],
      [{ introducer, maxUploadMbit: 0 }, /maxUploadMbit/],
    ] as const) {
      expect(() => read(wrong)).toThrow(why);
    }
  });

  it("reads the relay's secret from a file that nobody else can read", () => {
    const dir = makeTempDir("lobby-secret-");
    const path = join(dir, "turn.secret");
    writeFileSync(path, "a secret of enough length\n", { mode: 0o600 });
    const readFile = (): unknown =>
      readOutsideConfig(
        {
          enabled: true,
          name: "lobby.example.com",
          direct: {
            introducer: "wss://introducer.example.com",
            turn: { host: "relay.example.com", secretFile: path },
          },
        },
        { host: "127.0.0.1", port: 8674 },
        (one) => one,
      )?.direct?.turn?.secret;
    expect(readFile()).toBe("a secret of enough length");
    chmodSync(path, 0o644);
    expect(readFile).toThrow(/600/);
    removeDir(dir);
  });
});

describe("the vectors in docs", () => {
  it("are what this code makes", async () => {
    const made = await vectors();
    if (process.env["WRITE_VECTORS"] === "1") {
      writeFileSync(VECTORS, `${JSON.stringify(made, null, 2)}\n`);
    }
    expect(JSON.parse(readFileSync(VECTORS, "utf8"))).toEqual(made);
  });
});

/** Everything an app has to get right, from fixed numbers. Nothing here is anybody's key. */
async function vectors(): Promise<object> {
  const bytes = (start: number, length = 32): Buffer =>
    Buffer.from(Array.from({ length }, (_, index) => (start + index) & 255));
  const nonce = (start: number): Buffer => bytes(start, 12);
  const boxKey = privateKey("ed25519", bytes(1));
  const ring = privateKey("ed25519", bytes(33));
  const boxAgreement = privateKey("x25519", bytes(65));
  const deviceAgreement = privateKey("x25519", bytes(97));
  const boxId = boxIdOf(rawPublic(boxKey));
  const ringKey = b64(rawPublic(ring));
  const shared = agree(deviceAgreement, rawPublic(boxAgreement));
  const secret = enrolledSecret(
    shared,
    rawPublic(deviceAgreement),
    rawPublic(boxAgreement),
    boxId,
    ringKey,
  );
  const { sign } = await import("node:crypto");
  const signed = (key: KeyObject, message: string): object => ({
    message,
    signature: b64(sign(null, Buffer.from(message), key)),
  });
  const challenge = b64(bytes(129));
  const session = b64(bytes(161, 16));
  const place = { boxId, ringKey, session };
  const [deviceNonce, boxNonce] = [bytes(177), bytes(209)];
  const envelope = (key: Buffer, aad: string, plain: string, at: number): object => ({
    key: b64(key),
    aad,
    plain,
    nonce: b64(nonce(at)),
    sealed: sealBytes(key, aad, Buffer.from(plain), nonce(at)),
  });
  const code = "0123456789ABCDEF";
  const stretched = await pairingCode(code);
  const { room } = stretched;
  const commitment = pairingCommitment(rawPublic(deviceAgreement), deviceNonce);
  const transcript = transcriptHash({
    room,
    commitment,
    boxAgreement: rawPublic(boxAgreement),
    boxNonce,
    boxKey: rawPublic(boxKey),
    deviceAgreement: rawPublic(deviceAgreement),
    deviceNonce,
    ringKey: rawPublic(ring),
    deviceName: "Télé",
    platform: "tvos",
  });
  const pairing = pairingSecrets(shared, stretched.key, transcript);
  const exporter = bytes(5);
  const connect = `${DIRECT}|connect|${boxId}|${b64(exporter)}`;
  return {
    about:
      "Test vectors for docs/api.md, Direct. All binary values are base64url without padding. Ed25519 signatures are deterministic in Node; CryptoKit's are not, so verify them.",
    keys: {
      boxSeed: b64(bytes(1)),
      boxKey: b64(rawPublic(boxKey)),
      boxId,
      ringSeed: b64(bytes(33)),
      ringKey,
      boxAgreementPrivate: b64(bytes(65)),
      boxAgreementKey: b64(rawPublic(boxAgreement)),
      deviceAgreementPrivate: b64(bytes(97)),
      deviceAgreementKey: b64(rawPublic(deviceAgreement)),
      shared: b64(shared),
    },
    enrolment: { secret: b64(secret) },
    introducer: {
      nonce: challenge,
      device: signed(ring, `lobby-introducer/1|device|${boxId}|${challenge}`),
      box: signed(boxKey, `lobby-introducer/1|box|${boxId}|${challenge}`),
    },
    introduction: {
      session,
      deviceNonce: b64(deviceNonce),
      boxNonce: b64(boxNonce),
      hello: envelope(
        introductionKeys.hello(secret),
        introductionAad(place, "d2b", 0),
        JSON.stringify({ t: "hello", nonce: b64(deviceNonce) }),
        1,
      ),
      welcome: envelope(
        introductionKeys.welcome(secret, deviceNonce),
        introductionAad(place, "b2d", 0),
        JSON.stringify({
          t: "welcome",
          nonce: b64(boxNonce),
          fingerprints: [b64(bytes(7))],
          ice: { stun: [{ host: "stun.example.com", port: 3478 }], turn: null },
        }),
        2,
      ),
      offer: envelope(
        introductionKeys.session(secret, deviceNonce, boxNonce, "d2b"),
        introductionAad(place, "d2b", 1),
        JSON.stringify({ t: "offer", sdp: SDP }),
        3,
      ),
      answer: envelope(
        introductionKeys.session(secret, deviceNonce, boxNonce, "b2d"),
        introductionAad(place, "b2d", 1),
        JSON.stringify({ t: "answer", sdp: SDP }),
        4,
      ),
    },
    connection: {
      alpn: "lobby-direct/1",
      exporterLabel: "EXPORTER-lobby-direct-1",
      exporter: b64(exporter),
      ...signed(ring, connect),
      frame: b64(
        Buffer.concat([
          Buffer.from("LDA1"),
          rawPublic(ring),
          sign(null, Buffer.from(connect), ring),
        ]),
      ),
    },
    pairing: {
      code,
      scrypt: { salt: "lobby-pair/1|code", N: 32768, r: 8, p: 1, length: 64 },
      room,
      codeKey: b64(stretched.key),
      keys: {
        d2b: b64(pairingKeys.code(stretched.key, "d2b")),
        b2d: b64(pairingKeys.code(stretched.key, "b2d")),
      },
      session,
      commitment: b64(commitment),
      start: envelope(
        pairingKeys.code(stretched.key, "d2b"),
        pairingAad(room, session, "start"),
        JSON.stringify({ commitment: b64(commitment) }),
        5,
      ),
      deviceName: "Télé",
      platform: "tvos",
      transcript: b64(transcript),
      sessionKeys: { d2b: b64(pairing.d2b), b2d: b64(pairing.b2d) },
      secret: b64(pairing.secret),
      comparison: pairing.comparison,
      waiting: envelope(
        pairing.b2d,
        pairingAad(room, session, "waiting"),
        JSON.stringify({ status: "pending", expiresAt: 1795530600000 }),
        6,
      ),
      collect: envelope(
        pairing.d2b,
        pairingAad(room, session, "collect"),
        JSON.stringify({ nonce: b64(bytes(9, 16)) }),
        7,
      ),
    },
  };
}

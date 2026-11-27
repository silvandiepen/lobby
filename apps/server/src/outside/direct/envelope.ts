// SPDX-License-Identifier: MPL-2.0
import {
  createCipheriv,
  createDecipheriv,
  createHash,
  createPrivateKey,
  createPublicKey,
  diffieHellman,
  generateKeyPairSync,
  hkdfSync,
  randomBytes,
  scrypt,
  type KeyObject,
} from "node:crypto";

/*
 * Everything two ends say to each other through the introducer. The exact bytes are in
 * docs/api.md ("Direct") and docs/direct-vectors.json, which the apps test against too.
 */

export const DIRECT = "lobby-direct/1";
export const PAIR = "lobby-pair/1";
export const INTRODUCER = "lobby-introducer/1";

export type Direction = "d2b" | "b2d";

const KEY = 32;
const NONCE = 12;
const TAG = 16;
/** What the introducer passes on, at most. */
export const MAX_ENVELOPE = 16_384;

export const b64 = (data: Uint8Array): string => Buffer.from(data).toString("base64url");

/** Bytes of exactly this length from base64url, in its one way of writing it. Null otherwise. */
export function unb64(text: unknown, length: number): Buffer | null {
  if (typeof text !== "string" || text.length > Math.ceil((length * 4) / 3)) return null;
  const data = Buffer.from(text, "base64url");
  return data.length === length && b64(data) === text ? data : null;
}

export function derive(secret: Uint8Array, salt: Uint8Array, info: string, length = KEY): Buffer {
  return Buffer.from(hkdfSync("sha256", secret, salt, info, length));
}

export function seal(
  key: Uint8Array,
  aad: string,
  value: unknown,
  nonce: Uint8Array = randomBytes(NONCE),
): string {
  return sealBytes(key, aad, Buffer.from(JSON.stringify(value)), nonce);
}

export function sealBytes(
  key: Uint8Array,
  aad: string,
  plain: Uint8Array,
  nonce: Uint8Array = randomBytes(NONCE),
): string {
  const cipher = createCipheriv("chacha20-poly1305", key, nonce, { authTagLength: TAG });
  cipher.setAAD(Buffer.from(aad), { plaintextLength: plain.length });
  const body = Buffer.concat([cipher.update(plain), cipher.final()]);
  return b64(Buffer.concat([nonce, body, cipher.getAuthTag()]));
}

/** @throws Error when it was not sealed with this key for this place */
export function openBytes(key: Uint8Array, aad: string, text: string): Buffer {
  const data = Buffer.from(text, "base64url");
  if (text.length > MAX_ENVELOPE || data.length < NONCE + TAG) throw new Error("not an envelope");
  const cipher = createDecipheriv("chacha20-poly1305", key, data.subarray(0, NONCE), {
    authTagLength: TAG,
  });
  const body = data.subarray(NONCE, -TAG);
  cipher.setAAD(Buffer.from(aad), { plaintextLength: body.length });
  cipher.setAuthTag(data.subarray(-TAG));
  return Buffer.concat([cipher.update(body), cipher.final()]);
}

/** The JSON object in an envelope. Null when it is not one, or not for here. */
export function open(key: Uint8Array, aad: string, text: unknown): Record<string, unknown> | null {
  if (typeof text !== "string") return null;
  try {
    const value: unknown = JSON.parse(openBytes(key, aad, text).toString("utf8"));
    if (typeof value !== "object" || value === null || Array.isArray(value)) return null;
    return value as Record<string, unknown>;
  } catch {
    return null;
  }
}

// ---- An introduction: one device that is known ----

export interface Introduction {
  boxId: string;
  /** The device's public ring key. */
  ringKey: string;
  /** The introducer's name for this conversation. */
  session: string;
}

/** What an envelope is bound to: who, with whom, which conversation, which way, which message. */
export function introductionAad(one: Introduction, direction: Direction, count: number): string {
  return [DIRECT, one.boxId, one.ringKey, one.session, direction, String(count)].join("|");
}

const NOTHING = Buffer.alloc(0);

export const introductionKeys = {
  hello: (secret: Uint8Array): Buffer => derive(secret, NOTHING, `${DIRECT}|hello|d2b`),
  /** Only an answer to this very hello opens with it. */
  welcome: (secret: Uint8Array, deviceNonce: Uint8Array): Buffer =>
    derive(secret, deviceNonce, `${DIRECT}|welcome|b2d`),
  /** Both ends put something new in, so nothing that was said before opens with it. */
  session: (
    secret: Uint8Array,
    deviceNonce: Uint8Array,
    boxNonce: Uint8Array,
    direction: Direction,
  ): Buffer =>
    derive(secret, Buffer.concat([deviceNonce, boxNonce]), `${DIRECT}|session|${direction}`),
};

// ---- Keys ----

const SPKI = { ed25519: "302a300506032b6570032100", x25519: "302a300506032b656e032100" } as const;
const PKCS8 = {
  ed25519: "302e020100300506032b657004220420",
  x25519: "302e020100300506032b656e04220420",
} as const;

export function publicKey(kind: keyof typeof SPKI, raw: Uint8Array): KeyObject {
  return createPublicKey({
    key: Buffer.concat([Buffer.from(SPKI[kind], "hex"), raw]),
    format: "der",
    type: "spki",
  });
}

export function privateKey(kind: keyof typeof PKCS8, raw: Uint8Array): KeyObject {
  return createPrivateKey({
    key: Buffer.concat([Buffer.from(PKCS8[kind], "hex"), raw]),
    format: "der",
    type: "pkcs8",
  });
}

export function rawPublic(key: KeyObject): Buffer {
  const whole = (key.type === "private" ? createPublicKey(key) : key).export({
    format: "der",
    type: "spki",
  });
  return whole.subarray(-KEY);
}

export function newAgreementKey(): KeyObject {
  return generateKeyPairSync("x25519").privateKey;
}

/** @throws Error for a key that gives nothing but zeroes */
export function agree(own: KeyObject, other: Uint8Array): Buffer {
  return diffieHellman({ privateKey: own, publicKey: publicKey("x25519", other) });
}

/** The box's name: the hash of its key, so nobody else can have it. */
export function boxIdOf(boxKey: Uint8Array): string {
  return b64(createHash("sha256").update(boxKey).digest());
}

/** What a device and the box share after enrolling at home. */
export function enrolledSecret(
  shared: Uint8Array,
  deviceAgreement: Uint8Array,
  boxAgreement: Uint8Array,
  boxId: string,
  ringKey: string,
): Buffer {
  return derive(
    shared,
    Buffer.concat([deviceAgreement, boxAgreement]),
    `${DIRECT}|secret|${boxId}|${ringKey}`,
  );
}

// ---- Pairing: a device that only has a code ----

/** 32 MB and about a tenth of a second on the Pi. */
export const SCRYPT = { N: 32_768, r: 8, p: 1, maxmem: 48 * 1024 * 1024 } as const;

export interface PairingCode {
  /** Where the two meet at the introducer. Says nothing about the key. */
  room: string;
  key: Buffer;
}

/** What a code stands for. `code` is the sixteen characters, as `readCode` gives them. */
export function pairingCode(code: string): Promise<PairingCode> {
  return new Promise((resolve, reject) => {
    scrypt(Buffer.from(code, "ascii"), `${PAIR}|code`, 64, SCRYPT, (error, made) => {
      if (error) reject(error);
      else resolve({ room: b64(made.subarray(0, 16)), key: made.subarray(32, 64) });
    });
  });
}

export function pairingAad(room: string, session: string, step: string): string {
  return [PAIR, room, session, step].join("|");
}

export const pairingKeys = {
  code: (key: Uint8Array, direction: Direction): Buffer =>
    derive(key, NOTHING, `${PAIR}|code|${direction}`),
};

export function pairingCommitment(agreement: Uint8Array, nonce: Uint8Array): Buffer {
  return createHash("sha256").update(`${PAIR}|commit|`).update(agreement).update(nonce).digest();
}

export interface PairingTranscript {
  room: string;
  commitment: Uint8Array;
  boxAgreement: Uint8Array;
  boxNonce: Uint8Array;
  boxKey: Uint8Array;
  deviceAgreement: Uint8Array;
  deviceNonce: Uint8Array;
  ringKey: Uint8Array;
  deviceName: string;
  platform: string;
}

/** Every part with its length in front, so that no two conversations read the same. */
export function transcriptHash(one: PairingTranscript): Buffer {
  const hash = createHash("sha256");
  const parts = [
    Buffer.from(PAIR),
    Buffer.from(one.room),
    one.commitment,
    one.boxAgreement,
    one.boxNonce,
    one.boxKey,
    one.deviceAgreement,
    one.deviceNonce,
    one.ringKey,
    Buffer.from(one.deviceName, "utf8"),
    Buffer.from(one.platform),
  ];
  for (const part of parts) {
    const length = Buffer.alloc(2);
    length.writeUInt16BE(part.length);
    hash.update(length).update(part);
  }
  return hash.digest();
}

export interface PairingSecrets {
  d2b: Buffer;
  b2d: Buffer;
  /** What both keep afterwards. */
  secret: Buffer;
  /** Six digits on both screens. */
  comparison: string;
}

export function pairingSecrets(
  shared: Uint8Array,
  codeKey: Uint8Array,
  transcript: Uint8Array,
): PairingSecrets {
  const from = Buffer.concat([shared, codeKey]);
  const digits = derive(from, transcript, `${PAIR}|comparison`, 8).readBigUInt64BE() % 1_000_000n;
  return {
    d2b: derive(from, transcript, `${PAIR}|session|d2b`),
    b2d: derive(from, transcript, `${PAIR}|session|b2d`),
    secret: derive(from, transcript, `${PAIR}|secret`),
    comparison: digits.toString().padStart(6, "0"),
  };
}

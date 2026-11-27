// SPDX-License-Identifier: MPL-2.0
import {
  chmodSync,
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { generateKeyPairSync, randomBytes, sign, type KeyObject } from "node:crypto";
import { join } from "node:path";
import { b64, boxIdOf, privateKey, rawPublic, unb64 } from "./envelope.ts";
import { fingerprint, makeCertificate } from "./certificate.ts";

const DAY = 86_400_000;
/** How long a certificate is used. */
export const CERTIFICATE_MS = 365 * DAY;
/** How long the next one was known to devices before it takes over. */
export const OVERLAP_MS = 60 * DAY;

interface StoredCertificate {
  certificate: string;
  key: string;
  madeAt: number;
  usedSince: number | null;
}

interface Stored {
  version: 1;
  boxKey: string;
  wrapKey: string;
  current: StoredCertificate;
  next: StoredCertificate;
}

export const DIRECT_DIR = "direct";
const FILE = "keys.json";

/**
 * What makes this server itself on the direct road. Kept beside the catalogue, only for the user
 * that runs the server, and never in a backup: a backup in the wrong hands is not the box.
 */
export class BoxKeys {
  private readonly path: string;
  private readonly now: () => number;
  private stored: Stored;
  private readonly boxKey: KeyObject;

  /** @throws Error when there are keys that cannot be used, so they are never replaced silently */
  constructor(dataDir: string, now: () => number = Date.now) {
    this.now = now;
    const dir = join(dataDir, DIRECT_DIR);
    this.path = join(dir, FILE);
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    chmodSync(dir, 0o700);
    this.stored = existsSync(this.path) ? read(this.path) : this.make();
    const seed = unb64(this.stored.boxKey, 32);
    if (!seed) throw new Error("The keys of the direct connection are damaged.");
    this.boxKey = privateKey("ed25519", seed);
  }

  get boxPublic(): Buffer {
    return rawPublic(this.boxKey);
  }

  get boxId(): string {
    return boxIdOf(this.boxPublic);
  }

  /** What the devices' secrets are locked away with. */
  get wrapKey(): Buffer {
    const key = unb64(this.stored.wrapKey, 32);
    if (!key) throw new Error("The keys of the direct connection are damaged.");
    return key;
  }

  sign(message: string): Buffer {
    return sign(null, Buffer.from(message), this.boxKey);
  }

  /** The certificates a device may meet: the one in use, and the one that comes after it. */
  get fingerprints(): string[] {
    return [this.stored.current, this.stored.next].map((one) =>
      fingerprint(Buffer.from(one.certificate, "base64url")),
    );
  }

  /** What QUIC answers with. */
  get certificate(): { chain: string[]; key: string } {
    return { chain: [this.stored.current.certificate], key: this.stored.current.key };
  }

  /** Lets the next certificate take over when it is time. Returns whether it did. */
  rotateIfDue(): boolean {
    const now = this.now();
    const { current, next } = this.stored;
    if (now - (current.usedSince ?? current.madeAt) < CERTIFICATE_MS) return false;
    if (now - next.madeAt < OVERLAP_MS) return false;
    this.rotate();
    return true;
  }

  /** Now. Devices that know of `next` notice nothing; the others are told when they ring. */
  rotate(): void {
    this.stored = {
      ...this.stored,
      current: { ...this.stored.next, usedSince: this.now() },
      next: this.newCertificate(),
    };
    this.write();
  }

  private newCertificate(): StoredCertificate {
    const made = makeCertificate(this.now());
    return {
      certificate: b64(made.certificate),
      key: b64(made.key),
      madeAt: this.now(),
      usedSince: null,
    };
  }

  private make(): Stored {
    const box = generateKeyPairSync("ed25519").privateKey.export({ format: "der", type: "pkcs8" });
    this.stored = {
      version: 1,
      boxKey: b64(box.subarray(-32)),
      wrapKey: b64(randomBytes(32)),
      current: { ...this.newCertificate(), usedSince: this.now() },
      next: this.newCertificate(),
    };
    this.write();
    return this.stored;
  }

  private write(): void {
    const part = `${this.path}.part`;
    rmSync(part, { force: true });
    writeFileSync(part, `${JSON.stringify(this.stored, null, 2)}\n`, { mode: 0o600 });
    renameSync(part, this.path);
  }
}

/** Takes the keys away: the box gets a new name, and every device has to be let in anew. */
export function forgetKeys(dataDir: string): void {
  rmSync(join(dataDir, DIRECT_DIR), { recursive: true, force: true });
}

function read(path: string): Stored {
  if ((statSync(path).mode & 0o077) !== 0) {
    throw new Error(
      "The keys of the direct connection can be read by others. Set their mode to 600.",
    );
  }
  let found: Partial<Stored>;
  try {
    found = JSON.parse(readFileSync(path, "utf8")) as Partial<Stored>;
  } catch (error) {
    throw new Error("The keys of the direct connection cannot be read.", { cause: error });
  }
  const certificate = (one: StoredCertificate | undefined): boolean =>
    typeof one?.certificate === "string" &&
    typeof one.key === "string" &&
    typeof one.madeAt === "number";
  if (
    found.version !== 1 ||
    typeof found.boxKey !== "string" ||
    typeof found.wrapKey !== "string" ||
    !certificate(found.current) ||
    !certificate(found.next)
  ) {
    throw new Error("The keys of the direct connection are damaged.");
  }
  return found as Stored;
}

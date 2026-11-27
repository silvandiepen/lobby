// SPDX-License-Identifier: MPL-2.0
import { createHash, generateKeyPairSync, randomBytes, sign } from "node:crypto";

/*
 * A self-signed certificate, written out by hand: Node reads certificates but makes none. Devices
 * compare its hash with the one they know (they ask no authority, and no date is looked at), so it
 * holds the least that a certificate can.
 */

function der(tag: number, ...parts: Buffer[]): Buffer {
  const body = Buffer.concat(parts);
  const size =
    body.length < 128
      ? Buffer.from([body.length])
      : body.length < 256
        ? Buffer.from([0x81, body.length])
        : Buffer.from([0x82, body.length >> 8, body.length & 255]);
  return Buffer.concat([Buffer.from([tag]), size, body]);
}

const SEQUENCE = 0x30;
const ECDSA_SHA256 = der(SEQUENCE, Buffer.from("06082a8648ce3d040302", "hex"));
// CN=lobby-direct
const NAME = der(
  SEQUENCE,
  der(
    0x31,
    der(SEQUENCE, Buffer.from("0603550403", "hex"), der(0x0c, Buffer.from("lobby-direct"))),
  ),
);
// DNS:lobby-direct, because TLS libraries ask for one.
const ALTERNATIVE = der(
  SEQUENCE,
  Buffer.from("0603551d11", "hex"),
  der(0x04, der(SEQUENCE, der(0x82, Buffer.from("lobby-direct")))),
);
const NEVER = "99991231235959Z";

export interface MadeCertificate {
  /** DER. */
  certificate: Buffer;
  /** PKCS #8, DER. */
  key: Buffer;
}

export function makeCertificate(now: number): MadeCertificate {
  const { publicKey, privateKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  const serial = randomBytes(16);
  // Positive, and without a leading zero.
  serial[0] = ((serial[0] ?? 0) & 0x7f) | 0x40;
  const from = new Date(now - 86_400_000).toISOString().replace(/[-:T]/g, "").slice(0, 14);
  const body = der(
    SEQUENCE,
    der(0xa0, der(0x02, Buffer.from([2]))),
    der(0x02, serial),
    ECDSA_SHA256,
    NAME,
    der(SEQUENCE, der(0x18, Buffer.from(`${from}Z`)), der(0x18, Buffer.from(NEVER))),
    NAME,
    publicKey.export({ format: "der", type: "spki" }),
    der(0xa3, der(SEQUENCE, ALTERNATIVE)),
  );
  const signature = sign("sha256", body, privateKey);
  return {
    certificate: der(
      SEQUENCE,
      body,
      ECDSA_SHA256,
      der(0x03, Buffer.concat([Buffer.alloc(1), signature])),
    ),
    key: privateKey.export({ format: "der", type: "pkcs8" }),
  };
}

/** What devices know a certificate by. */
export function fingerprint(certificate: Uint8Array): string {
  return createHash("sha256").update(certificate).digest("base64url");
}

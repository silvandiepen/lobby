// SPDX-License-Identifier: MPL-2.0
import { execFileSync } from "node:child_process";
import { chmodSync, writeFileSync } from "node:fs";
import { join } from "node:path";

/** A self-signed certificate and its key, made for this test and gone with its folder. */
export function makeCertificate(
  dir: string,
  name: string,
  base = "cert",
): { certFile: string; keyFile: string } {
  const certFile = join(dir, `${base}.pem`);
  const keyFile = join(dir, `${base}.key`);
  const config = join(dir, `${base}.cnf`);
  writeFileSync(
    config,
    `[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=ext\n[dn]\nCN=${name}\n[ext]\nsubjectAltName=DNS:${name}\nbasicConstraints=CA:TRUE\n`,
  );
  execFileSync(
    "openssl",
    [
      ..."req -x509 -newkey rsa:2048 -nodes -days 30 -sha256".split(" "),
      ...["-config", config, "-keyout", keyFile, "-out", certFile],
    ],
    { stdio: "ignore" },
  );
  chmodSync(keyFile, 0o600);
  return { certFile, keyFile };
}

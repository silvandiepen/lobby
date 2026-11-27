// SPDX-License-Identifier: MPL-2.0
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

/** Removed devices, kept beside the catalogue and the backups: a backup may be older than that. */
export const REVOKED_FILE = "revoked-devices.json";

/** Device ids and when each was removed. */
export type Revocations = Map<string, number>;

/** @throws Error when there is a list that cannot be read: it may hold a removed device */
export function readRevocations(dir: string): Revocations {
  const path = join(dir, REVOKED_FILE);
  if (!existsSync(path)) return new Map();
  const found: Revocations = new Map();
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8")) as unknown;
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
      throw new Error("not a list");
    }
    for (const [id, at] of Object.entries(parsed)) {
      if (typeof at !== "number") throw new Error("not a time");
      found.set(id, at);
    }
  } catch (error) {
    throw new Error(
      `${path} cannot be read, so removed devices could come back. Repair it, or move it away.`,
      { cause: error },
    );
  }
  return found;
}

export function writeRevocations(dir: string, revoked: Revocations): void {
  const path = join(dir, REVOKED_FILE);
  mkdirSync(dirname(path), { recursive: true });
  const part = `${path}.part`;
  writeFileSync(part, `${JSON.stringify(Object.fromEntries(revoked), null, 2)}\n`, { mode: 0o600 });
  renameSync(part, path);
}

// SPDX-License-Identifier: MPL-2.0
/**
 * What the demo scripts share: the films, the state folder, and calls to the demo's own Lobby
 * Server at home (127.0.0.1). Node 24, no dependencies: the server's own runtime runs these.
 */
import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

export interface Film {
  folder: string;
  title: string;
  year: number;
  genres: string[];
  overview: string;
  download: { url: string; zip: boolean };
  subtitles?: { url: string; file: string };
  poster: { url: string; source: string; cropToPortrait?: boolean };
  licence: string;
  licenceUrl: string;
  licenceSource: string;
  attribution: string;
}

export const FILMS: Film[] = (
  JSON.parse(readFileSync(join(import.meta.dirname, "films.json"), "utf8")) as { films: Film[] }
).films;

/** `--name value` from the command line, or the fallback. */
export function option(name: string, fallback: string): string {
  const at = process.argv.indexOf(`--${name}`);
  const value = at >= 0 ? process.argv[at + 1] : undefined;
  return value ?? fallback;
}

/** The folder with the doorman's credential and what the scripts remember. Mode 0700. */
export function stateDir(): string {
  const dir = option("state", join(process.env["HOME"] ?? ".", "lobby-demo", "state"));
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  chmodSync(dir, 0o700);
  return dir;
}

export function writeSecret(path: string, value: string): void {
  writeFileSync(path, `${value}\n`, { mode: 0o600 });
  chmodSync(path, 0o600);
}

export function readSecret(path: string): string | null {
  return existsSync(path) ? readFileSync(path, "utf8").trim() : null;
}

export class Api {
  readonly base: string;
  token: string | null;

  constructor(base: string, token: string | null) {
    this.base = base.replace(/\/$/, "");
    this.token = token;
  }

  async call<T>(method: string, path: string, body?: unknown, raw?: Uint8Array): Promise<T> {
    const headers: Record<string, string> = {};
    if (this.token) headers["Authorization"] = `Bearer ${this.token}`;
    let payload: NonNullable<RequestInit["body"]> | null = null;
    if (raw) {
      headers["Content-Type"] = "application/octet-stream";
      payload = raw;
    } else if (body !== undefined) {
      headers["Content-Type"] = "application/json";
      payload = JSON.stringify(body);
    }
    const response = await fetch(`${this.base}${path}`, { method, headers, body: payload });
    const text = await response.text();
    if (!response.ok) {
      throw new Error(`${method} ${path}: ${response.status} ${text.slice(0, 300)}`);
    }
    return (text ? JSON.parse(text) : null) as T;
  }
}

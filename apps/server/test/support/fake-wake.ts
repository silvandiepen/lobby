// SPDX-License-Identifier: MPL-2.0
// A stand-in for tools/wake.py in the tests: it speaks the same JSON lines, and keeps its Apple
// TVs in `<state>/tvs.json`. Every request it took goes to `<state>/log.jsonl`, so a test can see
// whether a TV was woken. It reaches no network.
//
//   node test/support/fake-wake.ts --state <dir>
import { appendFileSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { createInterface } from "node:readline";

interface Tv {
  id: string;
  name: string;
  model: string;
  paired: boolean;
}

interface State {
  televisions: Tv[];
  /** Waking says this code. */
  wakeFails?: string;
  /** Waking takes this long. */
  wakeMs?: number;
  /** What waking says of the app in front: pyatv over Companion alone cannot tell (null). */
  front?: boolean | null;
  /** Exits at once after starting, as a broken install would. */
  crash?: boolean;
}

const at = process.argv.indexOf("--state");
const dir = process.argv[at + 1] ?? ".";
const read = (): State => JSON.parse(readFileSync(join(dir, "tvs.json"), "utf8")) as State;
const write = (state: State): void => {
  writeFileSync(join(dir, "tvs.json"), JSON.stringify(state));
};

if (read().crash === true) {
  appendFileSync(join(dir, "starts"), "x");
  process.exit(4);
}
appendFileSync(join(dir, "starts"), "x");

const pairings = new Map<string, { device: string; pin: string | null }>();
let next = 0;

const say = (message: object): void => {
  process.stdout.write(`${JSON.stringify(message)}\n`);
};

type Request = Record<string, unknown>;
const no = (code: string, message: string): never => {
  throw Object.assign(new Error(message), { code });
};

const ops: Record<string, (request: Request) => Promise<object> | object> = {
  ping: () => ({ pyatv: "fake" }),
  scan: () => ({
    televisions: read().televisions.map((one) => ({ ...one, identifiers: [one.id] })),
  }),
  pair_begin: (request) => {
    const tv = read().televisions.find((one) => one.id === request["device"]);
    if (!tv) no("not_found", "That Apple TV was not found on the network.");
    next += 1;
    const token = `pairing-${String(next)}`;
    pairings.set(token, { device: String(request["device"]), pin: null });
    return { pairing: token, expiresInMs: 60_000 };
  },
  pair_pin: (request) => {
    const one = pairings.get(String(request["pairing"]));
    if (!one) no("timeout", "The code was not typed in time. Start again.");
    else one.pin = String(request["pin"]);
    return {};
  },
  pair_finish: (request) => {
    const token = String(request["pairing"]);
    const one = pairings.get(token);
    pairings.delete(token);
    if (!one) return no("timeout", "The code was not typed in time. Start again.");
    if (one.pin !== "1234") return no("pairing_failed", "The Apple TV did not take the code.");
    const state = read();
    const tv = state.televisions.find((t) => t.id === one.device);
    if (!tv) return no("not_found", "gone");
    tv.paired = true;
    write(state);
    return { television: { ...tv, identifiers: [tv.id] } };
  },
  pair_cancel: (request) => {
    pairings.delete(String(request["pairing"]));
    return {};
  },
  wake: async (request) => {
    const state = read();
    const tv = state.televisions.find((one) => one.id === request["device"]);
    if (!tv) return no("not_found", "That Apple TV was not found on the network.");
    if (!tv.paired) return no("not_paired", "Not paired.");
    if (state.wakeMs) await new Promise((done) => setTimeout(done, state.wakeMs));
    if (state.wakeFails) return no(state.wakeFails, "It did not work.");
    return { front: state.front ?? null, selected: false, reason: null };
  },
  // Select once on the TV and the app again. The test plays the TV: it opens Lobby when it sees
  // this in the log.
  pick: (request) => {
    const tv = read().televisions.find((one) => one.id === request["device"]);
    if (!tv) return no("not_found", "That Apple TV was not found on the network.");
    return { front: null, selected: true, reason: null };
  },
  unpair: (request) => {
    const state = read();
    const tv = state.televisions.find((one) => one.id === request["device"]);
    if (tv) tv.paired = false;
    write(state);
    return { removed: tv !== undefined };
  },
};

say({ event: "ready", pyatv: "fake" });
createInterface({ input: process.stdin }).on("line", (line) => {
  const request = JSON.parse(line) as Request;
  appendFileSync(join(dir, "log.jsonl"), `${line}\n`);
  const op = ops[String(request["op"])];
  void (async () => {
    try {
      if (!op) no("bad_request", "There is no such request.");
      else say({ id: request["id"], ok: true, ...(await op(request)) });
    } catch (error) {
      const code = (error as { code?: string }).code ?? "failed";
      say({ id: request["id"], ok: false, code, message: (error as Error).message });
    }
  })();
});

// SPDX-License-Identifier: MPL-2.0
// A stand-in for tools/wake.py in the tests: it speaks the same JSON lines, and keeps its Apple
// TVs and its speakers in `<state>/tvs.json`. Every request it took goes to `<state>/log.jsonl`,
// so a test can see whether a TV was woken. It reaches no network. A stream to a speaker runs the
// real ffmpeg on the real file, as the helper does, and logs how much FLAC came out.
//
//   node test/support/fake-wake.ts --state <dir>
import { spawn, type ChildProcess } from "node:child_process";
import { appendFileSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { createInterface } from "node:readline";

interface Tv {
  id: string;
  name: string;
  model: string;
  paired: boolean;
}

interface Speaker {
  id: string;
  name: string;
  model: string;
  kind: "homepod" | "speaker";
  access: "open" | "password" | "home_only";
  hasPassword?: boolean;
}

interface State {
  televisions: Tv[];
  speakers?: Speaker[];
  /** A stream to a speaker says this code, as a speaker that lets only its Home play says "refused". */
  streamFails?: string;
  /** A stream ends by itself after this long, as at the end of the track; otherwise when stopped. */
  streamMs?: number;
  /** A stream breaks after this long with this code. */
  streamBreaks?: { ms: number; code: string };
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
const streams = new Map<
  string,
  { decoder: ChildProcess; timer: NodeJS.Timeout | null; volume: number; stopped: boolean }
>();
const log = (entry: object): void => {
  appendFileSync(join(dir, "log.jsonl"), `${JSON.stringify(entry)}\n`);
};
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
  speakers: () => ({ speakers: read().speakers ?? [] }),
  stream: async (request) => {
    const state = read();
    const speaker = (state.speakers ?? []).find((one) => one.id === request["speaker"]);
    if (!speaker) return no("not_found", "That speaker was not found on the network.");
    if (state.streamFails)
      return no(state.streamFails, "The speaker did not let Lobby Server play.");
    const token = String(request["stream"]);
    const start = Number(request["startMs"] ?? 0) / 1000;
    // As tools/wake.py decodes it.
    const decoder = spawn(
      String(request["ffmpeg"]),
      [
        "-nostdin",
        "-hide_banner",
        "-loglevel",
        "error",
        "-ss",
        start.toFixed(3),
        "-i",
        String(request["file"]),
        "-map",
        "0:a:0",
        "-vn",
        "-ac",
        "2",
        "-ar",
        "44100",
        "-sample_fmt",
        "s16",
        "-f",
        "flac",
        "pipe:1",
      ],
      { stdio: ["ignore", "pipe", "ignore"] },
    );
    let bytes = 0;
    let head = Buffer.alloc(0);
    decoder.stdout.on("data", (chunk: Buffer) => {
      if (head.length < 4) head = Buffer.concat([head, chunk]).subarray(0, 4);
      bytes += chunk.length;
    });
    const volume = typeof request["volume"] === "number" ? request["volume"] : 0.4;
    const one = { decoder, timer: null as NodeJS.Timeout | null, volume, stopped: false };
    streams.set(token, one);
    decoder.on("close", () => {
      log({ op: "sent", stream: token, bytes, flac: head.toString("latin1") === "fLaC" });
    });
    const end = (reason: string, code: string | null): void => {
      if (streams.get(token) !== one) return;
      streams.delete(token);
      decoder.kill();
      say({ event: "stream_ended", stream: token, reason, code });
    };
    // As the helper, it answers once the speaker takes the sound: once the decoder gave some.
    await new Promise<void>((done) => {
      decoder.stdout.once("data", () => {
        done();
      });
      decoder.once("close", () => {
        done();
      });
    });
    if (state.streamBreaks) {
      const { ms, code } = state.streamBreaks;
      one.timer = setTimeout(() => {
        end("failed", code);
      }, ms);
    } else if (state.streamMs !== undefined) {
      one.timer = setTimeout(() => {
        end("ended", null);
      }, state.streamMs);
    }
    return { volume };
  },
  stream_stop: (request) => {
    const token = String(request["stream"]);
    const one = streams.get(token);
    if (!one) return { stopped: false };
    streams.delete(token);
    if (one.timer) clearTimeout(one.timer);
    one.decoder.kill();
    say({ event: "stream_ended", stream: token, reason: "stopped", code: null });
    return { stopped: true };
  },
  volume: (request) => {
    const one = streams.get(String(request["stream"]));
    if (!one) return no("not_streaming", "Nothing plays on that speaker now.");
    one.volume = Number(request["volume"]);
    return { volume: one.volume };
  },
  speaker_password: (request) => {
    const state = read();
    const speaker = (state.speakers ?? []).find((one) => one.id === request["speaker"]);
    if (!speaker) return no("not_found", "That speaker was not found on the network.");
    speaker.hasPassword = request["password"] !== null;
    if (speaker.access === "password" && speaker.hasPassword) speaker.access = "open";
    write(state);
    return {};
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

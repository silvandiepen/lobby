// SPDX-License-Identifier: MPL-2.0
import { spawn, type ChildProcessByStdio } from "node:child_process";
import { statSync } from "node:fs";
import { createInterface } from "node:readline";
import type { Readable, Writable } from "node:stream";
import { fileURLToPath } from "node:url";
import { log } from "../log.ts";

/** The helper that speaks to Apple TVs, shipped beside the server. */
export const WAKE_SCRIPT = fileURLToPath(new URL("../../tools/wake.py", import.meta.url));

const FIRST_WAIT_MS = 1_000;
const LAST_WAIT_MS = 60_000;
const SETTLED_MS = 60_000;
const READY_MS = 20_000;
const MAX_LINE = 256 * 1024;
const MAX_WAITING = 32;

type Child = ChildProcessByStdio<Writable, Readable, Readable>;

/** What the helper said no with, or that it could not be asked. */
export class WakeHelperError extends Error {
  /** The helper's codes, and "unavailable" when it is not running. */
  readonly code: string;

  constructor(code: string, message: string) {
    super(message);
    this.code = code;
  }
}

export interface WakeHelperOptions {
  /** The program that runs the script: a Python with pyatv. */
  python: string;
  script?: string;
  /**
   * Arguments before the script. Default `-I`: none of the environment's or the folder's Python
   * files are taken, only the venv's own.
   */
  flags?: string[];
  /** Arguments after the script. */
  args?: string[];
  /** Longest a request may take before it is given up. */
  timeoutMs?: number;
}

interface Waiting {
  resolve: (answer: Record<string, unknown>) => void;
  reject: (error: WakeHelperError) => void;
  timer: NodeJS.Timeout;
}

/**
 * The helper process (`tools/wake.py`), kept running: one JSON request per line on its stdin and
 * one answer per line on its stdout, matched by id. Started again with a growing wait when it
 * stops. It never gets an environment of its own beyond HOME and PATH, and nothing it says is
 * logged but its own problems, which carry no credential.
 */
export class WakeHelper {
  private readonly options: WakeHelperOptions;
  private child: Child | null = null;
  private readonly waiting = new Map<string, Waiting>();
  private timer: NodeJS.Timeout | null = null;
  private attempt = 0;
  private startedAt = 0;
  private next = 0;
  private ready = false;
  private stopped = true;
  /** In words, when it is not running. */
  problem: string | null = null;
  /** pyatv's version, as the helper said. */
  version: string | null = null;
  private readyWaiters: (() => void)[] = [];
  /** Told when it comes up or goes down. */
  onChange: (() => void) | null = null;

  constructor(options: WakeHelperOptions) {
    this.options = options;
  }

  get isUp(): boolean {
    return this.ready;
  }

  start(): void {
    if (!this.stopped) return;
    this.stopped = false;
    this.attempt = 0;
    this.run();
  }

  async stop(): Promise<void> {
    if (this.stopped) return;
    this.stopped = true;
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    const child = this.child;
    this.child = null;
    this.ready = false;
    this.failAll("unavailable", "Lobby Server is stopping.");
    this.wakeWaiters();
    if (child && child.exitCode === null && child.signalCode === null) {
      const exited = new Promise((done) => child.once("exit", done));
      child.stdin.end();
      const kill = setTimeout(() => child.kill("SIGKILL"), 3_000);
      await exited;
      clearTimeout(kill);
    }
  }

  /** Waits until it is running, at most `ms`. */
  async whenReady(ms: number): Promise<boolean> {
    if (this.ready) return true;
    if (this.stopped) return false;
    await new Promise<void>((done) => {
      const timer = setTimeout(done, ms);
      this.readyWaiters.push(() => {
        clearTimeout(timer);
        done();
      });
    });
    return this.ready;
  }

  /**
   * Asks the helper and waits for its answer.
   *
   * @throws WakeHelperError with the helper's code, or "unavailable" / "timeout"
   */
  async ask(
    op: string,
    fields: Record<string, unknown> = {},
    timeoutMs = this.options.timeoutMs ?? 45_000,
  ): Promise<Record<string, unknown>> {
    const child = this.child;
    if (!this.ready || !child) {
      throw new WakeHelperError(
        "unavailable",
        this.problem ?? "The helper for Apple TVs is starting. Try again in a moment.",
      );
    }
    if (this.waiting.size >= MAX_WAITING) {
      throw new WakeHelperError("busy", "The helper for Apple TVs is busy. Try again in a moment.");
    }
    this.next += 1;
    const id = String(this.next);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.waiting.delete(id);
        reject(new WakeHelperError("timeout", "The Apple TV did not answer in time."));
      }, timeoutMs);
      this.waiting.set(id, { resolve, reject, timer });
      child.stdin.write(`${JSON.stringify({ ...fields, id, op })}\n`);
    });
  }

  private run(): void {
    if (this.stopped) return;
    const { python, script = WAKE_SCRIPT, flags = ["-I"], args = [] } = this.options;
    try {
      if (!statSync(python).isFile()) throw new Error("not a file");
    } catch {
      this.fail(`there is no Python at ${python}; install pyatv there (docs/operations.md)`);
      return;
    }
    this.startedAt = Date.now();
    const child = spawn(python, [...flags, script, ...args], {
      stdio: ["pipe", "pipe", "pipe"],
      cwd: "/",
      env: {
        HOME: process.env["HOME"] ?? "/",
        PATH: process.env["PATH"] ?? "/usr/bin:/bin",
        PYTHONUNBUFFERED: "1",
      },
    });
    this.child = child;
    const late = setTimeout(() => child.kill("SIGKILL"), READY_MS);
    let ended = false;
    let said: string | null = null;
    const end = (problem: string): void => {
      if (ended) return;
      ended = true;
      clearTimeout(late);
      if (this.child !== child) return;
      this.child = null;
      const wasReady = this.ready;
      this.ready = false;
      this.failAll("unavailable", "The helper for Apple TVs stopped. Try again in a moment.");
      if (wasReady) this.onChange?.();
      this.fail(said ?? problem);
    };
    child.on("error", () => {
      end("the helper for Apple TVs cannot be started");
    });
    child.on("exit", (code) => {
      end(`the helper for Apple TVs stopped (${String(code ?? "killed")})`);
    });
    child.stdin.on("error", () => undefined);
    // pyatv's own warnings: their kind only, and only now and then, never the text, which could
    // carry an address or more.
    let warned = 0;
    createInterface({ input: child.stderr }).on("line", () => {
      if (Date.now() - warned < 60_000) return;
      warned = Date.now();
      log.warn("The helper for Apple TVs said something on stderr");
    });
    createInterface({ input: child.stdout }).on("line", (line) => {
      if (this.child !== child || line.length > MAX_LINE) return;
      let message: Record<string, unknown>;
      try {
        message = JSON.parse(line) as Record<string, unknown>;
      } catch {
        return;
      }
      if (message["event"] === "ready") {
        clearTimeout(late);
        this.ready = true;
        this.problem = null;
        this.version = typeof message["pyatv"] === "string" ? message["pyatv"] : null;
        log.info("The helper for Apple TVs is running", { pyatv: this.version ?? "unknown" });
        this.wakeWaiters();
        this.onChange?.();
        return;
      }
      if (message["event"] === "missing") {
        said = "pyatv is not installed for that Python (docs/operations.md)";
        return;
      }
      const id = typeof message["id"] === "string" ? message["id"] : null;
      const one = id === null ? undefined : this.waiting.get(id);
      if (!one || id === null) return;
      this.waiting.delete(id);
      clearTimeout(one.timer);
      if (message["ok"] === true) {
        const answer = { ...message };
        delete answer["id"];
        delete answer["ok"];
        one.resolve(answer);
      } else {
        one.reject(
          new WakeHelperError(
            typeof message["code"] === "string" ? message["code"] : "failed",
            typeof message["message"] === "string"
              ? message["message"].slice(0, 300)
              : "That did not work.",
          ),
        );
      }
    });
  }

  private failAll(code: string, message: string): void {
    for (const [id, one] of this.waiting) {
      clearTimeout(one.timer);
      one.reject(new WakeHelperError(code, message));
      this.waiting.delete(id);
    }
  }

  private wakeWaiters(): void {
    for (const one of this.readyWaiters.splice(0)) one();
  }

  private fail(problem: string): void {
    if (this.stopped) return;
    if (problem !== this.problem) log.error("Apple TVs cannot be woken", { problem });
    this.problem = problem;
    if (Date.now() - this.startedAt >= SETTLED_MS) this.attempt = 0;
    const wait = Math.min(LAST_WAIT_MS, FIRST_WAIT_MS * 2 ** Math.min(this.attempt, 10));
    this.attempt += 1;
    this.timer = setTimeout(
      () => {
        this.run();
      },
      wait * (0.75 + Math.random() / 2),
    );
  }
}

// SPDX-License-Identifier: MPL-2.0
import { Agent, request as httpRequest, type ClientRequest } from "node:http";
import { connect } from "node:net";
import type { Duplex } from "node:stream";
import { randomUUID } from "node:crypto";
import { ask, NAME, until, type OutsideReply } from "./outside.ts";

export interface LiveEvent {
  id: string | null;
  event: string;
  data: Record<string, unknown>;
  at: number;
}

export const CAPABILITIES = [
  "play",
  "pause",
  "resume",
  "seek",
  "skip",
  "next",
  "stop",
  "setAudio",
  "setSubtitle",
  "setVolume",
  "upNext",
];

/** A player's state as an app sends it. */
export function playing(itemId: string, more: Record<string, unknown> = {}): unknown {
  return {
    itemId,
    assetId: null,
    profileId: null,
    status: "playing",
    positionMs: 60_000,
    ageMs: 0,
    durationMs: 5_400_000,
    rate: 1,
    audioTracks: [{ id: "0", label: "English", language: "eng" }],
    audioTrackId: "0",
    subtitleTracks: [],
    subtitleTrackId: null,
    volume: 0.5,
    nextItemId: null,
    queue: [],
    ...more,
  };
}

/** A device with the live channel open, over a real socket. */
export class LiveClient {
  readonly id: string;
  readonly token: string;
  readonly session: string;
  readonly events: LiveEvent[] = [];
  closed = false;
  status = 0;
  private readonly dial: () => Duplex;
  private readonly host: string;
  private request: ClientRequest | null = null;
  private order = 0;
  private said: Record<string, unknown> = {};

  constructor(device: { id: string; token: string }, dial: number | (() => Duplex)) {
    this.id = device.id;
    this.token = device.token;
    this.session = randomUUID();
    this.host = typeof dial === "number" ? "localhost" : NAME;
    this.dial = typeof dial === "number" ? () => connect(dial, "127.0.0.1") : dial;
  }

  get last(): string | null {
    return this.events.findLast((one) => one.id !== null)?.id ?? null;
  }

  async open(last: string | null = null): Promise<void> {
    this.closed = false;
    this.status = 0;
    const agent = new Agent({ keepAlive: false });
    agent.createConnection = () => this.dial();
    const query = last === null ? "" : `&last=${last}`;
    const request = httpRequest({
      path: `/v1/live?session=${this.session}${query}`,
      agent,
      setHost: false,
      headers: { Host: this.host, Authorization: `Bearer ${this.token}` },
    });
    this.request = request;
    request.on("error", () => {
      this.closed = true;
    });
    request.on("response", (response) => {
      this.status = response.statusCode ?? 0;
      let text = "";
      response.setEncoding("utf8");
      response.on("data", (part: string) => {
        text += part;
        const blocks = text.split("\n\n");
        text = blocks.pop() ?? "";
        for (const block of blocks) this.take(block);
      });
      response.on("error", () => undefined);
      response.on("close", () => {
        if (this.request === request) this.closed = true;
      });
    });
    request.end();
    const before = this.events.length;
    await until(
      () =>
        this.closed ||
        (this.status !== 0 && this.status !== 200) ||
        this.events.slice(before).some((one) => one.event === "hello"),
    );
  }

  private take(block: string): void {
    const fields = new Map(
      block.split("\n").map((line): [string, string] => {
        const at = line.indexOf(": ");
        return [line.slice(0, at), line.slice(at + 2)];
      }),
    );
    this.events.push({
      id: fields.get("id") ?? null,
      event: fields.get("event") ?? "",
      data: JSON.parse(fields.get("data") ?? "null") as Record<string, unknown>,
      at: performance.now(),
    });
  }

  /** Breaks the connection, without a goodbye. */
  cut(): void {
    this.request?.destroy();
    this.request = null;
    this.closed = true;
  }

  post(path: string, body: unknown, method = "POST"): Promise<OutsideReply> {
    return ask(this.dial, method, path, { token: this.token, body, host: this.host });
  }

  announce(more: Record<string, unknown> = {}): Promise<OutsideReply> {
    this.order += 1;
    const { player, ...lasting } = more;
    this.said = { ...this.said, ...lasting };
    return this.post(`/v1/live/${this.session}`, {
      order: this.order,
      foreground: true,
      canPlay: true,
      profileId: null,
      capabilities: CAPABILITIES,
      ...this.said,
      ...(player === undefined ? {} : { player }),
    });
  }

  command(
    deviceId: string,
    command: Record<string, unknown>,
    id: string = randomUUID(),
  ): Promise<OutsideReply> {
    return this.post("/v1/remote/commands", { id, session: this.session, deviceId, command });
  }

  result(commandId: string, more: Record<string, unknown> = {}): Promise<OutsideReply> {
    return this.post(`/v1/live/${this.session}/results`, { commandId, status: "done", ...more });
  }

  of(event: string): LiveEvent[] {
    return this.events.filter((one) => one.event === event);
  }

  commands(): { commandId: string; requestId: string; command: Record<string, unknown> }[] {
    return this.of("command").map(
      (one) =>
        one.data as {
          commandId: string;
          requestId: string;
          command: Record<string, unknown>;
        },
    );
  }

  /** Waits for a command of this kind and gives its id. */
  async asked(type: string): Promise<string> {
    await until(() => this.commands().some((one) => one.command["type"] === type));
    return this.commands().findLast((one) => one.command["type"] === type)?.commandId ?? "";
  }

  outcome(requestId: string): Record<string, unknown> | undefined {
    return this.of("result").find((one) => one.data["commandId"] === requestId)?.data;
  }

  /** What this device knows now of another, after everything it was told. */
  sees(deviceId: string): Record<string, unknown> | null {
    let known: Record<string, unknown> | null = null;
    for (const { event, data } of this.events) {
      if (event === "snapshot") {
        const all = data["devices"] as Record<string, unknown>[];
        known = all.find((one) => one["id"] === deviceId) ?? null;
      }
      const device = data["device"] as Record<string, unknown> | undefined;
      if (event === "device" && device?.["id"] === deviceId) known = device;
      if (event === "gone" && data["deviceId"] === deviceId) known = null;
    }
    return known;
  }
}

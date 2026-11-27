// SPDX-License-Identifier: MPL-2.0
import { constants, createHash, createPrivateKey, X509Certificate } from "node:crypto";
import { readFile, stat } from "node:fs/promises";
import { createServer as createTcpServer, type Server, type Socket } from "node:net";
import { createSecureContext, createServer as createTlsServer, type SecureContext } from "node:tls";
import type { TLSSocket, Server as TlsServer } from "node:tls";
import { errorMessage, log } from "../log.ts";
import type { OutsideTlsConfig } from "./config.ts";
import type { OutsideConnection, OutsideTransport } from "./entrance.ts";
import { plainAddress } from "./limits.ts";
import { readProxyHeader } from "./proxy.ts";

const CHECK_MS = 30_000;
/** For the relay's header and the whole TLS handshake. */
const HANDSHAKE_MS = 10_000;
const MAX_HANDSHAKES = 64;
const MAX_SOCKETS = 192;
const CIPHERS = [
  "TLS_AES_128_GCM_SHA256",
  "TLS_AES_256_GCM_SHA384",
  "TLS_CHACHA20_POLY1305_SHA256",
  "ECDHE-ECDSA-AES128-GCM-SHA256",
  "ECDHE-RSA-AES128-GCM-SHA256",
  "ECDHE-ECDSA-AES256-GCM-SHA384",
  "ECDHE-RSA-AES256-GCM-SHA384",
  "ECDHE-ECDSA-CHACHA20-POLY1305",
  "ECDHE-RSA-CHACHA20-POLY1305",
].join(":");

const PROTOCOL = {
  minVersion: "TLSv1.2",
  ciphers: CIPHERS,
  honorCipherOrder: true,
  secureOptions: constants.SSL_OP_NO_RENEGOTIATION,
} as const;

interface Certificate {
  context: SecureContext;
  from: number;
  to: number;
}

/**
 * The road over the owner's own relay: it passes the encrypted bytes on as they are, through a
 * tunnel this machine opened, and tells the visitor's address in front of them (PROXY protocol
 * v2). TLS ends here, so the relay cannot read along.
 */
export class RelayTransport implements OutsideTransport {
  readonly name = "relay";
  private readonly config: OutsideTlsConfig;
  private readonly publicName: string;
  private readonly now: () => number;
  private accept: ((connection: OutsideConnection) => void) | null = null;
  private tcp: Server | null = null;
  private readonly tls: TlsServer;
  private readonly sockets = new Set<Socket>();
  /** By the relay's address and port, which no two connections share. */
  private readonly handshakes = new Map<string, { socket: Socket; address: string }>();
  /** Called when a connection is through its handshake, or gone. */
  private readonly settle = new Map<string, () => void>();
  private pending = 0;
  private certificate: Certificate | null = null;
  private readDigest = "";
  private problem: string | null = null;
  private timer: NodeJS.Timeout | null = null;
  private checking: Promise<void> = Promise.resolve();

  constructor(config: OutsideTlsConfig, publicName: string, now: () => number = Date.now) {
    this.config = config;
    this.publicName = publicName;
    this.now = now;
    this.tls = createTlsServer({
      // Here too: a context that comes with the name brings its certificate, not its ciphers.
      ...PROTOCOL,
      ALPNProtocols: ["http/1.1"],
      handshakeTimeout: HANDSHAKE_MS,
      // There is no certificate but this one's: who does not know the name is not shown it.
      SNICallback: (name, done) => {
        const certificate = this.certificate;
        if (name.toLowerCase() !== this.publicName || !certificate || !this.isCurrent()) {
          done(new Error("unknown name"));
          return;
        }
        done(null, certificate.context);
      },
    });
    this.tls.on("secureConnection", (socket) => {
      this.secured(socket);
    });
    this.tls.on("tlsClientError", (_error, socket) => {
      socket.destroy();
    });
  }

  status(): { open: boolean; problem: string | null } {
    return { open: this.tcp?.listening ?? false, problem: this.problem };
  }

  async open(accept: (connection: OutsideConnection) => void): Promise<void> {
    this.accept = accept;
    this.timer ??= setInterval(() => void this.check(), CHECK_MS).unref();
    await this.check();
  }

  async close(): Promise<void> {
    this.accept = null;
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
    await this.check();
  }

  /** Reads the certificate again when its files changed, and opens or closes the listener. */
  check(): Promise<void> {
    this.checking = this.checking.then(async () => {
      try {
        if (!this.accept) {
          await this.unlisten();
          return;
        }
        await this.reload();
        if (this.isCurrent()) {
          await this.listen();
          this.say(null);
        } else {
          await this.unlisten();
        }
      } catch (error) {
        await this.unlisten();
        this.say(errorMessage(error));
      }
    });
    return this.checking;
  }

  private say(problem: string | null): void {
    if (problem !== null && problem !== this.problem) {
      log.error("The outside entrance cannot be reached through the relay", { problem });
    }
    this.problem = problem;
  }

  private isCurrent(): boolean {
    const now = this.now();
    return this.certificate !== null && now >= this.certificate.from && now < this.certificate.to;
  }

  private async reload(): Promise<void> {
    try {
      const [cert, key, info] = await Promise.all([
        readFile(this.config.certFile),
        readFile(this.config.keyFile),
        stat(this.config.keyFile),
      ]);
      const digest = createHash("sha256").update(cert).update(key).digest("hex");
      if (digest !== this.readDigest || (info.mode & 0o007) !== 0) {
        this.certificate = this.parse(cert, key, info.mode);
        this.readDigest = digest;
        log.info("Read the certificate for outside", {
          until: new Date(this.certificate.to).toISOString(),
        });
      }
      if (!this.isCurrent()) throw new Error("the certificate is not valid at this time");
    } catch (error) {
      // One that still holds goes on: a renewal may be half written.
      const code = (error as NodeJS.ErrnoException).code;
      const problem =
        code === "ENOENT"
          ? "the certificate or its key is not there"
          : code === "EACCES"
            ? "the certificate or its key may not be read"
            : errorMessage(error);
      if (!this.isCurrent()) throw new Error(problem, { cause: error });
      log.warn("The new certificate for outside cannot be used; keeping the old one", { problem });
    }
  }

  private parse(cert: Buffer, key: Buffer, mode: number): Certificate {
    if ((mode & 0o007) !== 0) throw new Error("the key can be read by everybody on this machine");
    const leaf = new X509Certificate(cert);
    if (leaf.checkHost(this.publicName) === undefined) {
      throw new Error("the certificate is for another name");
    }
    if (!leaf.checkPrivateKey(createPrivateKey(key))) {
      throw new Error("the key does not belong to the certificate");
    }
    return {
      from: leaf.validFromDate.getTime(),
      to: leaf.validToDate.getTime(),
      context: createSecureContext({
        cert,
        key,
        ...PROTOCOL,
      }),
    };
  }

  private async listen(): Promise<void> {
    if (this.tcp) return;
    const server = createTcpServer((socket) => {
      this.receive(socket);
    });
    server.maxConnections = MAX_SOCKETS;
    this.tcp = server;
    try {
      await new Promise<void>((resolve, reject) => {
        server.once("error", reject);
        server.listen({ host: this.config.host, port: this.config.port, exclusive: true }, resolve);
      });
    } catch (error) {
      this.tcp = null;
      throw error;
    }
    const bound = server.address();
    if (
      bound === null ||
      typeof bound === "string" ||
      plainAddress(bound.address) !== plainAddress(this.config.host)
    ) {
      throw new Error("the listener is not at the address it was given");
    }
    server.on("error", (error) => {
      this.say(errorMessage(error));
    });
  }

  private async unlisten(): Promise<void> {
    const server = this.tcp;
    this.tcp = null;
    for (const socket of this.sockets) socket.destroy();
    if (server?.listening) {
      await new Promise<void>((resolve) => {
        server.close(() => {
          resolve();
        });
      });
    }
  }

  // ---- Connections ----

  private receive(socket: Socket): void {
    socket.on("error", () => undefined);
    const relay = plainAddress(socket.remoteAddress);
    const key = `${socket.remoteAddress ?? ""} ${String(socket.remotePort)}`;
    if (relay === null || !this.config.relays.includes(relay) || this.pending >= MAX_HANDSHAKES) {
      socket.destroy();
      return;
    }
    this.sockets.add(socket);
    this.pending += 1;
    const timer = setTimeout(() => socket.destroy(), HANDSHAKE_MS);
    const settled = (): void => {
      if (!this.settle.delete(key)) return;
      clearTimeout(timer);
      this.pending -= 1;
    };
    this.settle.set(key, settled);
    socket.once("close", () => {
      settled();
      this.sockets.delete(socket);
      if (this.handshakes.get(key)?.socket === socket) this.handshakes.delete(key);
    });

    let held: Buffer = Buffer.alloc(0);
    const read = (): void => {
      const data = socket.read() as Buffer | null;
      if (!data) return;
      held = Buffer.concat([held, data]);
      const header = readProxyHeader(held);
      // Never more than a header's worth is held.
      if (header.state === "more") return;
      if (header.state === "wrong") {
        socket.destroy();
        return;
      }
      socket.off("readable", read);
      const rest = held.subarray(header.length);
      if (rest.length > 0) socket.unshift(rest);
      this.handshakes.set(key, { socket, address: header.address });
      this.tls.emit("connection", socket);
    };
    socket.on("readable", read);
  }

  private secured(socket: TLSSocket): void {
    const key = `${socket.remoteAddress ?? ""} ${String(socket.remotePort)}`;
    const known = this.handshakes.get(key);
    this.settle.get(key)?.();
    socket.on("error", () => undefined);
    const accept = this.accept;
    if (!known || !accept || socket.servername !== this.publicName) {
      socket.destroy();
      return;
    }
    accept({ stream: socket, address: known.address, addressIsReliable: true });
  }
}

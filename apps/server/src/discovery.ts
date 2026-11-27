// SPDX-License-Identifier: MPL-2.0
import { networkInterfaces, type NetworkInterfaceInfo } from "node:os";
import { Bonjour } from "bonjour-service";
import multicastDns from "multicast-dns";
import { errorMessage, log } from "./log.ts";

/** The Bonjour service type the apps look for: `_lobby._tcp`. */
export const SERVICE_TYPE = "lobby";

export interface Announcement {
  serverName: string;
  serverId: string;
  port: number;
  apiVersion: number;
}

/**
 * The addresses a device at home can reach: IPv4 on real interfaces. Docker's bridges
 * and the tailnet are left out, because a device that is handed one of those tries it
 * first and waits for nothing.
 */
export function homeAddresses(
  interfaces: NodeJS.Dict<NetworkInterfaceInfo[]> = networkInterfaces(),
): string[] {
  return Object.entries(interfaces)
    .filter(([name]) => !/^(?:docker|br-|veth|virbr|tailscale|utun|tun|wg|zt)/.test(name))
    .flatMap(([, addresses]) => addresses ?? [])
    .filter((address) => address.family === "IPv4" && !address.internal)
    .map((address) => address.address);
}

/**
 * The server's own name on the home network. Not the machine's: the machine's name is
 * already answered for by its own responder (avahi), and two answers would conflict.
 */
export function localHost(serverId: string): string {
  return `lobby-${serverId.replaceAll("-", "").slice(0, 8)}.local`;
}

/** Says that `host` has an IPv4 address and nothing else (RFC 6762, section 6.1). */
export function ipv4Only(host: string): {
  name: string;
  type: "NSEC";
  ttl: number;
  flush: boolean;
  data: { nextDomain: string; rrtypes: string[] };
} {
  return {
    name: host,
    type: "NSEC",
    ttl: 120,
    flush: true,
    data: { nextDomain: host, rrtypes: ["A"] },
  };
}

/**
 * Answers IPv6 lookups of `host` with "there is none". The server listens on IPv4; without
 * this answer Apple devices wait five seconds for one on every lookup.
 */
function answerIPv6Lookups(host: string): () => void {
  const mdns = multicastDns();
  mdns.on("error", (error: Error) => {
    log.warn("Cannot answer IPv6 lookups of the server's name", { error: errorMessage(error) });
  });
  mdns.on("query", (query) => {
    const asked = (query.questions ?? []).some(
      (question) => question.type === "AAAA" && question.name.toLowerCase() === host.toLowerCase(),
    );
    if (asked) mdns.respond({ answers: [ipv4Only(host)] });
  });
  return () => {
    mdns.destroy();
  };
}

/**
 * Announces the server on the home network, so the apps can list it instead of
 * asking for an address. It carries nothing secret: the name, the port and the
 * server's id, all of which `/v1/server` gives to anyone who can reach it.
 * Returns a function that withdraws the announcement.
 */
export function announce(announcement: Announcement): () => Promise<void> {
  const bonjour = new Bonjour(undefined, (error: unknown) => {
    log.warn("Could not announce the server on the network; devices can still type its address", {
      error: errorMessage(error),
    });
  });
  const service = bonjour.publish({
    name: announcement.serverName,
    type: SERVICE_TYPE,
    port: announcement.port,
    host: localHost(announcement.serverId),
    disableIPv6: true,
    txt: { id: announcement.serverId, v: String(announcement.apiVersion) },
  });
  const allRecords = service.records.bind(service);
  service.records = () => {
    const reachable = homeAddresses();
    return allRecords().filter(
      (record) => record.type !== "A" || reachable.includes(String(record.data)),
    );
  };
  service.on("error", (error: unknown) => {
    log.warn("Could not announce the server on the network; devices can still type its address", {
      error: errorMessage(error),
    });
  });
  const stopAnswering = answerIPv6Lookups(localHost(announcement.serverId));
  return () =>
    new Promise((resolve) => {
      stopAnswering();
      bonjour.unpublishAll(() => {
        bonjour.destroy();
        resolve();
      });
    });
}

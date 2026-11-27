// SPDX-License-Identifier: MPL-2.0
import type { NetworkInterfaceInfo } from "node:os";
import { describe, expect, it } from "vitest";
import { homeAddresses, ipv4Only, localHost } from "../src/discovery.ts";

function ipv4(address: string, internal = false): NetworkInterfaceInfo {
  return {
    address,
    internal,
    family: "IPv4",
    mac: "02:00:00:00:00:01",
    netmask: "255.255.255.0",
    cidr: `${address}/24`,
  };
}

describe("announcing on the home network", () => {
  it("offers only addresses a device at home can reach", () => {
    expect(
      homeAddresses({
        lo: [ipv4("127.0.0.1", true)],
        eth0: [ipv4("192.168.1.10")],
        wlan0: [ipv4("192.168.1.11")],
        tailscale0: [ipv4("100.64.0.5")],
        docker0: [ipv4("172.17.0.1")],
      }),
    ).toEqual(["192.168.1.10", "192.168.1.11"]);
  });

  it("uses a .local name of its own", () => {
    expect(localHost("7c3f9a12-5b8e-4d21-9f6a-2e4b8c1d0a57")).toBe("lobby-7c3f9a12.local");
  });
});

it("says the server's name has an IPv4 address only", () => {
  expect(ipv4Only("lobby-1.local")).toMatchObject({
    name: "lobby-1.local",
    type: "NSEC",
    data: { nextDomain: "lobby-1.local", rrtypes: ["A"] },
  });
});

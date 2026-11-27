// SPDX-License-Identifier: MPL-2.0
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

const CLI = join(import.meta.dirname, "../src/cli.ts");

function lobby(args: string[], cwd: string) {
  const result = spawnSync(process.execPath, [CLI, ...args], {
    cwd,
    encoding: "utf8",
    env: { ...process.env, LOBBY_CONFIG: join(cwd, "lobby.config.json") },
  });
  return { status: result.status, out: `${result.stdout}${result.stderr}` };
}

describe("the lobby command", () => {
  it("names the commands an installed copy adds", () => {
    const dir = mkdtempSync(join(tmpdir(), "lobby-cli-"));
    const help = lobby(["help"], dir);
    expect(help.status).toBe(0);
    expect(help.out).toContain("update [--version <v>]");
    expect(help.out).toContain("uninstall [--delete-data]");
    rmSync(dir, { recursive: true });
  });

  it("sends update and uninstall to the installed command, before reading any config", () => {
    const dir = mkdtempSync(join(tmpdir(), "lobby-cli-"));
    for (const command of ["update", "uninstall"]) {
      const result = lobby([command], dir);
      expect(result.status).toBe(1);
      expect(result.out).toContain("bin/lobby");
      expect(result.out).not.toContain("no config file");
    }
    expect(existsSync(join(dir, "data"))).toBe(false);
    rmSync(dir, { recursive: true });
  });
});

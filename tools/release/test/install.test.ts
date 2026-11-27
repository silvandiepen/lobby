// SPDX-License-Identifier: MPL-2.0
/**
 * The installer, for real: archives built by build.ts, installed into a folder of the test's own,
 * the server started from it, updated and removed. Services are not touched: `launchctl`,
 * `systemctl`, `loginctl` and `sudo` are stand-ins on PATH (test/bin) that note how they were
 * called and start or stop the installed server the way the service manager would.
 */
import { execFileSync, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join, relative, resolve } from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";

const HERE = import.meta.dirname;
const RELEASE = resolve(HERE, "..");
const INSTALLER = join(RELEASE, "install.sh");
const SHELLS = ["sh", ...(existsSync("/bin/dash") ? ["/bin/dash"] : [])];

const hostPlatform = (() => {
  const os = { linux: "linux", darwin: "macos" }[process.platform as string];
  const arch = { arm64: "arm64", x64: "x64" }[process.arch as string];
  return os && arch ? `${os}-${arch}` : null;
})();

function run(
  command: string,
  args: string[],
  env: NodeJS.ProcessEnv = {},
  input?: string,
): { status: number; out: string } {
  const result = spawnSync(command, args, {
    encoding: "utf8",
    env: { ...process.env, ...env },
    input: input ?? "",
  });
  return { status: result.status ?? -1, out: `${result.stdout}${result.stderr}` };
}

/** Calls a function of install.sh in the given shell. */
function piece(shell: string, script: string): { status: number; out: string } {
  return run(shell, ["-c", `. "${INSTALLER}"; ${script}`], { LOBBY_INSTALL_LIB: "1" });
}

describe.each(SHELLS)("install.sh's pieces in %s", (shell) => {
  it("names the platform of a computer, or none", () => {
    const cases: [string, string, string | null][] = [
      ["Linux", "aarch64", "linux-arm64"],
      ["Linux", "x86_64", "linux-x64"],
      ["Linux", "amd64", "linux-x64"],
      ["Darwin", "arm64", "macos-arm64"],
      ["Darwin", "x86_64", "macos-x64"],
      ["Linux", "armv7l", null],
      ["FreeBSD", "amd64", null],
    ];
    for (const [os, machine, expected] of cases) {
      const result = piece(shell, `platform_of ${os} ${machine}`);
      if (expected === null) expect(result.status, `${os} ${machine}`).not.toBe(0);
      else expect(result.out.trim(), `${os} ${machine}`).toBe(expected);
    }
  });

  it("finds the archive for its platform in SHA256SUMS", () => {
    const dir = mkdtempSync(join(tmpdir(), "lobby-sums-"));
    const sums = join(dir, "SHA256SUMS");
    const a = "a".repeat(64);
    const b = "b".repeat(64);
    writeFileSync(
      sums,
      `${"c".repeat(64)}  install.sh\n${a}  lobby-server-1.2.3-linux-arm64.tar.xz\n${b}  lobby-server-1.2.3-linux-x64.tar.xz\n`,
    );
    expect(piece(shell, `sums_entry "${sums}" linux-x64`).out.trim()).toBe(
      `${b} lobby-server-1.2.3-linux-x64.tar.xz`,
    );
    expect(piece(shell, `sums_entry "${sums}" macos-arm64`).out.trim()).toBe("");
    rmSync(dir, { recursive: true });
  });

  it("compares versions by their numbers", () => {
    const older = (a: string, b: string): boolean =>
      piece(shell, `older_than ${a} ${b}`).status === 0;
    expect(older("0.1.0", "0.2.0")).toBe(true);
    expect(older("0.9.0", "0.10.0")).toBe(true);
    expect(older("1.0.0", "0.10.0")).toBe(false);
    expect(older("0.2.0", "0.2.0")).toBe(false);
    expect(older("0.2.1", "0.2.0")).toBe(false);
  });

  it("writes services that run bin/lobby and restart it after exit 75", () => {
    const user = piece(shell, `systemd_unit "/home/someone/lobby" user "/usr/bin:/bin"`).out;
    expect(user).toContain(`ExecStart="/home/someone/lobby/bin/lobby" serve`);
    expect(user).toContain("RestartForceExitStatus=75");
    expect(user).toContain("WantedBy=default.target");
    expect(user).not.toContain("User=");
    const system = piece(shell, `systemd_unit "/home/someone/lobby" system "/usr/bin:/bin"`).out;
    expect(system).toMatch(/^User=\S+$/m);
    expect(system).toContain("WantedBy=multi-user.target");
    const plist = piece(shell, `launchd_plist "/Users/someone/lobby" user "/usr/bin:/bin"`).out;
    expect(plist).toContain("<string>/Users/someone/lobby/bin/lobby</string>");
    expect(plist).toContain("<key>LOBBY_SUPERVISED</key>");
    if (process.platform === "darwin") {
      const dir = mkdtempSync(join(tmpdir(), "lobby-plist-"));
      writeFileSync(join(dir, "a.plist"), plist);
      expect(run("plutil", ["-lint", join(dir, "a.plist")]).status).toBe(0);
      rmSync(dir, { recursive: true });
    }
  });

  it("says how to get ffmpeg", () => {
    expect(piece(shell, "ffmpeg_hint").out.trim()).not.toBe("");
  });
});

/** Every file below a folder with its SHA-256. */
function fingerprint(dir: string): Map<string, string> {
  const found = new Map<string, string>();
  const walk = (at: string): void => {
    for (const entry of readdirSync(at, { withFileTypes: true })) {
      const path = join(at, entry.name);
      if (entry.isDirectory()) walk(path);
      else
        found.set(
          relative(dir, path),
          createHash("sha256").update(readFileSync(path)).digest("hex"),
        );
    }
  };
  walk(dir);
  return found;
}

async function freePort(): Promise<number> {
  return new Promise((done, fail) => {
    const server = createServer();
    server.once("error", fail);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      server.close(() => {
        done(typeof address === "object" && address ? address.port : 0);
      });
    });
  });
}

async function answers(port: number, seconds = 60): Promise<boolean> {
  for (let left = seconds * 4; left > 0; left -= 1) {
    try {
      const response = await fetch(`http://127.0.0.1:${String(port)}/v1/server`);
      if (response.ok) return true;
    } catch {
      // Not yet.
    }
    await new Promise((done) => setTimeout(done, 250));
  }
  return false;
}

/** launchctl, systemctl, loginctl and sudo that start and stop the installed server. */
function standIns(dir: string): void {
  mkdirSync(dir, { recursive: true });
  const manager = `#!/bin/sh
echo "$(basename "$0") $*" >> "$LOBBY_TEST_CALLS"
stop() {
  if [ -f "$LOBBY_TEST_PID" ]; then
    pid="$(cat "$LOBBY_TEST_PID")"
    kill "$pid" 2>/dev/null || true
    i=0; while kill -0 "$pid" 2>/dev/null && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
    rm -f "$LOBBY_TEST_PID"
  fi
}
begin() {
  stop
  nohup "$LOBBY_TEST_PREFIX/bin/lobby" serve >> "$LOBBY_TEST_PREFIX/server.log" 2>&1 < /dev/null &
  echo $! > "$LOBBY_TEST_PID"
}
case "$(basename "$0") $*" in
  "launchctl bootout"*|"systemctl --user stop"*) stop ;;
  "launchctl bootstrap"*|"systemctl --user restart"*) begin ;;
esac
exit 0
`;
  for (const name of ["launchctl", "systemctl"]) {
    writeFileSync(join(dir, name), manager);
    chmodSync(join(dir, name), 0o755);
  }
  writeFileSync(
    join(dir, "loginctl"),
    '#!/bin/sh\necho "loginctl $*" >> "$LOBBY_TEST_CALLS"\necho no\n',
  );
  writeFileSync(join(dir, "sudo"), '#!/bin/sh\necho "sudo $*" >> "$LOBBY_TEST_CALLS"\nexit 1\n');
  for (const name of ["loginctl", "sudo"]) chmodSync(join(dir, name), 0o755);
}

describe.skipIf(hostPlatform === null)("installing, updating and removing Lobby Server", () => {
  const root = mkdtempSync(join(tmpdir(), "lobby-install-"));
  const home = join(root, "home");
  const prefix = join(home, "lobby");
  const calls = join(root, "calls.log");
  const pidFile = join(root, "server.pid");
  const name = (version: string): string => `lobby-server-${version}-${hostPlatform ?? ""}.tar.xz`;
  const archiveA = join(root, "a", name("0.0.1"));
  const archiveB = join(root, "b", name("0.0.2"));
  let port = 0;
  const env = (): NodeJS.ProcessEnv => ({
    HOME: home,
    PATH: `${join(root, "bin")}:${process.env["PATH"] ?? ""}`,
    XDG_CONFIG_HOME: join(home, ".config"),
    LOBBY_HOME: "",
    LOBBY_CONFIG: "",
    LOBBY_TEST_CALLS: calls,
    LOBBY_TEST_PID: pidFile,
    LOBBY_TEST_PREFIX: prefix,
  });
  const lobby = (...args: string[]) => run(join(prefix, "bin/lobby"), args, env());
  const serviceFile =
    process.platform === "darwin"
      ? join(home, "Library/LaunchAgents/lobby.server.plist")
      : join(home, ".config/systemd/user/lobby.service");

  beforeAll(async () => {
    mkdirSync(home, { recursive: true });
    standIns(join(root, "bin"));
    port = await freePort();
    const build = (version: string, out: string): void => {
      execFileSync(
        process.execPath,
        [join(RELEASE, "build.ts"), "--version", version, "--out", out, hostPlatform ?? ""],
        { stdio: ["ignore", "ignore", "inherit"] },
      );
    };
    build("0.0.1", join(root, "a"));
    build("0.0.2", join(root, "b"));
    build("0.0.1", join(root, "a-again"));
  });

  afterAll(() => {
    if (existsSync(pidFile)) {
      try {
        process.kill(Number(readFileSync(pidFile, "utf8")));
      } catch {
        // Gone already.
      }
    }
    rmSync(root, { recursive: true, force: true });
  });

  it("builds the same archive from the same commit", () => {
    const sums = (dir: string): string => readFileSync(join(root, dir, "SHA256SUMS"), "utf8");
    expect(sums("a-again")).toBe(sums("a"));
  });

  it("refuses an archive whose checksum does not match", () => {
    const result = run(
      "sh",
      [INSTALLER, "--archive", archiveA, "--sha256", "0".repeat(64), "--no-start"],
      env(),
    );
    expect(result.status).not.toBe(0);
    expect(result.out).toContain("not installed");
    expect(existsSync(join(prefix, "app"))).toBe(false);
  });

  it("installs into its folder, with a config, a data folder and a service", () => {
    const result = run("sh", [INSTALLER, "--archive", archiveA, "--no-start"], env());
    expect(result.status, result.out).toBe(0);
    for (const part of [
      "app/src/cli.ts",
      "runtime/bin/node",
      "bin/lobby",
      "installer/install.sh",
    ]) {
      expect(existsSync(join(prefix, part)), part).toBe(true);
    }
    expect(readFileSync(join(prefix, "VERSION"), "utf8").trim()).toBe("0.0.1");
    const config = JSON.parse(readFileSync(join(prefix, "lobby.config.json"), "utf8")) as Record<
      string,
      unknown
    >;
    // No folders and no claim setting: the app's first setup, open only from nearby.
    expect(config).toEqual({ serverName: "Lobby", dataDir: "data", host: "0.0.0.0", port: 8674 });
    expect(statSync(join(prefix, "data")).mode & 0o777).toBe(0o700);
    expect(readFileSync(serviceFile, "utf8")).toContain(join(prefix, "bin/lobby"));
    expect(lobby("version").out.trim()).toBe("0.0.1");
  });

  it("will not install over an installed copy", () => {
    const result = run("sh", [INSTALLER, "--archive", archiveB, "--no-start"], env());
    expect(result.status).not.toBe(0);
    expect(result.out).toContain("already installed");
    expect(readFileSync(join(prefix, "VERSION"), "utf8").trim()).toBe("0.0.1");
  });

  it("runs the server from the installed copy", async () => {
    // What its owner would do: listen only here, on a port that is free.
    writeFileSync(
      join(prefix, "lobby.config.json"),
      `${JSON.stringify({ serverName: "Lobby", dataDir: "data", host: "127.0.0.1", port }, null, 2)}\n`,
    );
    expect(run(join(root, "bin/launchctl"), ["bootstrap", "test"], env()).status).toBe(0);
    expect(await answers(port)).toBe(true);
    const info = (await (await fetch(`http://127.0.0.1:${String(port)}/v1/server`)).json()) as {
      version: string;
    };
    expect(info.version).toBe("0.0.1");
    expect(existsSync(join(prefix, "data/secrets.json"))).toBe(true);
  });

  it("updates to a newer release and keeps the data, the config and a helper put there", async () => {
    // A lobby-direct built on this computer: the archive has none, so it stays.
    writeFileSync(join(prefix, "bin/lobby-direct"), "#!/bin/sh\nexit 0\n", { mode: 0o755 });
    // The catalogue is not changed while the server is stopped; compare with it stopped.
    run(join(root, "bin/launchctl"), ["bootout", "test"], env());
    const data = fingerprint(join(prefix, "data"));
    const config = readFileSync(join(prefix, "lobby.config.json"), "utf8");
    run(join(root, "bin/launchctl"), ["bootstrap", "test"], env());
    expect(await answers(port)).toBe(true);
    writeFileSync(calls, "");

    const result = lobby("update", "--archive", archiveB);
    expect(result.status, result.out).toBe(0);
    expect(result.out).toContain("running");
    expect(lobby("version").out.trim()).toBe("0.0.2");
    expect(readFileSync(join(prefix, ".previous/VERSION"), "utf8").trim()).toBe("0.0.1");
    const info = (await (await fetch(`http://127.0.0.1:${String(port)}/v1/server`)).json()) as {
      version: string;
    };
    expect(info.version).toBe("0.0.2");

    expect(readFileSync(join(prefix, "lobby.config.json"), "utf8")).toBe(config);
    run(join(root, "bin/launchctl"), ["bootout", "test"], env());
    const after = fingerprint(join(prefix, "data"));
    for (const [file, hash] of data) {
      // The new version may write to the catalogue; nothing else that was there changes.
      if (file.startsWith("lobby.db")) continue;
      expect(after.get(file), file).toBe(hash);
    }
    expect(after.has("lobby.db")).toBe(true);
    // The backup the update made first, with the version before.
    expect([...after.keys()].some((file) => /^backups\/.+\/lobby\.db$/.test(file))).toBe(true);
    expect(readFileSync(join(prefix, "bin/lobby-direct"), "utf8")).toContain("exit 0");
    const called = readFileSync(calls, "utf8");
    expect(called).toMatch(
      process.platform === "darwin" ? /launchctl bootout/ : /systemctl --user stop/,
    );
    expect(called).toMatch(
      process.platform === "darwin" ? /launchctl bootstrap/ : /systemctl --user restart/,
    );
  });

  it("does nothing for the version that is there, and refuses an older one", () => {
    const same = lobby("update", "--archive", archiveB, "--no-start");
    expect(same.status, same.out).toBe(0);
    expect(same.out).toContain("installed already");
    const older = lobby("update", "--archive", archiveA, "--no-start");
    expect(older.status).not.toBe(0);
    expect(older.out).toContain("older");
    expect(lobby("version").out.trim()).toBe("0.0.2");
  });

  it("uninstalls the program and its service, and keeps the data and the config", () => {
    const data = fingerprint(join(prefix, "data"));
    const result = lobby("uninstall");
    expect(result.status, result.out).toBe(0);
    for (const part of ["app", "runtime", "bin", "installer", "VERSION", ".previous"]) {
      expect(existsSync(join(prefix, part)), part).toBe(false);
    }
    expect(existsSync(serviceFile)).toBe(false);
    // SQLite's own journal files come and go with the server; everything else stays.
    const sqlite = (files: Map<string, string>) =>
      new Map([...files].filter(([file]) => !/^lobby\.db-(wal|shm)$/.test(file)));
    expect(sqlite(fingerprint(join(prefix, "data")))).toEqual(sqlite(data));
    expect(existsSync(join(prefix, "lobby.config.json"))).toBe(true);
  });

  it("installs again over the kept data, and deletes it only when asked", () => {
    const config = readFileSync(join(prefix, "lobby.config.json"), "utf8");
    const again = run("sh", [INSTALLER, "--archive", archiveB, "--no-start"], env());
    expect(again.status, again.out).toBe(0);
    expect(again.out).toContain("Kept the config");
    expect(readFileSync(join(prefix, "lobby.config.json"), "utf8")).toBe(config);

    const unasked = run("sh", [join(prefix, "bin/lobby"), "uninstall", "--delete-data"], env());
    expect(unasked.status).not.toBe(0);
    expect(existsSync(join(prefix, "data"))).toBe(true);

    const gone = lobby("uninstall", "--delete-data", "--yes");
    expect(gone.status, gone.out).toBe(0);
    expect(existsSync(prefix)).toBe(false);
  });
});

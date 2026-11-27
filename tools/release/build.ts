// SPDX-License-Identifier: MPL-2.0
/**
 * Builds the release archives of Lobby Server: one per platform, each with the server, its
 * production dependencies, a private Node.js, the installer, and lobby-direct where it was built.
 *
 *   node tools/release/build.ts [options] [platform …]
 *
 *   --version <x.y.z>   The release. Default: the version in apps/server/package.json.
 *   --out <dir>         Where the archives go. Default: dist/release (git-ignored).
 *   --cache <dir>       Where Node downloads are kept. Default: ~/.cache/lobby-release.
 *   --direct-dir <dir>  lobby-direct programs built before: <dir>/<platform>/lobby-direct.
 *   --build-direct      Build lobby-direct here for each platform whose toolchain is here.
 *   --releases <url>    Where releases are published, written into the installer. Default: the
 *                       one in install.sh (this repository's GitHub Releases).
 *
 * Platforms: linux-arm64, linux-x64, macos-arm64, macos-x64 (default: all four). Needs Node 24,
 * npm, git, tar and xz; cargo for the notices of lobby-direct. The same commit, Node download and
 * lobby-direct give the same archive: file times are the commit's, owners are 0, the order is
 * sorted, and xz runs on one thread.
 */
import { execFileSync, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  chmodSync,
  copyFileSync,
  cpSync,
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  renameSync,
  rmSync,
  utimesSync,
  writeFileSync,
} from "node:fs";
import { homedir, tmpdir } from "node:os";
import { basename, dirname, join, relative, resolve } from "node:path";

export const PLATFORMS = {
  "linux-arm64": { node: "linux-arm64", rust: "aarch64-unknown-linux-musl" },
  "linux-x64": { node: "linux-x64", rust: "x86_64-unknown-linux-musl" },
  "macos-arm64": { node: "darwin-arm64", rust: "aarch64-apple-darwin" },
  "macos-x64": { node: "darwin-x64", rust: "x86_64-apple-darwin" },
} as const;
export type Platform = keyof typeof PLATFORMS;

const HERE = import.meta.dirname;
const REPO = resolve(HERE, "../..");

interface Options {
  version: string;
  out: string;
  cache: string;
  directDir: string | null;
  buildDirect: boolean;
  releases: string;
  platforms: Platform[];
}

interface NodeRuntime {
  version: string;
  sha256: Record<string, string>;
}

function isPlatform(name: string): name is Platform {
  return Object.hasOwn(PLATFORMS, name);
}

function readOptions(argv: string[]): Options {
  const serverPackage = JSON.parse(
    readFileSync(join(REPO, "apps/server/package.json"), "utf8"),
  ) as { version: string };
  const options: Options = {
    version: serverPackage.version,
    out: join(REPO, "dist/release"),
    cache: process.env["LOBBY_RELEASE_CACHE"] ?? join(homedir(), ".cache/lobby-release"),
    directDir: null,
    buildDirect: false,
    releases: "",
    platforms: [],
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index] ?? "";
    const value = (): string => {
      const next = argv[index + 1];
      if (next === undefined) throw new Error(`${arg} needs a value.`);
      index += 1;
      return next;
    };
    if (arg === "--version") options.version = value().replace(/^v/, "");
    else if (arg === "--out") options.out = resolve(value());
    else if (arg === "--cache") options.cache = resolve(value());
    else if (arg === "--direct-dir") options.directDir = resolve(value());
    else if (arg === "--build-direct") options.buildDirect = true;
    else if (arg === "--releases") options.releases = value().replace(/\/+$/, "");
    else if (isPlatform(arg)) options.platforms.push(arg);
    else throw new Error(`Unknown option or platform: ${arg}`);
  }
  if (!/^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$/.test(options.version)) {
    throw new Error(`Not a version: ${options.version}`);
  }
  if (options.releases !== "" && !/^https:\/\/[^\s"'`$\\]+$/.test(options.releases)) {
    throw new Error("--releases must be an https:// address.");
  }
  if (options.platforms.length === 0) options.platforms = Object.keys(PLATFORMS) as Platform[];
  return options;
}

function run(command: string, args: string[], cwd = REPO, env?: NodeJS.ProcessEnv): string {
  return execFileSync(command, args, {
    cwd,
    encoding: "utf8",
    env: env ?? process.env,
    stdio: ["ignore", "pipe", "inherit"],
  });
}

function sha256(path: string): string {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

/** The Node archive for a platform, from the cache or nodejs.org, checked against the pinned hash. */
async function nodeArchive(runtime: NodeRuntime, nodePlatform: string, cache: string) {
  const name = `node-${runtime.version}-${nodePlatform}.tar.xz`;
  const expected = runtime.sha256[nodePlatform];
  if (expected === undefined) throw new Error(`No pinned checksum for ${name}.`);
  const path = join(cache, "node", name);
  if (existsSync(path) && sha256(path) === expected) return { name, path };
  mkdirSync(dirname(path), { recursive: true });
  const url = `https://nodejs.org/dist/${runtime.version}/${name}`;
  console.log(`Downloading ${url}`);
  const response = await fetch(url);
  if (!response.ok) throw new Error(`${url}: ${String(response.status)}`);
  const partial = `${path}.part`;
  writeFileSync(partial, Buffer.from(await response.arrayBuffer()));
  const actual = sha256(partial);
  if (actual !== expected) {
    rmSync(partial);
    throw new Error(`${name} has SHA-256 ${actual}, not the pinned ${expected}.`);
  }
  renameSync(partial, path);
  return { name, path };
}

/** The server's files as git knows them, without its tests. */
function stageApp(target: string, version: string): void {
  const files = run("git", ["ls-files", "-z", "--", "apps/server"])
    .split("\0")
    .filter((file) => file !== "")
    .map((file) => relative("apps/server", file))
    .filter(
      (file) =>
        !file.startsWith("test/") &&
        file !== "vitest.config.ts" &&
        file !== "tsconfig.json" &&
        existsSync(join(REPO, "apps/server", file)),
    );
  for (const file of files) {
    mkdirSync(dirname(join(target, file)), { recursive: true });
    copyFileSync(join(REPO, "apps/server", file), join(target, file));
  }
  const packagePath = join(target, "package.json");
  const pkg = JSON.parse(readFileSync(packagePath, "utf8")) as Record<string, unknown>;
  if (pkg["version"] !== version) {
    pkg["version"] = version;
    writeFileSync(packagePath, `${JSON.stringify(pkg, null, 2)}\n`);
  }
}

/** The server's production dependencies, exactly as package-lock.json has them. */
function stageDependencies(target: string, work: string): void {
  const root = join(work, "npm");
  mkdirSync(root, { recursive: true });
  const rootPackage = JSON.parse(readFileSync(join(REPO, "package.json"), "utf8")) as {
    workspaces: string[];
  };
  copyFileSync(join(REPO, "package.json"), join(root, "package.json"));
  copyFileSync(join(REPO, "package-lock.json"), join(root, "package-lock.json"));
  for (const workspace of rootPackage.workspaces) {
    mkdirSync(join(root, workspace), { recursive: true });
    copyFileSync(join(REPO, workspace, "package.json"), join(root, workspace, "package.json"));
  }
  run(
    "npm",
    [
      "ci",
      "--omit=dev",
      "--workspace=apps/server",
      "--include-workspace-root=false",
      "--ignore-scripts",
      "--no-audit",
      "--no-fund",
    ],
    root,
  );
  const modules = join(root, "node_modules");
  // Links to the workspaces and to command-line tools, and npm's own notes: none are needed.
  for (const name of [".bin", "@lobby", ".package-lock.json"]) {
    rmSync(join(modules, name), { recursive: true, force: true });
  }
  renameSync(modules, join(target, "node_modules"));
}

interface Notice {
  name: string;
  version: string;
  license: string;
  texts: { file: string; text: string }[];
}

const LICENSE_FILE = /^(licen[cs]e|copying|notice)([.-].*)?$/i;

function licenseTexts(dir: string): { file: string; text: string }[] {
  return readdirSync(dir)
    .filter((file) => LICENSE_FILE.test(file) && lstatSync(join(dir, file)).isFile())
    .sort()
    .map((file) => ({ file, text: readFileSync(join(dir, file), "utf8").trimEnd() }));
}

function npmNotices(modules: string): Notice[] {
  const dirs: string[] = [];
  for (const entry of readdirSync(modules).sort()) {
    if (entry.startsWith("@")) {
      for (const inner of readdirSync(join(modules, entry)).sort()) {
        dirs.push(join(modules, entry, inner));
      }
    } else if (!entry.startsWith(".")) {
      dirs.push(join(modules, entry));
    }
  }
  return dirs.map((dir) => {
    const pkg = JSON.parse(readFileSync(join(dir, "package.json"), "utf8")) as {
      name: string;
      version: string;
      license?: string;
    };
    return {
      name: pkg.name,
      version: pkg.version,
      license: pkg.license ?? "see the text",
      texts: licenseTexts(dir),
    };
  });
}

/** The crates in lobby-direct for one target, with their licences, from cargo. */
function crateNotices(rustTarget: string): Notice[] {
  const manifest = join(REPO, "apps/direct/Cargo.toml");
  // Every platform's crates, not only the target's: `cargo tree --target` also resolves what the
  // build scripts and proc-macros need on the host, which differs when the target is another
  // platform (cpufeatures for an aarch64 target on an x86_64 runner).
  run("cargo", ["fetch", "--locked", "--manifest-path", manifest]);
  const inBinary = new Set(
    run("cargo", [
      "tree",
      "--locked",
      "--offline",
      "-e",
      "normal",
      "--target",
      rustTarget,
      "--prefix",
      "none",
      "-f",
      "{p}",
      "--manifest-path",
      manifest,
    ])
      .split("\n")
      .filter((line) => line !== "" && !line.includes("(proc-macro)"))
      .map((line) => line.replace(/ \(\*\)$/, "").split(" "))
      .filter(([name]) => name !== "lobby-direct")
      .map(([name, version]) => `${name ?? ""} ${(version ?? "").replace(/^v/, "")}`),
  );
  const metadata = JSON.parse(
    run("cargo", [
      "metadata",
      "--locked",
      "--offline",
      "--format-version",
      "1",
      "--manifest-path",
      manifest,
    ]),
  ) as {
    packages: { name: string; version: string; license: string | null; manifest_path: string }[];
  };
  const notices = metadata.packages
    .filter((one) => inBinary.has(`${one.name} ${one.version}`))
    .sort((a, b) => a.name.localeCompare(b.name) || a.version.localeCompare(b.version))
    .map((one) => ({
      name: one.name,
      version: one.version,
      license: one.license ?? "see the text",
      texts: licenseTexts(dirname(one.manifest_path)),
    }));
  const juice = join(REPO, "apps/direct/vendor/libjuice");
  notices.push({
    name: "libjuice (vendored unchanged in apps/direct/vendor/libjuice)",
    version: "",
    license: "MPL-2.0; its source is in Lobby's source and at github.com/paullouisageneau/libjuice",
    texts: licenseTexts(juice),
  });
  return notices;
}

function noticesText(
  version: string,
  nodeVersion: string,
  nodeLicense: string,
  npm: Notice[],
  crates: Notice[] | null,
): string {
  // A licence text that many packages carry word for word is written out once.
  const seen = new Map<string, string>();
  const section = (title: string, notices: Notice[]): string =>
    [
      `${"=".repeat(78)}\n${title}\n${"=".repeat(78)}`,
      ...notices.map((one) => {
        const label = `${one.name}${one.version === "" ? "" : ` ${one.version}`}`;
        return [
          `\n--- ${label} (${one.license})`,
          ...one.texts.map((text) => {
            const first = seen.get(text.text);
            if (first !== undefined) return `\n[${text.file}: the same text as ${first}]`;
            seen.set(text.text, `${text.file} of ${label}`);
            return `\n[${text.file}]\n\n${text.text}`;
          }),
        ].join("\n");
      }),
    ].join("\n");
  return [
    `Lobby Server ${version}: third-party software in this archive`,
    "",
    "ffmpeg and ffprobe are not in it: they come from the system and keep their own licences.",
    "",
    section(`Node.js ${nodeVersion} (runtime/bin/node)`, [
      {
        name: "Node.js",
        version: nodeVersion,
        license: "MIT, with the licences of its parts",
        texts: [{ file: "LICENSE", text: nodeLicense.trimEnd() }],
      },
    ]),
    section("npm packages (app/node_modules)", npm),
    crates === null ? "" : section("Rust crates and C code in bin/lobby-direct", crates),
    "",
  ].join("\n\n");
}

/** Same modes and times everywhere, so that the archive depends on the content only. */
function normalise(root: string, epoch: number, executables: Set<string>): string[] {
  const paths: string[] = [];
  const walk = (dir: string): void => {
    for (const entry of readdirSync(dir).sort()) {
      const path = join(dir, entry);
      const stat = lstatSync(path);
      const rel = relative(dirname(root), path);
      if (stat.isSymbolicLink()) throw new Error(`A link has no place in the archive: ${rel}`);
      if (stat.isDirectory()) {
        chmodSync(path, 0o755);
        paths.push(rel);
        walk(path);
      } else {
        chmodSync(path, executables.has(relative(root, path)) ? 0o755 : 0o644);
        paths.push(rel);
      }
    }
  };
  chmodSync(root, 0o755);
  paths.push(basename(root));
  walk(root);
  for (const rel of paths) utimesSync(join(dirname(root), rel), epoch, epoch);
  return paths.sort();
}

function tarIsGnu(): boolean {
  return spawnSync("tar", ["--version"], { encoding: "utf8" }).stdout.includes("GNU tar");
}

function writeArchive(parent: string, paths: string[], out: string, epoch: number): void {
  const list = join(parent, "..", `${basename(out)}.list`);
  writeFileSync(list, `${paths.join("\n")}\n`);
  const flags = tarIsGnu()
    ? [
        "--format=ustar",
        "--owner=0",
        "--group=0",
        "--numeric-owner",
        `--mtime=@${String(epoch)}`,
        "--no-xattrs",
        "--no-acls",
      ]
    : [
        "--format",
        "ustar",
        "--uid",
        "0",
        "--gid",
        "0",
        "--uname",
        "root",
        "--gname",
        "root",
        "--no-xattrs",
        "--no-acls",
        "--no-fflags",
        "--no-mac-metadata",
      ];
  // tar | xz, with the names passed as arguments rather than spliced into the line.
  execFileSync(
    "sh",
    ["-c", 'tar "$@" -cf - | xz -6 -T1 -c > "$OUT"', "sh", ...flags, "--no-recursion", "-T", list],
    {
      cwd: parent,
      stdio: ["ignore", "inherit", "inherit"],
      env: { ...process.env, OUT: out, LC_ALL: "C", TZ: "UTC", COPYFILE_DISABLE: "1" },
    },
  );
  rmSync(list);
}

function directProgram(options: Options, platform: Platform, work: string): string | null {
  const given = options.directDir && join(options.directDir, platform, "lobby-direct");
  if (given && existsSync(given)) return given;
  if (!options.buildDirect) return null;
  const out = join(work, "direct", platform, "lobby-direct");
  const built = spawnSync("sh", [join(HERE, "build-direct.sh"), platform, out], {
    cwd: REPO,
    stdio: "inherit",
    env: { ...process.env, LOBBY_RELEASE_CACHE: options.cache },
  });
  if (built.status === 0) return out;
  if (built.status === 3) return null;
  throw new Error(`Building lobby-direct for ${platform} failed.`);
}

async function main(): Promise<void> {
  const options = readOptions(process.argv.slice(2));
  const runtime = JSON.parse(readFileSync(join(HERE, "node-runtime.json"), "utf8")) as NodeRuntime;
  const commit = run("git", ["rev-parse", "HEAD"]).trim();
  const dirty = run("git", ["status", "--porcelain", "--", "apps/server", "package-lock.json"]);
  const epoch = Number(
    process.env["SOURCE_DATE_EPOCH"] ?? run("git", ["log", "-1", "--format=%ct"]).trim(),
  );
  if (dirty !== "") {
    console.warn("Note: apps/server has changes that are not committed; the archive has them too.");
  }

  const work = mkdtempSync(join(tmpdir(), "lobby-release-"));
  try {
    const common = join(work, "common");
    stageApp(join(common, "app"), options.version);
    stageDependencies(join(common, "app"), work);
    const npm = npmNotices(join(common, "app/node_modules"));
    const source = readFileSync(join(HERE, "install.sh"), "utf8");
    // Without --releases the installer keeps the address it has in the source.
    const installer =
      options.releases === ""
        ? source
        : source.replace(/^RELEASES_DEFAULT="[^"]*"$/m, `RELEASES_DEFAULT="${options.releases}"`);
    mkdirSync(options.out, { recursive: true });
    const written: { name: string; hash: string }[] = [];

    for (const platform of options.platforms) {
      const name = `lobby-server-${options.version}-${platform}`;
      const stage = join(work, "stage", platform);
      const root = join(stage, name);
      mkdirSync(root, { recursive: true });
      cpSync(join(common, "app"), join(root, "app"), { recursive: true });

      const node = await nodeArchive(runtime, PLATFORMS[platform].node, options.cache);
      const unpacked = join(work, "node", platform);
      mkdirSync(unpacked, { recursive: true });
      const inner = node.name.replace(/\.tar\.xz$/, "");
      run("tar", ["-xJf", node.path, "-C", unpacked, `${inner}/bin/node`, `${inner}/LICENSE`]);
      mkdirSync(join(root, "runtime/bin"), { recursive: true });
      renameSync(join(unpacked, inner, "bin/node"), join(root, "runtime/bin/node"));
      const nodeLicense = readFileSync(join(unpacked, inner, "LICENSE"), "utf8");
      renameSync(join(unpacked, inner, "LICENSE"), join(root, "runtime/LICENSE"));

      mkdirSync(join(root, "bin"), { recursive: true });
      copyFileSync(join(HERE, "lobby.sh"), join(root, "bin/lobby"));
      const direct = directProgram(options, platform, work);
      if (direct) copyFileSync(direct, join(root, "bin/lobby-direct"));
      else console.warn(`Note: ${name} has no lobby-direct (see docs/release.md).`);

      mkdirSync(join(root, "installer"), { recursive: true });
      writeFileSync(join(root, "installer/install.sh"), installer);
      writeFileSync(join(root, "VERSION"), `${options.version}\n`);
      writeFileSync(
        join(root, "BUILD.json"),
        `${JSON.stringify(
          {
            version: options.version,
            platform,
            commit,
            uncommittedChanges: dirty !== "",
            node: runtime.version,
            lobbyDirect: direct !== null,
          },
          null,
          2,
        )}\n`,
      );
      writeFileSync(join(root, "README.txt"), readme(options.version, platform, direct !== null));
      mkdirSync(join(root, "LICENSES"), { recursive: true });
      // Lobby's own licence, then everything else's.
      copyFileSync(join(REPO, "LICENSE"), join(root, "LICENSES/LICENSE"));
      writeFileSync(
        join(root, "LICENSES/THIRD-PARTY-NOTICES.txt"),
        noticesText(
          options.version,
          runtime.version,
          nodeLicense,
          npm,
          direct ? crateNotices(PLATFORMS[platform].rust) : null,
        ),
      );

      const paths = normalise(
        root,
        epoch,
        new Set(["bin/lobby", "bin/lobby-direct", "runtime/bin/node", "installer/install.sh"]),
      );
      const archive = join(options.out, `${name}.tar.xz`);
      writeArchive(stage, paths, archive, epoch);
      written.push({ name: basename(archive), hash: sha256(archive) });
      console.log(`${basename(archive)}  ${written.at(-1)?.hash ?? ""}`);
    }

    const installerOut = join(options.out, "install.sh");
    writeFileSync(installerOut, installer, { mode: 0o755 });
    written.push({ name: "install.sh", hash: sha256(installerOut) });
    // Every archive in the folder, also ones of earlier runs for other platforms.
    const sumsPath = join(options.out, "SHA256SUMS");
    const known = new Map<string, string>();
    if (existsSync(sumsPath)) {
      for (const line of readFileSync(sumsPath, "utf8").split("\n")) {
        const [hash, file] = line.split("  ");
        if (hash && file && existsSync(join(options.out, file))) known.set(file, hash);
      }
    }
    for (const one of written) known.set(one.name, one.hash);
    writeFileSync(
      sumsPath,
      [...known]
        .sort(([a], [b]) => a.localeCompare(b))
        .map(([file, hash]) => `${hash}  ${file}\n`)
        .join(""),
    );
    console.log(`Written to ${options.out}`);
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
}

function readme(version: string, platform: Platform, direct: boolean): string {
  return `Lobby Server ${version} for ${platform}

Install it with the installer that comes with it, which checks this archive first:

  sh install.sh --archive lobby-server-${version}-${platform}.tar.xz

(install.sh and SHA256SUMS are published beside the archive.) It goes to ~/lobby, writes a config
and a service, and keeps the data folder on every update. Lobby needs ffmpeg and ffprobe.

  app/        Lobby Server and its dependencies
  runtime/    Node.js, only for Lobby
  bin/lobby   the command: lobby help, lobby update, lobby uninstall
${direct ? "  bin/lobby-direct  the direct connection's helper\n" : "  (no lobby-direct: build it as docs/release.md in Lobby's source says, into bin/)\n"}  LICENSES/   Lobby's licence (MPL-2.0) and those of the software in this archive
`;
}

if (process.argv[1] && resolve(process.argv[1]) === resolve(HERE, "build.ts")) {
  main().catch((error: unknown) => {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(1);
  });
}

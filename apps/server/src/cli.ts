#!/usr/bin/env node
// SPDX-License-Identifier: MPL-2.0
import { join, resolve } from "node:path";
import { ACCESS, ROLES, type Access, type Role } from "./auth/devices.ts";
import { createBackup, listBackups, pruneBackups, restoreBackup } from "./backup.ts";
import { loadConfig } from "./config.ts";
import { probeFile } from "./library/probe.ts";
import { Studios } from "./library/studios.ts";
import { errorMessage } from "./log.ts";
import { BoxKeys, forgetKeys } from "./outside/direct/keys.ts";
import { OUTSIDE_SWITCH } from "./outside/index.ts";
import {
  openServices,
  RESTART_EXIT_CODE,
  startServer,
  VERSION,
  type RunningServer,
} from "./server.ts";
import { readSettings, settingsHistory, settingsVersion, writeSettings } from "./settings/store.ts";

const HELP = `Lobby Server ${VERSION}

Usage: lobby <command> [options]

  serve                     Run the server.
  scan                      Scan the library once and exit.
  status                    Show what is in the catalogue.
  approve <code> [role]     Approve the device showing <code>. Role: viewer (default), householdAdmin or admin (manager).
  devices                   List paired devices.
  revoke <device id>        Remove a paired device.
  outside [off]             Show whether the outside entrance is on, or turn it off at once.
  direct id                 The box id that the introducer has to know.
  direct <rotate|reset>     Use the next certificate of the direct connection now, or forget its
                            keys and every device's. Restart the server afterwards.
  tags [all]                HEVC files whose picture label is not hvc1 (Apple devices show
                            only hvc1). MKV files are left out unless "all": they are
                            relabelled on every copy anyway. Changes nothing.
  studios [min]             What TMDB says made the titles, and the studios with at least
                            <min> (8) of them that could be categories. Changes nothing.
  setup-secret              Print the secret that claims this server's first manager.
  settings [history]        Show the settings managers changed in the app, or their versions.
  settings restore <n>      Use an earlier version of those settings again. Stop the server first.
  backup                    Back the catalogue up now. Safe while the server runs.
  backups                   List the backups.
  restore <backup>          Put a backup into an empty data folder. Stop the server first.

Installed from a release archive, bin/lobby also has:
  update [--version <v>]    Install a newer release. Keeps the data folder and the config.
  uninstall [--delete-data] Remove the program and its service. Keeps the data unless asked.
  version                   The version that is installed.

Options:
  --config <path>           Config file. Default: $LOBBY_CONFIG, or ./lobby.config.json.
`;

function parseArgs(argv: string[]): { command: string; args: string[]; configPath: string } {
  const args: string[] = [];
  let configPath = process.env["LOBBY_CONFIG"] ?? "lobby.config.json";
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index] ?? "";
    if (arg === "--config") {
      configPath = argv[index + 1] ?? configPath;
      index += 1;
    } else {
      args.push(arg);
    }
  }
  return { command: args[0] ?? "help", args: args.slice(1), configPath: resolve(configPath) };
}

function when(at: number | null): string {
  return at === null ? "never" : new Date(at).toISOString().slice(0, 16).replace("T", " ");
}

async function main(): Promise<void> {
  const { command, args, configPath } = parseArgs(process.argv.slice(2));
  if (command === "help" || command === "--help" || command === "-h") {
    console.log(HELP);
    return;
  }
  if (command === "update" || command === "uninstall") {
    throw new Error(
      `"lobby ${command}" belongs to an installed copy: run bin/lobby in the folder Lobby was installed in.`,
    );
  }
  const config = loadConfig(configPath);

  if (command === "serve") {
    let running: RunningServer | null = null;
    const restart = (): void => {
      const closing = running;
      running = null;
      void (async () => {
        await closing?.close();
        // A supervisor starts it again: a fresh process, fresh state. systemd sets INVOCATION_ID
        // (Restart= in the units); launchd and Docker are told with LOBBY_SUPERVISED=1.
        if (process.env["INVOCATION_ID"] !== undefined || process.env["LOBBY_SUPERVISED"] === "1") {
          process.exit(RESTART_EXIT_CODE);
        }
        // Without one, as in `npm run server:dev`, it starts again in this process.
        console.log("Restarting to take the new settings…");
        running = await startServer(loadConfig(configPath), { restart });
      })().catch((error: unknown) => {
        console.error(errorMessage(error));
        process.exit(1);
      });
    };
    running = await startServer(config, { restart });
    const stop = (): void => {
      void (running?.close() ?? Promise.resolve()).then(() => process.exit(0));
    };
    process.on("SIGINT", stop);
    process.on("SIGTERM", stop);
    return;
  }

  if (command === "settings") {
    const dataDir = config.dataDir;
    if (args[0] === undefined) {
      const current = readSettings(dataDir);
      if (!current) {
        console.log("No settings were changed in the app yet: lobby.config.json holds them all.");
        return;
      }
      console.log(`Version ${String(current.version)}, ${when(current.at)} (${current.reason})`);
      console.log(JSON.stringify(current.values, null, 2));
      return;
    }
    if (args[0] === "history") {
      for (const one of settingsHistory(dataDir)) {
        console.log(
          `${String(one.version).padStart(4)}  ${when(one.at)}  ${one.reason}  ${one.changed.join(", ")}`,
        );
      }
      return;
    }
    if (args[0] === "restore" && args[1] !== undefined) {
      // For a server that does not start with what a manager set. The server must be stopped.
      const current = readSettings(dataDir);
      const earlier = settingsVersion(dataDir, Number(args[1]));
      if (!current || !earlier) throw new Error("That version is not kept.");
      writeSettings(dataDir, {
        version: current.version + 1,
        at: Date.now(),
        by: null,
        reason: `restored ${String(earlier.version)} with the lobby command`,
        changed: Object.keys({ ...current.values, ...earlier.values }).filter(
          (key) => JSON.stringify(current.values[key]) !== JSON.stringify(earlier.values[key]),
        ),
        values: earlier.values,
      });
      console.log(`Version ${String(earlier.version)} is in use again. Start the server.`);
      return;
    }
    throw new Error("Usage: lobby settings [history | restore <version>]");
  }

  if (command === "restore") {
    const backup = args[0];
    if (!backup) throw new Error("Usage: lobby restore <backup folder or .db file>");
    for (const note of restoreBackup(resolve(backup), config.dataDir)) console.log(note);
    console.log(`Restored into ${config.dataDir}. Start the server; it will rescan the library.`);
    return;
  }
  if (command === "backups") {
    for (const backup of listBackups(config.backup.dir)) console.log(backup.path);
    return;
  }

  const services = openServices(config);
  try {
    switch (command) {
      case "backup": {
        const backup = await createBackup(
          services.db,
          config.backup.dir,
          config.configPath,
          Date.now(),
          config.dataDir,
        );
        pruneBackups(config.backup.dir, config.backup.keep);
        console.log(`Backed up to ${backup.path}`);
        break;
      }
      case "scan": {
        const started = Date.now();
        let summary = await services.scanner.scanAll();
        if (summary.settling > 0) {
          console.log(
            `Waiting ${Math.round(config.stabilityMs / 1000)} s to see that ${summary.settling} new files are complete…`,
          );
          await new Promise((done) => setTimeout(done, config.stabilityMs + 500));
          summary = await services.scanner.scanAll();
        }
        let audio = await services.music.scanner.scanAll();
        if (audio.settling > 0) {
          console.log(`Waiting to see that ${audio.settling} new audio files are complete…`);
          await new Promise((done) => setTimeout(done, config.stabilityMs + 500));
          audio = await services.music.scanner.scanAll();
        }
        const read =
          (await services.scanner.processQueue()) + (await services.music.scanner.processQueue());
        console.log(
          `Scan finished in ${Math.round((Date.now() - started) / 1000)} s. Files read: ${read}.`,
        );
        const away = [...summary.unavailableSources, ...audio.unavailableSources];
        if (away.length > 0) {
          console.log(`Not reachable: ${away.join(", ")}`);
        }
        break;
      }
      case "studios": {
        const min = Number(args[0] ?? "8");
        if (!Number.isInteger(min) || min < 1) throw new Error("min must be a whole number from 1");
        const counts = services.db.get<{ titles: number; read: number; with: number }>(
          `select count(*) as titles, coalesce(sum(studios_at is not null), 0) as read,
             coalesce(sum(exists (select 1 from item_studio where item_id = item.id)), 0) as with
           from item where kind in ('movie', 'show') and parent_id is null and tmdb_id is not null`,
        );
        console.log(
          `Films and shows matched: ${counts?.titles ?? 0}; studios read: ${counts?.read ?? 0}; with a studio: ${counts?.with ?? 0}.`,
        );
        if ((counts?.read ?? 0) < (counts?.titles ?? 0)) {
          console.log("The rest are read a few at a time by the server's monthly refresh.");
        }
        const found = new Studios(services.db).suggestions(min);
        if (found.length === 0) console.log(`No studio has ${min} titles without a category.`);
        for (const one of found) {
          const named = one.categoryId === null ? "" : " (a category has this name)";
          console.log(`\n${one.name}: ${one.count} titles${named}`);
          for (const studio of one.studios) {
            console.log(`  ${studio.id.padEnd(16)} ${studio.name} (${studio.titles})`);
          }
          console.log(`  e.g. ${one.titles.map((title) => title.title).join(", ")}`);
        }
        break;
      }
      case "tags": {
        if (args[0] !== undefined && args[0] !== "all") throw new Error("Usage: lobby tags [all]");
        const rows = services.db.all<{
          id: string;
          path: string;
          rel_path: string;
          container: string | null;
          playability: string | null;
          codec_tag: string | null;
          available: number;
        }>(
          `select asset.id, source.path, asset.rel_path, asset.container, asset.playability,
             track.codec_tag, (asset.available = 1 and source.available = 1) as available
           from track join asset on asset.id = track.asset_id join source on source.id = asset.source_id
           where track.kind = 'video' and track.codec = 'hevc' and asset.state = 'probed'
             and (track.codec_tag is null or track.codec_tag not in ('hvc1', 'dvh1'))
             ${args[0] === "all" ? "" : "and asset.container in ('mp4', 'mov', 'm4v')"}
           order by asset.playability, source.path, asset.rel_path`,
        );
        const counts = new Map<string, number>();
        for (const row of rows) {
          let tag = row.codec_tag;
          // Not read yet: read it now, headers only, without writing it down.
          if (tag === null && row.available === 1) {
            try {
              const probe = await probeFile(join(row.path, row.rel_path), config.ffprobePath);
              tag = probe.tracks.find((track) => track.kind === "video")?.codecTag ?? null;
            } catch {
              tag = null;
            }
          }
          const label = tag === null ? "unknown" : tag === "" ? "none" : tag;
          counts.set(label, (counts.get(label) ?? 0) + 1);
          console.log(
            `${label.padEnd(8)} ${(row.container ?? "?").padEnd(4)} ${(row.playability ?? "?").padEnd(7)} ${row.id}  ${row.rel_path}`,
          );
        }
        console.log(
          rows.length === 0
            ? "Every HEVC file is labelled hvc1."
            : `\n${[...counts].map(([label, n]) => `${label}: ${n}`).join(", ")}` +
                ' (a file still marked "direct" with a label other than hvc1 is repackaged once the server has read it)',
        );
        break;
      }
      case "status": {
        const rows = services.db.all<{ label: string; n: number }>(
          `select 'films' as label, count(*) as n from item where kind = 'movie'
           union all select 'shows', count(*) from item where kind = 'show'
           union all select 'episodes', count(*) from item where kind = 'episode'
           union all select 'extras', count(*) from item where kind = 'extra'
           union all select 'need review', count(*) from item where match_status = 'needs_review'
           union all select 'files', count(*) from asset
           union all select 'files waiting', count(*) from asset where state = 'discovered'
           union all select 'files unreadable', count(*) from asset where state = 'failed'
           union all select 'plays directly', count(*) from asset where playability = 'direct'
           union all select 'needs repackaging', count(*) from asset where playability = 'remux'
           union all select 'needs converting', count(*) from asset where playability = 'transcode'
           union all select 'unsupported', count(*) from asset where playability = 'unsupported'`,
        );
        for (const row of rows) console.log(`${row.label.padEnd(20)} ${row.n}`);
        break;
      }
      case "approve": {
        const code = args[0];
        const role = (args[1] ?? "viewer") as Access | Role;
        if (!code || !(ROLES.includes(role as Role) || ACCESS.includes(role as Access)))
          throw new Error("Usage: lobby approve <code> [viewer|householdAdmin|admin]");
        const approved = services.devices.approve(code, role, "cli");
        console.log(
          `Approved "${approved.deviceName}" (${approved.platform}) as ${approved.access}.`,
        );
        break;
      }
      case "devices": {
        for (const device of services.devices.list()) {
          console.log(
            `${device.id}  ${device.access.padEnd(14)} ${device.platform.padEnd(6)} ${device.name}` +
              `  last used ${when(device.lastUsedAt)}${device.revokedAt === null ? "" : "  REMOVED"}`,
          );
        }
        break;
      }
      case "revoke": {
        const id = args[0];
        if (!id) throw new Error("Usage: lobby revoke <device id>");
        services.devices.revoke(id);
        console.log("Removed. The device's next request is refused.");
        break;
      }
      case "outside": {
        if (args[0] !== undefined && args[0] !== "off")
          throw new Error("Usage: lobby outside [off]");
        // Turning it on is for a manager's device, where it shows what that means.
        if (args[0] === "off") services.db.setMeta(OUTSIDE_SWITCH, "off");
        const on = config.outside !== null && services.db.getMeta(OUTSIDE_SWITCH) === "on";
        console.log(
          `The outside entrance is ${config.outside === null ? "not set up" : on ? "on" : "off"}.`,
        );
        break;
      }
      case "direct": {
        if (args[0] === "rotate") {
          new BoxKeys(config.dataDir).rotate();
          console.log("The next certificate is in use once the server has been restarted.");
        } else if (args[0] === "reset") {
          forgetKeys(config.dataDir);
          services.db.run("delete from direct_device");
          console.log(
            "The keys are gone. Restart the server, give the introducer the new box id, and let every device connect at home once.",
          );
        } else if (args[0] === "id") {
          console.log(new BoxKeys(config.dataDir).boxId);
        } else {
          throw new Error("Usage: lobby direct <id|rotate|reset>");
        }
        break;
      }
      case "setup-secret": {
        console.log(
          services.devices.isClaimed
            ? "This server already has a manager. New devices pair with a code."
            : services.setupSecret,
        );
        break;
      }
      default:
        console.log(HELP);
        process.exitCode = 1;
    }
  } finally {
    services.db.close();
  }
}

main().catch((error: unknown) => {
  console.error(errorMessage(error));
  process.exit(1);
});

// SPDX-License-Identifier: MPL-2.0
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Devices } from "../../src/auth/devices.ts";
import { loadConfig } from "../../src/config.ts";
import type { Database } from "../../src/db/database.ts";
import { FolderBrowser } from "../../src/settings/browse.ts";
import { SettingsService } from "../../src/settings/service.ts";

/** The settings routes for a test app, with a config of its own in `dir`, changed nowhere else. */
export function settingsFor(
  db: Database,
  devices: Devices,
  dir: string,
): { service: SettingsService; browser: FolderBrowser } {
  const configPath = join(dir, "lobby.config.json");
  writeFileSync(configPath, JSON.stringify({ dataDir: join(dir, "settings-data") }));
  const browser = new FolderBrowser(() => [dir]);
  const service = new SettingsService({
    configPath,
    config: loadConfig(configPath),
    db,
    devices,
    browser,
    hasTmdbKey: false,
    checkKey: () => Promise.resolve("refused"),
    hooks: {
      apply: () => Promise.resolve(),
      restart: () => undefined,
      setTmdbKey: () => undefined,
      startScanning: () => undefined,
    },
  });
  service.ensure();
  return { service, browser };
}

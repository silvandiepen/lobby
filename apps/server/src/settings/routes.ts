// SPDX-License-Identifier: MPL-2.0
import type { Hono } from "hono";
import type { Device } from "../auth/devices.ts";
import { ApiError, readBody, type AppEnv, type Ctx } from "../http/app.ts";
import { isNearby, peerAddress } from "../http/home.ts";
import { RateLimiter } from "../outside/limits.ts";
import { BrowseError, type FolderBrowser } from "./browse.ts";
import { SettingsError, type SettingsService } from "./service.ts";

interface SettingsRouteDeps {
  settings: SettingsService;
  browser: FolderBrowser;
  requireManager: (c: Ctx, action: string) => Device;
  now?: () => number;
}

/** Settings are small: 64 folders with their names fit many times over. */
const MAX_SETTINGS_BODY = 128 * 1024;
const MAX_KEY_BODY = 4 * 1024;

/** Per device. Generous for a person, too few for a program trying things. */
export const SETTINGS_RATES = {
  change: { burst: 20, perMinute: 10 },
  browse: { burst: 60, perMinute: 60 },
  tmdb: { burst: 5, perMinute: 1 },
} as const;

function translate(error: unknown): never {
  if (error instanceof SettingsError) {
    throw new ApiError(
      error.code,
      error.message,
      error.problems.length > 0 ? { problems: error.problems } : {},
    );
  }
  if (error instanceof BrowseError) throw new ApiError(error.code, error.message);
  throw error;
}

/**
 * A manager's settings of the server, its first setup and its TMDB key. For managers at home or
 * in the tailnet only: the outside entrance has none of these routes, and kids devices neither.
 */
export function registerSettingsRoutes(app: Hono<AppEnv>, deps: SettingsRouteDeps): void {
  const { settings, browser, requireManager } = deps;
  const now = deps.now ?? Date.now;
  const limits = {
    change: new RateLimiter(SETTINGS_RATES.change, now),
    browse: new RateLimiter(SETTINGS_RATES.browse, now),
    tmdb: new RateLimiter(SETTINGS_RATES.tmdb, now),
  };

  /** A manager, close by, who has not asked too often. */
  const manager = (c: Ctx, action: string, rate: keyof typeof limits | null = null): Device => {
    const device = requireManager(c, action);
    const peer = peerAddress(c);
    if (peer !== null && !isNearby(peer)) {
      throw new ApiError(
        "forbidden",
        "The server's settings can only be changed at home or over Tailscale.",
      );
    }
    if (rate !== null) {
      const wait = limits[rate].take(device.id);
      if (wait > 0) {
        c.header("Retry-After", String(wait));
        throw new ApiError("rate_limited", "That was a lot at once. Try again in a moment.");
      }
    }
    c.header("Cache-Control", "no-store");
    return device;
  };

  const booleanOf = (body: Record<string, unknown>, key: string): boolean => {
    const value = body[key] ?? false;
    if (typeof value !== "boolean")
      throw new ApiError("invalid_request", `"${key}" must be true or false.`);
    return value;
  };

  const answerChange = (
    c: Ctx,
    result: Awaited<ReturnType<SettingsService["change"]>>,
    dryRun: boolean,
  ): Response => {
    const restarting = !dryRun && result.plan.restart && result.plan.changed.length > 0;
    if (restarting) settings.restartSoon();
    return c.json({
      dryRun,
      version: result.version,
      changed: result.plan.changed,
      effects: result.plan.effects,
      restart: result.plan.restart,
      rescanFolders: result.plan.rescanFolders,
      restarting,
      bootId: settings.bootId,
    });
  };

  app.get("/v1/settings", (c) => {
    manager(c, "see the server's settings");
    return c.json(settings.describe());
  });

  app.patch("/v1/settings", async (c) => {
    const device = manager(c, "change the server's settings", "change");
    const body = await readBody(c, MAX_SETTINGS_BODY);
    const changes = body["changes"];
    if (typeof changes !== "object" || changes === null || Array.isArray(changes)) {
      throw new ApiError(
        "invalid_request",
        `"changes" must be an object of settings and their new values.`,
      );
    }
    if (Object.keys(changes).length === 0) {
      throw new ApiError("invalid_request", `"changes" names no setting.`);
    }
    const baseVersion = body["baseVersion"] ?? null;
    if (
      baseVersion !== null &&
      (typeof baseVersion !== "number" || !Number.isInteger(baseVersion))
    ) {
      throw new ApiError("invalid_request", `"baseVersion" must be the version that was shown.`);
    }
    const dryRun = booleanOf(body, "dryRun");
    if (settings.isRestarting)
      throw new ApiError("unavailable", "The server is restarting. Try again in a moment.");
    const result = await settings
      .change(device.id, changes as Record<string, unknown>, { dryRun, baseVersion })
      .catch(translate);
    return answerChange(c, result, dryRun);
  });

  app.get("/v1/settings/history", (c) => {
    manager(c, "see the server's settings");
    return c.json({ versions: settings.history() });
  });

  app.post("/v1/settings/history/:version/restore", async (c) => {
    const device = manager(c, "change the server's settings", "change");
    const body = await readBody(c, MAX_KEY_BODY);
    const dryRun = booleanOf(body, "dryRun");
    const version = Number(c.req.param("version"));
    if (!Number.isInteger(version) || version < 1)
      throw new ApiError("not_found", "That version is no longer kept.");
    if (settings.isRestarting)
      throw new ApiError("unavailable", "The server is restarting. Try again in a moment.");
    const result = await settings.restore(device.id, version, dryRun).catch(translate);
    return answerChange(c, result, dryRun);
  });

  app.get("/v1/settings/audit", (c) => {
    manager(c, "see who changed the server's settings");
    const limit = Number(c.req.query("limit") ?? "100");
    if (!Number.isInteger(limit) || limit < 1 || limit > 500) {
      throw new ApiError("invalid_request", `"limit" must be a whole number from 1 to 500.`);
    }
    return c.json({ entries: settings.audit(limit) });
  });

  app.get("/v1/settings/browse", async (c) => {
    manager(c, "look through the server's folders", "browse");
    const listing = await browser.list(c.req.query("path")).catch(translate);
    return c.json(listing);
  });

  app.put("/v1/settings/tmdb", async (c) => {
    const device = manager(c, "set the TMDB key", "tmdb");
    const body = await readBody(c, MAX_KEY_BODY);
    await settings.setTmdbKey(device.id, body["key"]).catch(translate);
    return c.json({ tmdbKey: settings.tmdbStatus() });
  });

  app.delete("/v1/settings/tmdb", (c) => {
    const device = manager(c, "remove the TMDB key", "change");
    try {
      settings.removeTmdbKey(device.id);
    } catch (error) {
      translate(error);
    }
    return c.json({ tmdbKey: settings.tmdbStatus() });
  });

  app.put("/v1/settings/omdb", async (c) => {
    const device = manager(c, "set the OMDb key", "tmdb");
    const body = await readBody(c, MAX_KEY_BODY);
    await settings.setOmdbKey(device.id, body["key"]).catch(translate);
    return c.json({ omdbKey: settings.omdbStatus() });
  });

  app.delete("/v1/settings/omdb", (c) => {
    const device = manager(c, "remove the OMDb key", "change");
    settings.removeOmdbKey(device.id);
    return c.json({ omdbKey: settings.omdbStatus() });
  });

  // ---- The first setup ----

  app.get("/v1/setup", (c) => {
    manager(c, "set the server up");
    return c.json(settings.setup());
  });

  app.post("/v1/setup/steps/:step", async (c) => {
    const device = manager(c, "set the server up", "change");
    const body = await readBody(c, MAX_KEY_BODY);
    try {
      return c.json(settings.setupStep(device.id, c.req.param("step"), body["state"]));
    } catch (error) {
      translate(error);
    }
  });

  app.post("/v1/setup/finish", (c) => {
    const device = manager(c, "set the server up", "change");
    try {
      return c.json(settings.finishSetup(device.id));
    } catch (error) {
      translate(error);
    }
  });
}

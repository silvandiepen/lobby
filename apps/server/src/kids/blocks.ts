// SPDX-License-Identifier: MPL-2.0
import type { Database } from "../db/database.ts";
import { normalizeTitle } from "../library/parse.ts";

interface Chain {
  id: string;
  parent_id: string | null;
  kind: string;
  ident_key: string;
  title: string;
  season_number: number | null;
  episode_number: number | null;
}

interface Trace {
  asset_id: string;
  owner_id: string;
}

/** The item and what it is in, from the inside out. */
function chainOf(db: Database, itemId: string): Chain[] {
  const chain: Chain[] = [];
  for (let next: string | null = itemId; next !== null;) {
    const row: Chain | undefined = db.get<Chain>(
      `select id, parent_id, kind, ident_key, title, season_number, episode_number
       from item where id = ?`,
      [next],
    );
    if (!row) break;
    chain.push(row);
    next = row.parent_id;
  }
  return chain;
}

/**
 * Where an item is in the library, in words that are the same when all of it is made again:
 * its own key can hold the id of its show or its file. `chain` begins with the item.
 */
function placeOf(chain: Chain[]): string | null {
  const [item, ...above] = chain;
  const top = chain.at(-1);
  if (!item || !top) return null;
  const within = above.length === 0 ? "" : /:asset:/.test(top.ident_key) ? "" : top.ident_key;
  switch (item.kind) {
    case "season":
      return `season|${within}|${item.season_number ?? "none"}`;
    case "episode":
      return item.episode_number === null
        ? `episode|${within}|title|${normalizeTitle(item.title)}`
        : `episode|${within}|${item.season_number ?? "none"}|${item.episode_number}`;
    case "extra":
      return `extra|${within}|${normalizeTitle(item.title)}`;
    case "personal":
      return `personal|${normalizeTitle(item.title)}`;
    default:
      // A file nobody recognised is a film of its own; others go by their key.
      return item.ident_key.startsWith("unknown:")
        ? `unknown|${normalizeTitle(item.title)}`
        : `named|${item.ident_key}`;
  }
}

function profilesWithBlocks(db: Database): { id: string; blocked: Set<string> }[] {
  return db
    .all<{ id: string; ids: string }>(
      `select id, json_extract(kids_json, '$.blockedItemIds') as ids from profile
       where kids_json is not null and deleted_at is null
         and json_array_length(kids_json, '$.blockedItemIds') > 0`,
    )
    .map((row) => ({ id: row.id, blocked: new Set(JSON.parse(row.ids) as string[]) }));
}

function block(db: Database, profileId: string, itemId: string): void {
  db.run(
    `update profile set kids_json = json_insert(kids_json, '$.blockedItemIds[#]', ?1)
     where id = ?2 and kids_json is not null
       and not exists (select 1 from json_each(kids_json, '$.blockedItemIds') where value = ?1)`,
    [itemId, profileId],
  );
}

const linkedTo = (db: Database, assetId: string): string[] =>
  db
    .all<{ id: string }>("select item_id as id from item_asset where asset_id = ?", [assetId])
    .map((row) => row.id);

/** Call before a file is forgotten: what is needed to know it again, for everyone it is blocked for. */
export function traceBlocked(db: Database, assetId: string): void {
  const profiles = profilesWithBlocks(db);
  if (profiles.length === 0) return;
  const file = db.get<{ fingerprint: string | null; path: string }>(
    `select fingerprint, source.path || '/' || rel_path as path
     from asset join source on source.id = asset.source_id where asset.id = ?`,
    [assetId],
  );
  if (!file) return;
  for (const itemId of linkedTo(db, assetId)) {
    const chain = chainOf(db, itemId);
    for (const profile of profiles) {
      for (const [index, owner] of chain.entries()) {
        if (!profile.blocked.has(owner.id)) continue;
        const marks: [string, string | null][] = [
          ["fingerprint", file.fingerprint],
          ["path", file.path],
          ["place", placeOf(chain.slice(index))],
        ];
        for (const [kind, value] of marks) {
          if (value === null) continue;
          db.run(
            `insert or ignore into kids_blocked_trace (profile_id, owner_id, asset_id, kind, value)
             values (?, ?, ?, ?, ?)`,
            [profile.id, owner.id, assetId, kind, value],
          );
        }
      }
    }
  }
}

/**
 * Call when a file was linked to its items. What was blocked stays blocked when its file becomes
 * another title, is the same as a blocked file, or is one that was blocked and went away. When
 * it is not sure that it is the same, it is.
 *
 * @param previous the items the file belonged to before, still there
 * @param successors which item takes over from which
 * @param fresh items that were made for this file
 */
export function keepBlocked(
  db: Database,
  assetId: string,
  previous: string[],
  successors: ReadonlyMap<string, string>,
  fresh: ReadonlySet<string>,
): void {
  const linked = linkedTo(db, assetId).filter((id) => !previous.includes(id));
  if (linked.length === 0) return;
  for (const profile of profilesWithBlocks(db)) {
    const isBlocked = (chain: Chain[]): boolean => chain.some((one) => profile.blocked.has(one.id));
    const add = (itemId: string): void => {
      profile.blocked.add(itemId);
      block(db, profile.id, itemId);
    };
    const chains = linked.map((id) => chainOf(db, id));
    const open = (): Chain[][] => chains.filter((chain) => !isBlocked(chain));

    const owners = previous.flatMap((id) =>
      chainOf(db, id)
        .filter((one) => profile.blocked.has(one.id))
        .map((one) => one.id),
    );
    for (const owner of owners) {
      // All of a renamed show, rather than each of its episodes.
      const heir = successors.get(owner);
      if (
        heir !== undefined &&
        fresh.has(heir) &&
        open().some((chain) => chain.some((one) => one.id === heir))
      ) {
        add(heir);
      }
    }
    if (owners.length > 0) for (const [item] of open()) if (item) add(item.id);
    if (previous.length > 0) continue;

    // Not seen before: a copy of a blocked file that is there, or one that was there.
    const file = db.get<{ fingerprint: string | null; path: string }>(
      `select fingerprint, source.path || '/' || rel_path as path
       from asset join source on source.id = asset.source_id where asset.id = ?`,
      [assetId],
    );
    if (!file) continue;
    const twins =
      file.fingerprint === null
        ? []
        : db.all<{ item_id: string }>(
            `select item_id from item_asset join asset on asset.id = item_asset.asset_id
             where asset.fingerprint = ? and asset.id != ?`,
            [file.fingerprint, assetId],
          );
    const same = db.all<Trace>(
      `select distinct asset_id, owner_id from kids_blocked_trace
       where profile_id = ?1 and ((kind = 'fingerprint' and value = ?2) or (kind = 'path' and value = ?3))`,
      [profile.id, file.fingerprint, file.path],
    );
    for (const chain of chains) {
      for (const [index, one] of chain.entries()) {
        const place = placeOf(chain.slice(index));
        const traces =
          place === null
            ? []
            : db.all<Trace>(
                `select asset_id, owner_id from kids_blocked_trace
                 where profile_id = ? and kind = 'place' and value = ?`,
                [profile.id, place],
              );
        if (traces.length === 0) continue;
        if (!isBlocked(chain)) add(one.id);
        // They are about what is blocked now, so they end when a manager unblocks that.
        const owner = chain.slice(index).find(({ id }) => profile.blocked.has(id)) ?? one;
        for (const trace of traces) {
          db.run(
            `update or replace kids_blocked_trace set owner_id = ?
             where profile_id = ? and asset_id = ? and owner_id = ?`,
            [owner.id, profile.id, trace.asset_id, trace.owner_id],
          );
        }
      }
    }
    if (same.length > 0 || twins.some((twin) => isBlocked(chainOf(db, twin.item_id)))) {
      for (const [item] of open()) if (item) add(item.id);
    }
    // It is back: from here on its items say whether it is blocked.
    for (const trace of same) {
      db.run("delete from kids_blocked_trace where profile_id = ? and asset_id = ?", [
        profile.id,
        trace.asset_id,
      ]);
    }
  }
}

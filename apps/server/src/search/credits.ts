// SPDX-License-Identifier: MPL-2.0
import type { Database } from "../db/database.ts";
import type { Credit, TitleDetails } from "../enrich/provider.ts";

/** What search knows of a title beside what the apps see: its people, other names, collection. */
export interface SearchFacts {
  credits: Credit[];
  aliases: string[];
  collection: { id: number; name: string } | null;
}

export function searchFactsOf(details: TitleDetails): SearchFacts {
  return { credits: details.credits, aliases: details.aliases, collection: details.collection };
}

const MAX_ALIASES = 40;

/**
 * Keeps a film's or show's people, other names and collection, and marks it for the search
 * index when they changed. None of this is in what the apps sync, so the library revision stays.
 */
export function saveSearchFacts(
  db: Database,
  itemId: string,
  facts: SearchFacts,
  now: number,
): void {
  db.transaction(() => {
    const before = db.all<{
      person_id: number;
      role: string;
      character: string | null;
      position: number;
    }>(
      "select person_id, role, character, position from item_credit where item_id = ? order by role, position, person_id",
      [itemId],
    );
    const wanted = [...facts.credits].sort((a, b) =>
      a.role < b.role ? -1 : a.role > b.role ? 1 : a.order - b.order || a.personId - b.personId,
    );
    let changed =
      JSON.stringify(before) !==
      JSON.stringify(
        wanted.map((one) => ({
          person_id: one.personId,
          role: one.role,
          character: one.character,
          position: one.order,
        })),
      );
    for (const one of facts.credits) {
      db.run(
        `insert into person (id, name, profile_path, seen_at) values (?, ?, ?, ?)
         on conflict (id) do update set name = excluded.name,
           profile_path = coalesce(excluded.profile_path, person.profile_path), seen_at = excluded.seen_at`,
        [one.personId, one.name, one.profilePath, now],
      );
    }
    if (changed) {
      db.run("delete from item_credit where item_id = ?", [itemId]);
      for (const one of facts.credits) {
        db.run(
          `insert into item_credit (item_id, person_id, role, character, position) values (?, ?, ?, ?, ?)
           on conflict do nothing`,
          [itemId, one.personId, one.role, one.character, one.order],
        );
      }
    }
    const aliases = [...new Set(facts.aliases.map((one) => one.trim()).filter((one) => one !== ""))]
      .slice(0, MAX_ALIASES)
      .sort();
    const known = db
      .all<{ title: string }>("select title from item_alias where item_id = ? order by title", [
        itemId,
      ])
      .map((row) => row.title);
    if (JSON.stringify(known) !== JSON.stringify(aliases)) {
      changed = true;
      db.run("delete from item_alias where item_id = ?", [itemId]);
      for (const title of aliases) {
        db.run("insert into item_alias (item_id, title) values (?, ?)", [itemId, title]);
      }
    }
    const collection = db.get<{ collection_id: number | null; collection_name: string | null }>(
      "select collection_id, collection_name from item where id = ?",
      [itemId],
    );
    if (
      (collection?.collection_id ?? null) !== (facts.collection?.id ?? null) ||
      (collection?.collection_name ?? null) !== (facts.collection?.name ?? null)
    ) {
      changed = true;
    }
    db.run("update item set collection_id = ?, collection_name = ?, credits_at = ? where id = ?", [
      facts.collection?.id ?? null,
      facts.collection?.name ?? null,
      now,
      itemId,
    ]);
    if (changed) {
      db.run("insert into search_dirty (item_id) values (?) on conflict do nothing", [itemId]);
    }
  });
}

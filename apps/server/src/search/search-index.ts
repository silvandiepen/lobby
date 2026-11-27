// SPDX-License-Identifier: MPL-2.0
import type { Database } from "../db/database.ts";
import { readOverrides } from "../library/overrides.ts";
import { editDistance, fold, quoted, typosAllowed, words } from "./normalize.ts";

/**
 * The search index over the library (docs/api.md, Search): SQLite FTS5 tables kept in step with
 * the catalogue. A film, show or video is found by its titles, its people and whom they played,
 * its studios, genres, collection and summary; an episode by its title and summary. Words match
 * from their start and without accents; a word typed wrong or a part of a word is found too.
 */

/** Where a title was found, for the app to say why it is there. */
export type MatchField =
  "title" | "alias" | "person" | "character" | "collection" | "studio" | "genre" | "overview";

export interface TextMatch {
  itemId: string;
  score: number;
  field: MatchField;
  /** What matched: the name, character, studio or other title; null for the title itself. */
  text: string | null;
}

export interface PersonMatch {
  personId: number;
  name: string;
  score: number;
}

/** Between names in one column, so a match can be told apart from its neighbours. */
const SEPARATOR = " · ";
const INDEXED_KINDS = "('movie', 'show', 'personal', 'episode')";
/** How strongly each column counts (bm25 weights, in the table's column order). */
const WEIGHTS = "0, 10, 6, 4, 2, 2, 1, 3, 0.5";
const COLUMNS: { name: string; field: MatchField }[] = [
  { name: "title", field: "title" },
  { name: "aliases", field: "alias" },
  { name: "people", field: "person" },
  { name: "characters", field: "character" },
  { name: "collection", field: "collection" },
  { name: "studios", field: "studio" },
  { name: "genres", field: "genre" },
  { name: "overview", field: "overview" },
];
const MAX_HITS = 500;
/** Titles written at once; a few hundred milliseconds on the Pi. */
const BATCH = 2_000;
/** Fewer than this by words, and parts of words and typos are tried too. */
const FEW = 5;

interface DocRow {
  rowid: number;
  id: string;
  kind: string;
  title: string;
  override_json: string | null;
  overview: string | null;
  collection_name: string | null;
}

interface FoundRow {
  item_id: string;
  rank: number;
  title: string;
  aliases: string;
  people: string;
  characters: string;
  collection: string;
  studios: string;
  genres: string;
  overview: string;
}

export class SearchIndex {
  private readonly db: Database;
  /** Counts what was written, so what is kept in memory knows when it is old. */
  private writes = 0;
  /** The index's words by length, for typos; made again when the index changed. */
  private vocabulary: { stamp: string; byLength: Map<number, string[]> } | null = null;
  private people: { stamp: string; names: { id: number; folded: string; name: string }[] } | null =
    null;

  constructor(db: Database) {
    this.db = db;
  }

  /**
   * Brings the index up to date with the catalogue: only what changed since the last time, at
   * most `most` titles now. Returns whether it is up to date. node:sqlite is synchronous, so a
   * whole library at once (the first time) is left to `syncAll`, which lets requests in between.
   */
  sync(most = BATCH): boolean {
    this.collect();
    return this.batch(most);
  }

  /** All of it, a batch at a time. */
  async syncAll(): Promise<void> {
    while (!this.sync()) await new Promise((next) => setImmediate(next));
  }

  /** Notes what changed since the last time as waiting, so it can be written in batches. */
  private collect(): void {
    const db = this.db;
    const current = db.currentRevision();
    const indexed = Number(db.getMeta("search_revision") ?? "-1");
    const peopleSeen =
      db.get<{ at: number | null }>("select max(seen_at) as at from person")?.at ?? 0;
    const peopleIndexed = Number(db.getMeta("search_people_at") ?? "-1");
    if (indexed === current && peopleSeen <= peopleIndexed) return;
    db.transaction(() => {
      if (indexed < 0) {
        db.run("delete from search_text");
        db.run("delete from search_parts");
      } else if (indexed < current) {
        db.run("delete from search_text where rowid not in (select rowid from item)");
        db.run("delete from search_parts where rowid not in (select rowid from item)");
      }
      if (indexed < current) {
        // What changed, and the episodes of a show that changed: they carry its title.
        db.run(
          `insert into search_dirty (item_id)
           select id from item where revision > ?1 and kind in ${INDEXED_KINDS}
           union select episode.id from item as show
             join item as season on season.parent_id = show.id and season.kind = 'season'
             join item as episode on episode.parent_id = season.id
             where show.revision > ?1 and show.kind = 'show'
           on conflict do nothing`,
          [indexed],
        );
      }
      if (peopleSeen > peopleIndexed) {
        db.run("delete from person_text where rowid in (select id from person where seen_at > ?)", [
          peopleIndexed,
        ]);
        db.run(
          "insert into person_text (rowid, person_id, name) select id, id, name from person where seen_at > ?",
          [peopleIndexed],
        );
        db.setMeta("search_people_at", String(peopleSeen));
      }
      db.setMeta("search_revision", String(current));
    });
    this.writes += 1;
  }

  /** Writes up to `most` waiting titles. True when none are left. */
  private batch(most: number): boolean {
    const db = this.db;
    return db.transaction(() => {
      const waiting = db.all<{ item_id: string }>(
        `select item_id from search_dirty limit ${String(most)}`,
      );
      if (waiting.length === 0) return true;
      const ids = JSON.stringify(waiting.map((one) => one.item_id));
      const rows = db.all<DocRow>(
        `select rowid, id, kind, title, override_json, overview, collection_name from item
         where id in (select value from json_each(?)) and kind in ${INDEXED_KINDS}`,
        [ids],
      );
      for (const row of rows) this.write(row);
      db.run("delete from search_dirty where item_id in (select value from json_each(?))", [ids]);
      this.writes += 1;
      return waiting.length < most;
    });
  }

  private write(row: DocRow): void {
    const db = this.db;
    const overrides = readOverrides(row.override_json);
    const title = overrides.title ?? row.title;
    const overview = overrides.overview === undefined ? row.overview : overrides.overview;
    let aliases: string[];
    let people: string[] = [];
    let characters: string[] = [];
    let studios: string[] = [];
    let genres: string[] = [];
    if (row.kind === "episode") {
      // An episode is also found by its show's title.
      const show = db.get<{ title: string; override_json: string | null }>(
        `select show.title, show.override_json from item as episode
         join item as season on season.id = episode.parent_id
         join item as show on show.id = season.parent_id where episode.id = ?`,
        [row.id],
      );
      aliases = show ? [readOverrides(show.override_json).title ?? show.title] : [];
    } else {
      aliases = db
        .all<{ title: string }>("select title from item_alias where item_id = ?", [row.id])
        .map((one) => one.title)
        .filter((one) => fold(one) !== fold(title));
      if (overrides.title !== undefined && fold(row.title) !== fold(title))
        aliases.unshift(row.title);
      const credits = db.all<{ name: string; character: string | null }>(
        `select person.name, item_credit.character from item_credit
         join person on person.id = item_credit.person_id
         where item_credit.item_id = ? order by item_credit.role != 'cast', item_credit.position`,
        [row.id],
      );
      people = [...new Set(credits.map((one) => one.name))];
      characters = credits.flatMap((one) => (one.character === null ? [] : [one.character]));
      studios = db
        .all<{ name: string }>(
          `select studio.name from item_studio join studio on studio.id = item_studio.studio_id
           where item_studio.item_id = ? order by item_studio.position`,
          [row.id],
        )
        .map((one) => one.name);
      genres =
        overrides.genres ??
        db
          .all<{ name: string }>(
            "select genre.name from item_genre join genre on genre.id = item_genre.genre_id where item_id = ?",
            [row.id],
          )
          .map((one) => one.name);
    }
    db.run("delete from search_text where rowid = ?", [row.rowid]);
    db.run("delete from search_parts where rowid = ?", [row.rowid]);
    db.run(
      `insert into search_text (rowid, item_id, title, aliases, people, characters, studios, genres,
         collection, overview) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        row.rowid,
        row.id,
        title,
        aliases.join(SEPARATOR),
        people.join(SEPARATOR),
        characters.join(SEPARATOR),
        studios.join(SEPARATOR),
        genres.join(SEPARATOR),
        row.collection_name ?? "",
        overview ?? "",
      ],
    );
    db.run("insert into search_parts (rowid, item_id, text) values (?, ?, ?)", [
      row.rowid,
      row.id,
      [title, ...(row.kind === "episode" ? [] : aliases)].join(SEPARATOR),
    ]);
  }

  /**
   * Films, shows, videos and episodes that have every word, best first. Each word matches from
   * its start; with few results, parts of words and words with a letter or two wrong count too.
   */
  matchTitles(text: string): TextMatch[] {
    const typed = words(text);
    if (typed.length === 0) return [];
    const found = new Map<string, TextMatch>();
    const add = (rows: FoundRow[], penalty: number): void => {
      for (const row of rows) {
        if (found.has(row.item_id)) continue;
        found.set(row.item_id, this.explain(row, typed, -row.rank * penalty));
      }
    };
    add(this.ftsRows(typed.map((word) => `${quoted(word)}*`).join(" AND ")), 1);
    if (found.size < FEW) {
      // Typos: each word may be any known word close enough to it.
      const fuzzy = typed.map((word) => {
        const close = this.closeWords(word);
        return close.length === 0
          ? `${quoted(word)}*`
          : `(${[`${quoted(word)}*`, ...close.map(quoted)].join(" OR ")})`;
      });
      add(this.ftsRows(fuzzy.join(" AND ")), 0.5);
    }
    if (found.size < FEW && typed.some((word) => word.length >= 3)) {
      // Parts of words: "atrix" in "The Matrix". Titles and other names only.
      const parts = typed
        .filter((word) => word.length >= 3)
        .map(quoted)
        .join(" AND ");
      const ids = this.db.all<{ item_id: string; rank: number }>(
        `select item_id, rank from search_parts where search_parts match ? order by rank limit ${String(MAX_HITS)}`,
        [parts],
      );
      for (const one of ids) {
        if (found.has(one.item_id)) continue;
        const row = this.db.get<FoundRow>(
          `select item_id, 0 as rank, title, aliases, people, characters, collection, studios, genres, overview
           from search_text where rowid = (select rowid from item where id = ?)`,
          [one.item_id],
        );
        if (row) found.set(one.item_id, { ...this.explain(row, typed, 0), score: -one.rank * 0.3 });
      }
    }
    return [...found.values()].sort((a, b) => b.score - a.score);
  }

  private ftsRows(match: string): FoundRow[] {
    return this.db.all<FoundRow>(
      `select item_id, bm25(search_text, ${WEIGHTS}) as rank, title, aliases, people, characters,
         collection, studios, genres, overview
       from search_text where search_text match ? order by rank limit ${String(MAX_HITS)}`,
      [match],
    );
  }

  /** Says where a row was found and how well: a title that is what was typed comes first. */
  private explain(row: FoundRow, typed: string[], base: number): TextMatch {
    const phrase = typed.join(" ");
    const title = fold(row.title);
    let score = base;
    if (title === phrase) score += 100;
    else if (title.startsWith(phrase)) score += 30;
    else if (` ${title}`.includes(` ${phrase}`)) score += 15;
    const has = (value: string): boolean => {
      const folded = ` ${fold(value)}`;
      return typed.every((word) => folded.includes(` ${word}`));
    };
    const some = (value: string): boolean => {
      const folded = ` ${fold(value)}`;
      return typed.some((word) => folded.includes(` ${word}`));
    };
    for (const column of COLUMNS) {
      const value = row[column.name as keyof FoundRow] as string;
      if (value === "") continue;
      const names = value.split(SEPARATOR);
      const whole = names.find(has);
      if (whole !== undefined || (column.field !== "title" && names.some(some) && has(value))) {
        const which = whole ?? names.find(some) ?? null;
        if (column.field === "person" && whole !== undefined) score += 10;
        return {
          itemId: row.item_id,
          score,
          field: column.field,
          text: column.field === "title" || column.field === "overview" ? null : which,
        };
      }
    }
    return { itemId: row.item_id, score, field: "title", text: null };
  }

  /** Known words that differ from `word` in a letter or two; none for a short word. */
  private closeWords(word: string): string[] {
    const most = typosAllowed(word);
    if (most === 0) return [];
    const stamp = String(this.writes);
    if (this.vocabulary?.stamp !== stamp) {
      const byLength = new Map<number, string[]>();
      for (const { term } of this.db.all<{ term: string }>("select term from search_words")) {
        const list = byLength.get(term.length) ?? [];
        list.push(term);
        byLength.set(term.length, list);
      }
      this.vocabulary = { stamp, byLength };
    }
    const close: string[] = [];
    for (let length = word.length - most; length <= word.length + most; length += 1) {
      for (const term of this.vocabulary.byLength.get(length) ?? []) {
        if (term !== word && editDistance(word, term, most) <= most) close.push(term);
        if (close.length >= 20) return close;
      }
    }
    return close;
  }

  /** People in the library whose name has every word, best first; a name typed wrong too. */
  matchPeople(text: string, limit = 50): PersonMatch[] {
    const typed = words(text);
    if (typed.length === 0) return [];
    const rows = this.db.all<{ id: number; name: string; rank: number }>(
      `select person_id as id, name, rank from person_text where person_text match ?
       order by rank limit ${String(limit)}`,
      [typed.map((word) => `${quoted(word)}*`).join(" AND ")],
    );
    const phrase = typed.join(" ");
    const found = rows.map((row) => ({
      personId: row.id,
      name: row.name,
      score: -row.rank + (fold(row.name) === phrase ? 100 : 0),
    }));
    if (found.length === 0) {
      const most = typosAllowed(phrase.replace(/ /g, ""));
      if (most > 0) {
        for (const one of this.peopleNames()) {
          const distance = editDistance(phrase, one.folded, most);
          if (distance <= most) found.push({ personId: one.id, name: one.name, score: -distance });
        }
      }
    }
    return found.sort((a, b) => b.score - a.score).slice(0, limit);
  }

  /**
   * The people a name stands for: whoever has exactly that name, else whoever matches it best.
   */
  resolvePerson(name: string): number[] {
    const matches = this.matchPeople(name, 20);
    const exact = matches.filter((one) => fold(one.name) === fold(name));
    if (exact.length > 0) return exact.map((one) => one.personId);
    const best = matches[0];
    return best ? [best.personId] : [];
  }

  private peopleNames(): { id: number; folded: string; name: string }[] {
    const stamp = String(this.writes);
    if (this.people?.stamp !== stamp) {
      this.people = {
        stamp,
        names: this.db
          .all<{ id: number; name: string }>("select id, name from person")
          .map((one) => ({ ...one, folded: fold(one.name) })),
      };
    }
    return this.people.names;
  }
}

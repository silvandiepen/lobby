// SPDX-License-Identifier: MPL-2.0
// Shows what the studio suggestions do, against a TMDB stand-in with invented titles and
// studios. Nothing real is asked or read. Run: node apps/server/test/studios-stub.ts
import { randomUUID } from "node:crypto";
import { join } from "node:path";
import { Database } from "../src/db/database.ts";
import { Enricher } from "../src/enrich/index.ts";
import { Categories } from "../src/library/categories.ts";
import { Catalogue } from "../src/library/catalogue.ts";
import { ItemReader } from "../src/library/items.ts";
import { parseMediaPath } from "../src/library/parse.ts";
import { Studios } from "../src/library/studios.ts";
import { makeTempDir, removeDir } from "./support/media.ts";
import { LocalTmdb, movieAnswer } from "./support/tmdb.ts";

const dir = makeTempDir("lobby-studios-stub-");
const tmdb = await LocalTmdb.start(Buffer.alloc(0));
const db = new Database(join(dir, "lobby.db"));
try {
  const catalogue = new Catalogue(db);
  db.run(
    "insert into source (id, path, name, hint, created_at) values ('m', '/m', 'Films', 'movies', 0)",
  );
  const glow = {
    id: 7,
    name: "Glow Animation Studios",
    logo_path: "/glowlogo07.png",
    origin_country: "US",
  };
  const glowPictures = { id: 9, name: "Glow Pictures", logo_path: null, origin_country: "US" };
  const reef = { id: 21, name: "Reef Films", logo_path: "/reeflogo21.png", origin_country: "FR" };
  const films: [string, number, object[]][] = [];
  for (let n = 1; n <= 6; n += 1) films.push([`Lamp ${n}`, 2000 + n, [glow]]);
  for (let n = 1; n <= 3; n += 1) films.push([`Kite ${n}`, 2010 + n, [glowPictures, reef]]);
  for (let n = 1; n <= 4; n += 1) films.push([`Tide ${n}`, 1990 + n, [reef]]);
  const hits: Record<string, unknown>[] = [];
  films.forEach(([title, year, companies], index) => {
    const id = 100 + index;
    const date = `${year}-05-01`;
    tmdb.answers.set(`/3/movie/${id}`, {
      body: movieAnswer(id, title, date, { production_companies: companies }),
    });
    hits.push({
      id,
      title,
      original_title: title,
      release_date: date,
      vote_count: 50,
      popularity: 5,
    });
    const rel = `${title} (${year}).mkv`;
    const asset = randomUUID();
    const parsed = parseMediaPath(rel, "movies");
    db.run(
      `insert into asset (id, source_id, rel_path, size, mtime_ms, revision, state, duration_ms, parsed_json,
         first_seen_at, updated_at) values (?, 'm', ?, 1, 1, '1', 'probed', 5400000, ?, 0, 0)`,
      [asset, rel, JSON.stringify(parsed)],
    );
    catalogue.linkAsset(asset, parsed, "movies");
  });
  tmdb.search("movie", hits);
  const enricher = new Enricher({
    db,
    catalogue,
    key: "0123456789abcdef0123456789abcdef",
    language: "en-US",
    artworkDir: join(dir, "artwork"),
    baseUrl: `${tmdb.origin}/3`,
    imageBaseUrl: `${tmdb.origin}/t/p`,
    limits: { minIntervalMs: 0 },
  });
  console.log("Enriched:", await enricher.run());
  await enricher.stop();

  const studios = new Studios(db);
  for (const min of [8, 4]) {
    console.log(`\nSuggestions with at least ${min} titles:`);
    console.log(JSON.stringify(studios.suggestions(min), null, 2));
  }
  // What accepting the first one does: a category whose rule takes the titles in.
  const [first] = studios.suggestions(4);
  const categories = new Categories(db);
  categories.seed([]);
  const main = categories.view().groups[0]?.id ?? "";
  categories.change(categories.revision, () => {
    categories.createCategory(main, {
      name: first?.name ?? "",
      rule: { studioIds: first?.studios.map((one) => one.id) ?? [] },
    });
  });
  const reader = new ItemReader(db);
  const items = reader.page(null, 100).items.filter((one) => one.ruleCategoryIds.length > 0);
  console.log(`\nIn "${first?.name ?? ""}" by its rule:`, items.map((one) => one.title).join(", "));
  console.log(
    "Left to suggest:",
    studios.suggestions(4).map((one) => one.name),
  );
} finally {
  db.close();
  await tmdb.stop();
  removeDir(dir);
}

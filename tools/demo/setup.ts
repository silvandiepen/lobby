// SPDX-License-Identifier: MPL-2.0
/**
 * Sets the demo server up, through its own API at home (127.0.0.1), as a manager would in the app.
 * Run once after the first start; running it again changes only what differs.
 *
 *   node tools/demo/setup.ts --server http://127.0.0.1:8674 --state ~/lobby-demo/state
 *
 * - Claims the server for one admin device, "Demo doorman" (platform cli). Its credential is
 *   kept in <state>/doorman.token (0600) and is what doorman.ts and invites.ts use.
 * - Titles, years, summaries and genres from films.json (matching is off: no TMDB key), and the
 *   posters library.ts fetched.
 * - Viewers: "Alex", "Sam", and "Mia", a kids viewer who sees only the Kids part of the library.
 * - The four-digit code for grown-ups (Apple TV leaves kids mode with it): --kids-code, 2468.
 * - The entrance from outside on.
 */
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { Api, FILMS, option, readSecret, stateDir, writeSecret } from "./lib.ts";

interface Item {
  id: string;
  kind: string;
  title: string;
  year: number | null;
}
interface EditView {
  revision: number;
}
interface Profile {
  id: string;
  name: string;
  kids: unknown;
}
interface Categories {
  groups: { id: string; name: string | null }[];
}

const api = new Api(option("server", "http://127.0.0.1:8674"), null);
const state = stateDir();
const tokenFile = join(state, "doorman.token");
const kidsCode = option("kids-code", "2468");

api.token = readSecret(tokenFile);
if (!api.token) {
  const claimed = await api.call<{ token: string; setup: { needed: boolean } }>(
    "POST",
    "/v1/pairing/claim",
    { deviceName: "Demo doorman", platform: "cli" },
  );
  writeSecret(tokenFile, claimed.token);
  api.token = claimed.token;
  console.log("Claimed the server for the doorman.");
}

// A server that started with folders in its config needs no first setup; say so if it does.
const setup = await api.call<{ needed: boolean }>("GET", "/v1/setup");
if (setup.needed) {
  await api.call("POST", "/v1/setup/steps/tmdb", { state: "skipped" });
  await api.call("POST", "/v1/setup/finish");
}

// The catalogue, all of it.
const items: Item[] = [];
let cursor: string | null = null;
for (;;) {
  const page: { items: Item[]; cursor: string; more: boolean } = await api.call(
    "GET",
    `/v1/library${cursor ? `?cursor=${encodeURIComponent(cursor)}` : ""}`,
  );
  items.push(...page.items);
  cursor = page.cursor;
  if (!page.more) break;
}

const plain = (text: string) => text.toLowerCase().replace(/[^a-z0-9]/g, "");
for (const film of FILMS) {
  const item = items.find(
    (one) => one.kind === "movie" && plain(one.title).startsWith(plain(film.title)),
  );
  if (!item) {
    console.log(`Not in the catalogue yet: ${film.title}. Run this again after the scan.`);
    continue;
  }
  let view = await api.call<EditView>("GET", `/v1/items/${item.id}/edit`);
  view = await api.call<EditView>("PATCH", `/v1/items/${item.id}`, {
    revision: view.revision,
    set: { title: film.title, year: film.year, overview: film.overview, genres: film.genres },
  });
  const poster = readFileSync(join(state, "posters", `${film.title}.jpg`));
  await api.call(
    "POST",
    `/v1/items/${item.id}/artwork/upload?kind=poster&revision=${view.revision}`,
    undefined,
    poster,
  );
  console.log(`${film.title}: details and poster.`);
}

// Viewers.
const categories = await api.call<Categories>("GET", "/v1/categories");
const kidsGroup = categories.groups.find((group) => group.name === "Kids");
if (!kidsGroup) throw new Error("There is no Kids part of the library: check the config's roots.");
const { profiles } = await api.call<{ profiles: Profile[] }>("GET", "/v1/profiles");
const kids = {
  allowedGroupIds: [kidsGroup.id],
  allowedCategoryIds: [],
  allowedItemIds: [],
  blockedItemIds: [],
};
const wanted = [
  { name: "Alex", color: "blue", avatar: null, kids: null },
  { name: "Sam", color: "green", avatar: null, kids: null },
  { name: "Mia", color: "pink", avatar: null, kids },
];
for (const viewer of wanted) {
  const there = profiles.find((one) => one.name === viewer.name);
  if (there) await api.call("PATCH", `/v1/profiles/${there.id}`, viewer);
  else await api.call("POST", "/v1/profiles", viewer);
}
console.log("Viewers: Alex, Sam, and Mia (kids: only the Kids part).");

await api.call("PUT", "/v1/kids/code", { code: kidsCode });
console.log(`The code for grown-ups is ${kidsCode}.`);

await api.call("PATCH", "/v1/outside", { enabled: true });
const outside = await api.call<{ direct: { running: boolean; introducer: boolean } | null }>(
  "GET",
  "/v1/outside",
);
console.log(
  `Outside: on. Direct connection: ${outside.direct?.running ? "running" : "not running"}, ` +
    `${outside.direct?.introducer ? "signed in at the introducer" : "NOT signed in at the introducer (is the box id in its BOXES?)"}.`,
);

// SPDX-License-Identifier: MPL-2.0
import { normalizeTitle, sortTitle } from "../library/parse.ts";
import type {
  EpisodeDetails,
  MetadataProvider,
  SearchHit,
  TitleDetails,
  TitleType,
} from "./provider.ts";

/** What the files say about a film or show. */
export interface WantedTitle {
  type: TitleType;
  title: string;
  year: number | null;
  /** Ids written in file or folder names. */
  tmdbIds: number[];
  imdbIds: string[];
  /** Running times of a film's files, in minutes. */
  runtimes: number[];
  /** For a show: its episodes, as far as the files number them. */
  episodes: { season: number | null; episode: number | null; title: string | null }[];
}

export interface Candidate {
  type: TitleType | "episode";
  id: number;
  title: string;
  originalTitle: string | null;
  year: number | null;
  overview: string | null;
  posterPath: string | null;
  season?: number;
  episode?: number;
  evidence: string[];
}

export type Decision<T> =
  { accepted: T } | { accepted: null; reason: string; candidates: Candidate[] };

const MAX_CANDIDATES = 8;
const MAX_EXAMINED = 8;
const MAX_SEASONS = 30;
/** Fewer numbered episodes than this fit too many shows to prove anything. */
const MIN_NUMBERED = 5;
/** Titles with fewer ratings than this are obscure enough to distrust. */
const MIN_VOTES = 20;

type Agreement = "agrees" | "unknown" | "conflicts";

export function sameTitle(a: string, b: string): boolean {
  // Sort titles leave out a leading article, which people often do as well.
  const key = sortTitle(a);
  // A title in another script normalises to nothing; that is not a match with everything.
  return key !== "" ? key === sortTitle(b) : a.trim() !== "" && a.trim() === b.trim();
}

function titleMatches(hit: SearchHit, title: string): boolean {
  return sameTitle(hit.title, title) || sameTitle(hit.originalTitle, title);
}

function runtimeAgreement(details: TitleDetails, files: number[]): Agreement {
  const runtime = details.runtimeMinutes;
  if (runtime === null || files.length === 0) return "unknown";
  if (files.some((file) => Math.abs(file - runtime) <= Math.max(8, runtime * 0.12))) {
    return "agrees";
  }
  return files.every((file) => file < runtime * 0.5 || file > runtime * 2)
    ? "conflicts"
    : "unknown";
}

/** Only then is one of several films of the same name ruled out. */
function runsClearlyDifferent(details: TitleDetails, files: number[]): boolean {
  const runtime = details.runtimeMinutes;
  return (
    runtime !== null &&
    files.length > 0 &&
    files.every((file) => Math.abs(file - runtime) > Math.max(10, file * 0.25))
  );
}

/** Whether the show has every numbered episode the files are. */
function episodesFit(details: TitleDetails, wanted: WantedTitle): boolean {
  return wanted.episodes.every(({ season, episode }) => {
    if (season === null || episode === null || season === 0) return true;
    return details.seasons.some((one) => one.number === season && one.episodes >= episode);
  });
}

/** How many of the files' own episode titles the show has, in any season: orders differ. */
async function sharedTitles(
  provider: MetadataProvider,
  details: TitleDetails,
  titles: Set<string>,
): Promise<number> {
  const found = new Set<string>();
  for (const { number } of details.seasons.slice(0, MAX_SEASONS)) {
    for (const episode of (await provider.season(details.id, number))?.episodes ?? []) {
      // Two stories in one broadcast are often one episode on TMDB: "First / Second".
      for (const part of [episode.title, ...episode.title.split(/\s*[/;]\s*/)]) {
        const key = sortTitle(part);
        if (titles.has(key)) found.add(key);
      }
    }
  }
  return found.size;
}

function episodeTitles(wanted: WantedTitle): Set<string> {
  const titles = new Set<string>();
  for (const { episode, title } of wanted.episodes) {
    if (title === null || (episode !== null && isPlaceholder(title, episode))) continue;
    const key = sortTitle(title);
    if (key !== "") titles.add(key);
  }
  return titles;
}

/** Compares the files' episode titles with the show's own. */
async function episodeAgreement(
  provider: MetadataProvider,
  details: TitleDetails,
  wanted: WantedTitle,
): Promise<Agreement> {
  const titles = episodeTitles(wanted);
  if (titles.size === 0) return "unknown";
  const shared = await sharedTitles(provider, details, titles);
  if (shared >= 2 || (titles.size === 1 && shared === 1)) return "agrees";
  return shared === 0 && titles.size >= 3 ? "conflicts" : "unknown";
}

/** The one show the files' episodes point to, out of several of the same name. */
async function showByEpisodes(
  provider: MetadataProvider,
  shows: TitleDetails[],
  wanted: WantedTitle,
): Promise<TitleDetails | null> {
  const titles = episodeTitles(wanted);
  if (titles.size > 0) {
    const scored: { details: TitleDetails; shared: number }[] = [];
    for (const details of shows) {
      scored.push({ details, shared: await sharedTitles(provider, details, titles) });
    }
    scored.sort((a, b) => b.shared - a.shared);
    const [best, second] = scored;
    const enough = best && best.shared >= Math.min(2, titles.size);
    if (enough && (second?.shared ?? 0) * 5 <= best.shared) return best.details;
  }
  // Without titles: the only one that has all these episodes, if there are enough to tell.
  const numbered = wanted.episodes.filter((one) => one.season !== null && one.episode !== null);
  if (numbered.length < MIN_NUMBERED || titles.size >= 3) return null;
  const all = shows.filter((one) => episodesFit(one, wanted));
  // "Rooster" is not "The Rooster" when both exist.
  const literal = all.filter((one) => normalizeTitle(one.title) === normalizeTitle(wanted.title));
  const fitting = literal.length > 0 ? literal : all;
  const [only] = fitting;
  return fitting.length === 1 && only && only.votes >= MIN_VOTES ? only : null;
}

/** "Episode 4" and its like say nothing the number does not. */
export function isPlaceholder(title: string, episode: number): boolean {
  const match = /^(?:episode|episodio|aflevering|folge|episodi)\s+(\d+)$/.exec(
    normalizeTitle(title),
  );
  return match?.[1] !== undefined && Number(match[1]) === episode;
}

/**
 * Finds the film or show these files are. Accepts only a strong match with nothing
 * else like it; anything less comes back as candidates for a manager.
 */
export async function matchTitle(
  provider: MetadataProvider,
  wanted: WantedTitle,
): Promise<Decision<TitleDetails>> {
  const explicit = await matchExplicit(provider, wanted);
  if (explicit) return explicit;

  let hits: SearchHit[] = [];
  const searched = { complete: true };
  const searchMore = async (year: number | null): Promise<void> => {
    const result = await provider.search(wanted.type, wanted.title, year);
    searched.complete = result.complete;
    hits = [...hits, ...result.hits.filter((hit) => !hits.some((known) => known.id === hit.id))];
  };
  const exact = (): SearchHit[] => hits.filter((hit) => titleMatches(hit, wanted.title));
  const distance = (hit: SearchHit): number =>
    wanted.year === null || hit.year === null ? 99 : Math.abs(hit.year - wanted.year);

  let pool: SearchHit[];
  let sameYear = false;
  if (wanted.year === null) {
    await searchMore(null);
    pool = exact();
  } else {
    await searchMore(wanted.year);
    pool = exact().filter((hit) => distance(hit) === 0);
    sameYear = pool.length > 0;
    if (!sameYear) {
      await searchMore(null);
      // A search by year is an index lookup; the wider one can still surface the year itself.
      pool = exact().filter((hit) => distance(hit) === 0);
      sameYear = pool.length > 0;
    }
    if (!sameYear) pool = exact().filter((hit) => distance(hit) === 1);
    // A show's folder often carries the year of one season.
    if (pool.length === 0 && wanted.type === "tv") pool = exact();
  }

  const known = new Map<number, TitleDetails>();
  const detailsOf = async (hit: SearchHit): Promise<TitleDetails | null> => {
    const details = known.get(hit.id) ?? (await provider.details(hit.type, hit.id));
    if (details) known.set(hit.id, details);
    return details;
  };

  if (pool.length === 0) {
    const likely = hits
      .filter((hit) => wanted.year === null || distance(hit) <= 1)
      .slice(0, MAX_EXAMINED);
    for (const hit of likely) {
      const details = await detailsOf(hit);
      if (details?.aliases.some((alias) => sameTitle(alias, wanted.title))) pool.push(hit);
    }
    sameYear = pool.some((hit) => distance(hit) === 0);
    if (sameYear) pool = pool.filter((hit) => distance(hit) === 0);
  }

  if (sameYear && pool.length > 1) {
    // "Trolls" is not "The Trolls" when both exist.
    const literal = pool.filter(
      (hit) => normalizeTitle(hit.title) === normalizeTitle(wanted.title),
    );
    if (literal.length > 0) pool = literal;
  }

  const review = (reason: string): Decision<TitleDetails> => ({
    accepted: null,
    reason,
    candidates: [...pool, ...hits.filter((hit) => !pool.includes(hit))]
      .slice(0, MAX_CANDIDATES)
      .map((hit) => toCandidate(hit, wanted, known.get(hit.id))),
  });

  if (hits.length === 0) return review("TMDB has nothing by this title.");
  if (pool.length === 0) return review("Nothing on TMDB has both this title and year.");
  if (pool.length > MAX_EXAMINED) return review("Many titles on TMDB have this name.");

  if (pool.length > 1) {
    if (wanted.type === "movie") {
      // Short films often share a name and year with the film everyone means.
      const examined = await Promise.all(pool.map(detailsOf));
      const fitting = examined.filter(
        (one) => one === null || !runsClearlyDifferent(one, wanted.runtimes),
      );
      const famous = fitting.filter((one) => one !== null && one.votes >= MIN_VOTES * 5);
      const [favourite] = famous;
      if (
        sameYear &&
        famous.length === 1 &&
        favourite &&
        runtimeAgreement(favourite, wanted.runtimes) === "agrees" &&
        fitting.every(
          (one) => one === favourite || (one !== null && one.votes * 20 <= favourite.votes),
        )
      ) {
        return { accepted: favourite };
      }
      const [only] = fitting;
      return sameYear &&
        fitting.length === 1 &&
        only &&
        runtimeAgreement(only, wanted.runtimes) === "agrees"
        ? { accepted: only }
        : review("Several films on TMDB fit this title.");
    }
    const shows: TitleDetails[] = [];
    for (const hit of pool) {
      const details = await detailsOf(hit);
      if (details) shows.push(details);
    }
    const only = await showByEpisodes(provider, shows, wanted);
    return only ? { accepted: only } : review("Several shows on TMDB fit this title.");
  }

  const [hit] = pool;
  const details = hit ? await detailsOf(hit) : null;
  if (!details) return review("TMDB no longer has the title it found.");
  if (
    wanted.type === "movie" &&
    wanted.imdbIds.length > 0 &&
    details.imdbId !== null &&
    !wanted.imdbIds.includes(details.imdbId)
  ) {
    return review("The IMDb id in the file name belongs to something else.");
  }
  const agreement =
    wanted.type === "movie"
      ? runtimeAgreement(details, wanted.runtimes)
      : await episodeAgreement(provider, details, wanted);
  if (agreement === "conflicts") {
    return review(
      wanted.type === "movie"
        ? "The title fits but the running time does not."
        : "The title fits but none of the episode titles do.",
    );
  }
  if (sameYear) return { accepted: details };
  if (wanted.type === "movie") {
    return agreement === "agrees" && (searched.complete || wanted.year !== null)
      ? { accepted: details }
      : review("The title fits; the year or running time does not confirm it.");
  }
  if (agreement === "agrees") return { accepted: details };
  const numbered = wanted.episodes.filter((one) => one.season !== null && one.episode !== null);
  const wellKnown = numbered.length >= MIN_NUMBERED && details.votes >= MIN_VOTES;
  return wanted.year === null && (searched.complete || wellKnown) && episodesFit(details, wanted)
    ? { accepted: details }
    : review("The title fits; the year and episodes do not confirm it.");
}

async function matchExplicit(
  provider: MetadataProvider,
  wanted: WantedTitle,
): Promise<Decision<TitleDetails> | null> {
  const conflict = async (ids: number[], reason: string): Promise<Decision<TitleDetails>> => {
    const candidates: Candidate[] = [];
    for (const id of ids.slice(0, MAX_EXAMINED)) {
      const details = await provider.details(wanted.type, id);
      if (details) candidates.push(toCandidate(details, wanted, details));
    }
    return { accepted: null, reason, candidates };
  };

  const fromImdb: { type: TitleType; id: number }[] = [];
  for (const imdbId of wanted.imdbIds.slice(0, 3)) {
    for (const found of await provider.findByImdb(imdbId)) {
      if (!fromImdb.some((one) => one.id === found.id && one.type === found.type)) {
        fromImdb.push(found);
      }
    }
  }
  if (wanted.tmdbIds.length === 0 && fromImdb.length === 0) return null;
  if (fromImdb.some((one) => one.type !== wanted.type)) {
    return conflict(wanted.tmdbIds, "The IMDb id in the file name is another kind of title.");
  }
  const ids = [...new Set([...wanted.tmdbIds, ...fromImdb.map((one) => one.id)])];
  const [only] = ids;
  if (ids.length !== 1 || only === undefined) {
    return conflict(ids, "The ids in the file names contradict each other.");
  }
  const details = await provider.details(wanted.type, only);
  return details
    ? { accepted: details }
    : { accepted: null, reason: "TMDB does not know the id in the file name.", candidates: [] };
}

function toCandidate(
  hit: Pick<
    SearchHit,
    "type" | "id" | "title" | "originalTitle" | "year" | "overview" | "posterPath"
  >,
  wanted: WantedTitle,
  details: TitleDetails | undefined,
): Candidate {
  const evidence: string[] = [];
  if (sameTitle(hit.title, wanted.title) || sameTitle(hit.originalTitle, wanted.title)) {
    evidence.push("Same title.");
  } else if (details?.aliases.some((alias) => sameTitle(alias, wanted.title))) {
    evidence.push("Also known by this title.");
  } else {
    evidence.push("Similar title.");
  }
  if (wanted.year !== null && hit.year !== null) {
    evidence.push(
      hit.year === wanted.year ? "Same year." : `From ${hit.year}; the files say ${wanted.year}.`,
    );
  }
  const [file] = wanted.runtimes;
  if (details && details.runtimeMinutes !== null && file !== undefined) {
    evidence.push(`Runs ${details.runtimeMinutes} min; the file runs ${Math.round(file)} min.`);
  }
  return {
    type: hit.type,
    id: hit.id,
    title: hit.title,
    originalTitle: hit.originalTitle,
    year: hit.year,
    overview: hit.overview,
    posterPath: hit.posterPath,
    evidence,
  };
}

export interface WantedEpisode {
  season: number | null;
  episode: number | null;
  /** The title in the file name. Null for a file that holds several episodes. */
  title: string | null;
  airDate: string | null;
  runtimeMinutes: number | null;
}

/** Finds an episode by its number in its season, checked against title and running time. */
export function matchNumbered(
  wanted: WantedEpisode & { episode: number },
  episodes: EpisodeDetails[],
): Decision<EpisodeDetails> {
  const found = episodes.find((one) => one.episode === wanted.episode);
  const sameNames = episodes.filter(
    (one) => wanted.title !== null && sameTitle(one.title, wanted.title),
  );
  if (!found) {
    return {
      accepted: null,
      reason: "TMDB has no episode with this number.",
      candidates: sameNames.map((one) => episodeCandidate(one, "Same title.")),
    };
  }
  if (wanted.title === null || isPlaceholder(wanted.title, wanted.episode)) {
    return { accepted: found };
  }
  const a = normalizeTitle(found.title);
  const b = normalizeTitle(wanted.title);
  if (a === "" || b === "" || a.includes(b) || b.includes(a)) return { accepted: found };
  const candidates = [
    episodeCandidate(found, "Same number."),
    ...sameNames.map((one) => episodeCandidate(one, "Same title.")),
  ];
  if (sameNames.length > 0) {
    return {
      accepted: null,
      reason: "The number and the title point to different episodes.",
      candidates,
    };
  }
  const ratio =
    found.runtimeMinutes !== null && wanted.runtimeMinutes !== null
      ? wanted.runtimeMinutes / found.runtimeMinutes
      : 1;
  return ratio < 0.5 || ratio > 2
    ? { accepted: null, reason: "Neither the title nor the running time fits.", candidates }
    : { accepted: found };
}

/** Finds an episode whose season or number the file name does not give. */
export function matchByTitle(
  wanted: WantedEpisode,
  episodes: EpisodeDetails[],
): Decision<EpisodeDetails> {
  const title = wanted.title;
  let named =
    title !== null && normalizeTitle(title).length >= 3 && !/^episode \d+$/i.test(title)
      ? episodes.filter((one) => sameTitle(one.title, title))
      : [];
  const dated = episodes.filter((one) => wanted.airDate !== null && one.airDate === wanted.airDate);
  if (named.length > 1) {
    const both = named.filter((one) => dated.includes(one));
    if (both.length === 1) named = both;
  }
  const [only] = named;
  if (named.length === 1 && only) return { accepted: only };
  const numbered = episodes.filter(
    (one) => one.season !== 0 && wanted.episode !== null && one.episode === wanted.episode,
  );
  return {
    accepted: null,
    reason: "The file name does not give a season and episode number.",
    candidates: [
      ...named.map((one) => episodeCandidate(one, "Same title.")),
      ...dated
        .filter((one) => !named.includes(one))
        .map((one) => episodeCandidate(one, "Same air date.")),
      ...numbered
        .filter((one) => !named.includes(one) && !dated.includes(one))
        .map((one) => episodeCandidate(one, "Same number.")),
    ].slice(0, MAX_CANDIDATES),
  };
}

function episodeCandidate(episode: EpisodeDetails, evidence: string): Candidate {
  return {
    type: "episode",
    id: episode.id,
    title: episode.title,
    originalTitle: null,
    year: episode.airDate === null ? null : Number(episode.airDate.slice(0, 4)),
    overview: episode.overview,
    posterPath: null,
    season: episode.season,
    episode: episode.episode,
    evidence: [evidence],
  };
}

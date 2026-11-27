// SPDX-License-Identifier: MPL-2.0
import { LOGO_PATH } from "../artwork/logos.ts";
import type { Studio } from "../library/studios.ts";
import type { LimitedFetch } from "./http.ts";
import {
  ProviderError,
  ProviderUnavailable,
  type ArtworkKind,
  type EpisodeDetails,
  type ImageOption,
  type ImageOwner,
  type ImageSize,
  type MetadataProvider,
  type RemoteImage,
  type SearchHit,
  type SearchResult,
  type SeasonDetails,
  type TitleDetails,
  type StudioLogo,
  type TitleType,
  type Trailer,
  type Credit,
} from "./provider.ts";

/** The notice TMDB's terms ask every product that uses its data to show. */
export const TMDB_ATTRIBUTION =
  "This product uses the TMDB API but is not endorsed or certified by TMDB.";
export const TMDB_BASE_URL = "https://api.themoviedb.org/3";
export const TMDB_IMAGE_BASE_URL = "https://image.tmdb.org/t/p";

const MAX_SEARCH_PAGES = 3;
const MAX_IMAGE_OPTIONS = 30;
const PREVIEWS: Record<ArtworkKind, string> = {
  poster: "w185",
  backdrop: "w300",
  still: "w300",
  logo: "w300",
};
// TMDB's widest logo, w500, is too small for a banner.
const SIZES: Record<ArtworkKind, string> = {
  poster: "w780",
  backdrop: "w1280",
  still: "w780",
  logo: "original",
};
const NORMAL_BACKDROP = 1280;
const MAX_LOGO_CANDIDATES = 3;

export interface TmdbOptions {
  key: string;
  /** Household language as a TMDB locale, e.g. "en-US". */
  language: string;
  baseUrl?: string | undefined;
  imageBaseUrl?: string | undefined;
}

// TMDB's shapes, limited to what is read. Anything may be missing.
interface RawHit {
  id?: number;
  title?: string;
  name?: string;
  original_title?: string;
  original_name?: string;
  release_date?: string;
  first_air_date?: string;
  overview?: string;
  poster_path?: string | null;
  show_id?: number;
}
interface RawImage {
  file_path?: string;
  iso_639_1?: string | null;
  width?: number;
  height?: number;
  vote_average?: number;
  vote_count?: number;
}
interface RawImages {
  logos?: RawImage[];
  stills?: RawImage[];
  posters?: RawImage[];
  backdrops?: RawImage[];
}
interface RawVideo {
  site?: string;
  type?: string;
  key?: string;
  official?: boolean;
  iso_639_1?: string | null;
  published_at?: string;
}
interface RawAlias {
  title?: string;
}
interface RawTranslation {
  iso_639_1?: string;
  data?: { title?: string; name?: string; overview?: string };
}
interface RawStudio {
  id?: number;
  name?: string;
  logo_path?: string | null;
  origin_country?: string;
}

interface RawPerson {
  id?: number;
  name?: string;
  character?: string;
  order?: number;
  job?: string;
  department?: string;
  profile_path?: string | null;
  /** aggregate_credits */
  roles?: { character?: string }[];
  jobs?: { job?: string }[];
  total_episode_count?: number;
}
interface RawCredits {
  cast?: RawPerson[];
  crew?: RawPerson[];
}

interface RawDetails extends RawHit {
  credits?: RawCredits;
  aggregate_credits?: RawCredits;
  created_by?: RawPerson[];
  belongs_to_collection?: { id?: number; name?: string } | null;
  original_language?: string;
  backdrop_path?: string | null;
  imdb_id?: string | null;
  runtime?: number | null;
  episode_run_time?: number[];
  genres?: { name?: string }[];
  production_companies?: RawStudio[];
  networks?: RawStudio[];
  seasons?: { season_number?: number; episode_count?: number }[];
  vote_count?: number;
  vote_average?: number;
  popularity?: number;
  tagline?: string;
  external_ids?: { imdb_id?: string | null };
  videos?: { results?: RawVideo[] };
  images?: RawImages;
  alternative_titles?: { titles?: RawAlias[]; results?: RawAlias[] };
  translations?: { translations?: RawTranslation[] };
}
interface RawEpisode {
  id?: number;
  episode_number?: number;
  name?: string;
  overview?: string;
  air_date?: string | null;
  runtime?: number | null;
  still_path?: string | null;
}
interface RawSeason {
  id?: number;
  name?: string;
  overview?: string;
  air_date?: string | null;
  poster_path?: string | null;
  images?: RawImages;
  episodes?: RawEpisode[];
}

/** Talks to TMDB's v3 API. Sends titles, years and ids; never a path or file name. */
export class TmdbProvider implements MetadataProvider {
  private readonly http: LimitedFetch;
  private readonly language: string;
  private readonly lang: string;
  private readonly baseUrl: string;
  private readonly imageBaseUrl: string;
  /** Private so nothing that prints this object can print the key. */
  readonly #key: string;

  constructor(http: LimitedFetch, options: TmdbOptions) {
    this.http = http;
    this.#key = options.key.trim();
    this.language = options.language;
    this.lang = options.language.split("-")[0]?.toLowerCase() ?? "en";
    this.baseUrl = (options.baseUrl ?? TMDB_BASE_URL).replace(/\/+$/, "");
    this.imageBaseUrl = (options.imageBaseUrl ?? TMDB_IMAGE_BASE_URL).replace(/\/+$/, "");
  }

  async search(type: TitleType, title: string, year: number | null): Promise<SearchResult> {
    const hits: SearchHit[] = [];
    for (let page = 1; ; page += 1) {
      const raw = await this.json<{ results?: RawHit[]; total_pages?: number }>(
        `/search/${type}`,
        {
          query: title,
          include_adult: "false",
          page: String(page),
          ...(year === null
            ? {}
            : {
                [type === "movie" ? "primary_release_year" : "first_air_date_year"]: String(year),
              }),
        },
        `Searching ${type}`,
      );
      for (const result of raw?.results ?? []) {
        const hit = toHit(type, result);
        // A result can move to the next page between two requests.
        if (hit && !hits.some((known) => known.id === hit.id)) hits.push(hit);
      }
      if (page >= (raw?.total_pages ?? 1)) return { hits, complete: true };
      if (page >= MAX_SEARCH_PAGES) return { hits, complete: false };
    }
  }

  /**
   * One page of TMDB's search for films, shows or people, for search beyond the library. Only
   * the words go; never anything of the household.
   */
  async searchOutside(
    kind: "movie" | "tv" | "person",
    query: string,
    year: number | null,
  ): Promise<OutsideHit[]> {
    const raw = await this.json<{ results?: RawOutside[] }>(
      `/search/${kind}`,
      {
        query,
        include_adult: "false",
        page: "1",
        ...(year === null || kind === "person"
          ? {}
          : { [kind === "movie" ? "primary_release_year" : "first_air_date_year"]: String(year) }),
      },
      `Searching ${kind}`,
    );
    return (raw?.results ?? []).flatMap((one) => {
      const hit = outsideHit(kind, one);
      return hit ? [hit] : [];
    });
  }

  /** A film or show beyond the library: its ids, people and numbers. */
  async outsideTitle(type: TitleType, id: number): Promise<OutsideTitleDetails | null> {
    const raw = await this.json<RawDetails & { vote_average?: number }>(
      `/${type}/${id}`,
      { append_to_response: `external_ids,${type === "movie" ? "credits" : "aggregate_credits"}` },
      `Reading ${type} ${id}`,
    );
    if (raw?.id === undefined) return null;
    const hit = outsideHit(type, raw);
    if (!hit || hit.kind === "person") return null;
    return {
      ...hit,
      imdbId: imdb(raw.external_ids?.imdb_id ?? raw.imdb_id),
      genres: (raw.genres ?? []).map((one) => text(one.name)).filter((one) => one !== null),
      runtimeMinutes: positive(raw.runtime) ?? positive(raw.episode_run_time?.[0]),
      credits: credits(raw),
    };
  }

  /** A person: who they are, their ids, and what they were in. */
  async person(id: number): Promise<OutsidePerson | null> {
    const raw = await this.json<{
      id?: number;
      name?: string;
      biography?: string;
      birthday?: string | null;
      deathday?: string | null;
      known_for_department?: string;
      profile_path?: string | null;
      external_ids?: { imdb_id?: string | null };
      combined_credits?: { cast?: RawOutside[]; crew?: RawOutside[] };
    }>(
      `/person/${id}`,
      { append_to_response: "combined_credits,external_ids" },
      `Reading person ${id}`,
    );
    const name = text(raw?.name);
    if (raw?.id === undefined || name === null) return null;
    const titles: OutsidePerson["titles"] = [];
    const add = (one: RawOutside, role: string | null): void => {
      const kind = one.media_type === "tv" ? "tv" : one.media_type === "movie" ? "movie" : null;
      if (kind === null) return;
      const hit = outsideHit(kind, one);
      if (!hit || hit.kind === "person") return;
      const known = titles.find((title) => title.kind === hit.kind && title.id === hit.id);
      const detail = role ?? text(one.character);
      if (known) {
        if (detail !== null && !known.roles.includes(detail)) known.roles.push(detail);
        return;
      }
      titles.push({ ...hit, roles: detail === null ? [] : [detail], asCast: role === null });
    };
    for (const one of raw.combined_credits?.cast ?? []) add(one, null);
    for (const one of raw.combined_credits?.crew ?? []) add(one, text(one.job) ?? "Crew");
    return {
      id: raw.id,
      name,
      biography: text(raw.biography),
      birthday: isoDate(raw.birthday),
      deathday: isoDate(raw.deathday),
      knownFor: text(raw.known_for_department),
      profilePath: jpegPath(raw.profile_path),
      imdbId: /^nm[0-9]{7,}$/.test(raw.external_ids?.imdb_id ?? "")
        ? (raw.external_ids?.imdb_id ?? null)
        : null,
      titles,
    };
  }

  async searchLogos(name: string): Promise<StudioLogo[]> {
    const raw = await this.json<{
      results?: { name?: string; logo_path?: string | null; origin_country?: string }[];
    }>("/search/company", { query: name, language: "" }, "Searching studios");
    return (raw?.results ?? []).flatMap((one): StudioLogo[] => {
      const studio = text(one.name);
      if (studio === null || !one.logo_path) return [];
      return [{ name: studio, country: text(one.origin_country), path: one.logo_path }];
    });
  }

  async findByImdb(imdbId: string): Promise<{ type: TitleType; id: number }[]> {
    const raw = await this.json<{
      movie_results?: RawHit[];
      tv_results?: RawHit[];
      tv_season_results?: RawHit[];
      tv_episode_results?: RawHit[];
    }>(`/find/${encodeURIComponent(imdbId)}`, { external_source: "imdb_id" }, "Finding an id");
    const found: { type: TitleType; id: number }[] = [];
    for (const hit of raw?.movie_results ?? []) {
      if (hit.id !== undefined) found.push({ type: "movie", id: hit.id });
    }
    for (const hit of raw?.tv_results ?? []) {
      if (hit.id !== undefined) found.push({ type: "tv", id: hit.id });
    }
    for (const hit of [...(raw?.tv_season_results ?? []), ...(raw?.tv_episode_results ?? [])]) {
      if (hit.show_id !== undefined) found.push({ type: "tv", id: hit.show_id });
    }
    return found.filter(
      (one, index) => found.findIndex((o) => o.type === one.type && o.id === one.id) === index,
    );
  }

  async details(type: TitleType, id: number): Promise<TitleDetails | null> {
    const raw = await this.json<RawDetails>(
      `/${type}/${id}`,
      {
        append_to_response: `external_ids,videos,images,alternative_titles,translations,${
          type === "movie" ? "credits" : "aggregate_credits"
        }`,
        include_image_language: [...new Set([this.lang, "en", "null"])].join(","),
        include_video_language: [...new Set([this.lang, "en", "null"])].join(","),
      },
      `Reading ${type} ${id}`,
    );
    if (raw?.id === undefined) return null;
    const title = text(raw.title ?? raw.name);
    if (title === null) throw new ProviderError(`Reading ${type} ${id} gave no title`);
    const translations = raw.translations?.translations ?? [];
    const overviewIn = (language: string | undefined): string | null =>
      text(
        translations.find((one) => one.iso_639_1 === language && text(one.data?.overview))?.data
          ?.overview,
      );
    const date = isoDate(raw.release_date ?? raw.first_air_date);
    return {
      type,
      id: raw.id,
      imdbId: imdb(raw.external_ids?.imdb_id ?? raw.imdb_id),
      title,
      originalTitle: text(raw.original_title ?? raw.original_name) ?? title,
      aliases: [
        ...(raw.alternative_titles?.titles ?? raw.alternative_titles?.results ?? []).map(
          (one) => one.title,
        ),
        ...translations.map((one) => one.data?.title ?? one.data?.name),
      ].filter((one) => one !== undefined && one.trim() !== "") as string[],
      year: yearOf(date),
      date,
      overview: text(raw.overview) ?? overviewIn(raw.original_language) ?? overviewIn("en"),
      runtimeMinutes: positive(raw.runtime),
      genres: (raw.genres ?? []).map((one) => text(one.name)).filter((one) => one !== null),
      trailer: this.trailer(raw.videos?.results ?? []),
      images: await this.titleImages(type, raw.id, raw),
      seasons: (raw.seasons ?? [])
        .map((one) => ({ number: one.season_number, episodes: one.episode_count ?? 0 }))
        .filter((one): one is { number: number; episodes: number } => one.number !== undefined),
      votes: raw.vote_count ?? 0,
      rating: raw.vote_count ? positive(raw.vote_average) : null,
      popularity: positive(raw.popularity),
      tagline: text(raw.tagline?.replace(/\s+/g, " ")),
      posterPath: jpegPath(raw.poster_path),
      studios: [
        ...(raw.production_companies ?? []).map((one) => studio("company", one)),
        ...(raw.networks ?? []).map((one) => studio("network", one)),
      ].filter((one) => one !== null),
      credits: credits(raw),
      collection:
        raw.belongs_to_collection?.id !== undefined && text(raw.belongs_to_collection.name) !== null
          ? { id: raw.belongs_to_collection.id, name: text(raw.belongs_to_collection.name) ?? "" }
          : null,
    };
  }

  /** Household language first, then the original language, then whatever TMDB shows itself. */
  private async titleImages(type: TitleType, id: number, raw: RawDetails): Promise<RemoteImage[]> {
    const result: RemoteImage[] = [];
    let poster = pick(raw.images?.posters, this.lang);
    const original = raw.original_language;
    if (!poster && original !== undefined && original !== this.lang) {
      const more = await this.json<RawImages>(
        `/${type}/${id}/images`,
        { include_image_language: `${original},null`, language: "" },
        `Reading images of ${type} ${id}`,
      );
      poster = pick(more?.posters, original);
    }
    poster ??= pick(raw.images?.posters, null) ?? own(raw.poster_path);
    if (poster) result.push({ kind: "poster", ...poster });
    // A backdrop without words on it suits every screen.
    const banner = bestBanner(raw.images?.backdrops);
    const backdrop =
      banner ??
      pick(raw.images?.backdrops, null) ??
      pick(raw.images?.backdrops, this.lang) ??
      own(raw.backdrop_path);
    if (backdrop) {
      const { width } = raw.images?.backdrops?.find((one) => one.file_path === backdrop.path) ?? {};
      const large = (width ?? 0) > NORMAL_BACKDROP ? { large: true } : {};
      result.push({ kind: "backdrop", path: backdrop.path, language: backdrop.language, ...large });
    }
    result.push(...this.logos(raw.images?.logos).slice(0, MAX_LOGO_CANDIDATES));
    return result;
  }

  /** In the household's language, then English, then without one. TMDB's order within those. */
  private logos(logos: RawImage[] | undefined): RemoteImage[] {
    const languages = [...new Set<string | null>([this.lang, "en", null])];
    return languages.flatMap((language) =>
      (logos ?? []).flatMap((one): RemoteImage[] =>
        (one.iso_639_1 ?? null) === language && fitsAsLogo(one) && one.file_path !== undefined
          ? [{ kind: "logo", path: one.file_path, language }]
          : [],
      ),
    );
  }

  /** The title's own trailer: official and on a provider the apps can open. */
  private trailer(videos: RawVideo[]): Trailer | null {
    const usable = videos.filter(
      (one) =>
        one.site === "YouTube" &&
        one.type === "Trailer" &&
        one.official === true &&
        /^[\w-]{6,20}$/.test(one.key ?? ""),
    );
    const rank = (one: RawVideo): number => (one.iso_639_1 === this.lang ? 0 : 1);
    const best = usable.sort(
      (a, b) => rank(a) - rank(b) || (b.published_at ?? "").localeCompare(a.published_at ?? ""),
    )[0];
    return best?.key === undefined ? null : { provider: "youtube", key: best.key };
  }

  async season(showId: number, season: number): Promise<SeasonDetails | null> {
    const raw = await this.json<RawSeason>(
      `/tv/${showId}/season/${season}`,
      { append_to_response: "images", include_image_language: `${this.lang},null` },
      `Reading season ${season} of tv ${showId}`,
    );
    if (raw?.id === undefined) return null;
    const poster =
      pick(raw.images?.posters, this.lang) ??
      own(raw.poster_path) ??
      pick(raw.images?.posters, null);
    return {
      id: raw.id,
      season,
      title: text(raw.name) ?? `Season ${season}`,
      overview: text(raw.overview),
      airDate: isoDate(raw.air_date),
      poster: poster ? { kind: "poster", ...poster } : null,
      episodes: (raw.episodes ?? [])
        .map((one) => toEpisode(season, one))
        .filter((one) => one !== null),
    };
  }

  async episodeImdbId(showId: number, season: number, episode: number): Promise<string | null> {
    const raw = await this.json<{ imdb_id?: string | null }>(
      `/tv/${showId}/season/${season}/episode/${episode}/external_ids`,
      {},
      `Reading ids of an episode of tv ${showId}`,
    );
    return imdb(raw?.imdb_id);
  }

  async imageOptions(owner: ImageOwner, kind: ArtworkKind): Promise<ImageOption[]> {
    const part =
      owner.season === undefined
        ? ""
        : `/season/${owner.season}${owner.episode === undefined ? "" : `/episode/${owner.episode}`}`;
    const raw = await this.json<RawImages>(
      `/${owner.type}/${owner.id}${part}/images`,
      // Without a language TMDB lists every picture; the household's own come first below.
      { language: "" },
      `Listing pictures of ${owner.type} ${owner.id}`,
    );
    const list =
      {
        poster: raw?.posters,
        backdrop: raw?.backdrops,
        still: raw?.stills,
        logo: raw?.logos?.filter(fitsAsLogo),
      }[kind] ?? [];
    // A logo is words: without a language it is only a guess that they can be read.
    const [bare, english] = kind === "logo" ? [2, 1] : [1, 2];
    const rank = (language: string | null): number =>
      language === this.lang ? 0 : language === null ? bare : language === "en" ? english : 3;
    return list
      .flatMap((one): ImageOption[] => {
        const path = one.file_path;
        if (path === undefined || !imagePath(kind, path)) return [];
        const language = one.iso_639_1 ?? null;
        return [{ kind, path, language, width: one.width ?? null, height: one.height ?? null }];
      })
      .sort((a, b) => rank(a.language) - rank(b.language))
      .slice(0, MAX_IMAGE_OPTIONS);
  }

  async image(
    kind: ArtworkKind,
    path: string,
    size: ImageSize = "normal",
  ): Promise<Uint8Array<ArrayBuffer> | null> {
    if (!imagePath(kind, path)) return null;
    // Stills are not listed at this size in TMDB's configuration; the original always exists.
    const sizes = {
      preview: [PREVIEWS[kind]],
      normal: [...new Set([SIZES[kind], "original"])],
      original: ["original"],
    }[size];
    for (const size of sizes) {
      const { status, body } = await this.http.get(
        new URL(`${this.imageBaseUrl}/${size}${path}`),
        {},
        `Downloading a ${kind}`,
      );
      if (status === 200) return body;
    }
    return null;
  }

  private async json<T>(
    path: string,
    query: Record<string, string>,
    what: string,
  ): Promise<T | null> {
    if (!/^[\w.-]+$/.test(this.#key)) {
      throw new ProviderUnavailable("The TMDB key has characters a key cannot have", true);
    }
    const url = new URL(`${this.baseUrl}${path}`);
    for (const [name, value] of Object.entries({ language: this.language, ...query })) {
      if (value !== "") url.searchParams.set(name, value);
    }
    const headers: Record<string, string> = { accept: "application/json" };
    // A v3 key is 32 hex digits and goes in the query; a v4 token is a bearer credential.
    if (/^[0-9a-f]{32}$/i.test(this.#key)) url.searchParams.set("api_key", this.#key);
    else headers["authorization"] = `Bearer ${this.#key}`;
    const { status, body } = await this.http.get(url, headers, what);
    if (status === 404) return null;
    if (status !== 200) throw new ProviderError(`${what} gave status ${status}`);
    let parsed: unknown;
    try {
      parsed = JSON.parse(new TextDecoder().decode(body));
    } catch {
      throw new ProviderError(`${what} gave an answer that is not JSON`);
    }
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
      throw new ProviderError(`${what} gave an unexpected answer`);
    }
    return parsed as T;
  }
}

interface RawOutside extends RawHit {
  media_type?: string;
  vote_average?: number;
  vote_count?: number;
  popularity?: number;
  profile_path?: string | null;
  known_for_department?: string;
  known_for?: RawOutside[];
  character?: string;
  job?: string;
}

/** A film, show or person found at TMDB, beyond the library. */
export type OutsideHit =
  | {
      kind: "movie" | "tv";
      id: number;
      title: string;
      originalTitle: string;
      year: number | null;
      overview: string | null;
      posterPath: string | null;
      /** TMDB's average, null with fewer than 10 votes. */
      rating: number | null;
      votes: number;
      popularity: number;
    }
  | {
      kind: "person";
      id: number;
      name: string;
      knownFor: string | null;
      profilePath: string | null;
      knownForTitles: string[];
      popularity: number;
    };

export type OutsideTitleHit = Extract<OutsideHit, { kind: "movie" | "tv" }>;

export interface OutsideTitleDetails extends OutsideTitleHit {
  imdbId: string | null;
  genres: string[];
  runtimeMinutes: number | null;
  credits: Credit[];
}

export interface OutsidePerson {
  id: number;
  name: string;
  biography: string | null;
  birthday: string | null;
  deathday: string | null;
  knownFor: string | null;
  profilePath: string | null;
  imdbId: string | null;
  titles: (OutsideTitleHit & { roles: string[]; asCast: boolean })[];
}

function outsideHit(kind: "movie" | "tv" | "person", raw: RawOutside): OutsideHit | null {
  if (raw.id === undefined || !Number.isInteger(raw.id) || raw.id <= 0) return null;
  if (kind === "person") {
    const name = text(raw.name);
    if (name === null) return null;
    return {
      kind,
      id: raw.id,
      name,
      knownFor: text(raw.known_for_department),
      profilePath: jpegPath(raw.profile_path),
      knownForTitles: (raw.known_for ?? [])
        .map((one) => text(one.title ?? one.name))
        .filter((one) => one !== null)
        .slice(0, 3),
      popularity: raw.popularity ?? 0,
    };
  }
  const title = text(raw.title ?? raw.name);
  if (title === null) return null;
  const votes = raw.vote_count ?? 0;
  return {
    kind,
    id: raw.id,
    title,
    originalTitle: text(raw.original_title ?? raw.original_name) ?? title,
    year: yearOf(isoDate(raw.release_date ?? raw.first_air_date)),
    overview: text(raw.overview),
    posterPath: jpegPath(raw.poster_path),
    rating: votes >= 10 && raw.vote_average ? Math.round(raw.vote_average * 10) / 10 : null,
    votes,
    popularity: raw.popularity ?? 0,
  };
}

/** The most cast members kept of one title. */
export const MAX_CAST = 30;
const WRITING_JOBS = new Set(["Screenplay", "Writer", "Story", "Novel", "Author", "Characters"]);

/**
 * Who is in a title: the cast in billing order, its directors and writers, a show's creators.
 * A show's cast is of all its seasons (aggregate_credits), by how many episodes they were in.
 */
function credits(raw: RawDetails): Credit[] {
  const source = raw.credits ?? raw.aggregate_credits ?? {};
  const found: Credit[] = [];
  const add = (
    one: RawPerson,
    role: Credit["role"],
    character: string | null,
    order: number,
  ): void => {
    const name = text(one.name);
    if (one.id === undefined || !Number.isInteger(one.id) || one.id <= 0 || name === null) return;
    if (found.some((known) => known.personId === one.id && known.role === role)) return;
    found.push({
      personId: one.id,
      name,
      role,
      character,
      order,
      profilePath: jpegPath(one.profile_path),
    });
  };
  const cast = [...(source.cast ?? [])].sort((a, b) => (a.order ?? 999) - (b.order ?? 999));
  for (const one of cast.slice(0, MAX_CAST)) {
    const character =
      text(one.character) ??
      text(
        (one.roles ?? [])
          .map((role) => role.character ?? "")
          .filter((x) => x.trim() !== "")
          .join(" / "),
      );
    add(one, "cast", character, one.order ?? found.length);
  }
  let directors = 0;
  let writers = 0;
  for (const one of source.crew ?? []) {
    const jobs = one.jobs ? one.jobs.map((job) => job.job ?? "") : [one.job ?? ""];
    if (jobs.includes("Director") && directors < 10) add(one, "director", null, directors++);
    if (jobs.some((job) => WRITING_JOBS.has(job)) && writers < 10)
      add(one, "writer", null, writers++);
  }
  (raw.created_by ?? []).slice(0, 10).forEach((one, index) => {
    add(one, "creator", null, index);
  });
  return found;
}

function toHit(type: TitleType, raw: RawHit): SearchHit | null {
  const title = text(raw.title ?? raw.name);
  if (raw.id === undefined || title === null) return null;
  return {
    type,
    id: raw.id,
    title,
    originalTitle: text(raw.original_title ?? raw.original_name) ?? title,
    year: yearOf(isoDate(raw.release_date ?? raw.first_air_date)),
    overview: text(raw.overview),
    posterPath: jpegPath(raw.poster_path),
  };
}

function toEpisode(season: number, raw: RawEpisode): EpisodeDetails | null {
  if (raw.id === undefined || raw.episode_number === undefined) return null;
  return {
    id: raw.id,
    season,
    episode: raw.episode_number,
    title: text(raw.name) ?? "",
    overview: text(raw.overview),
    airDate: isoDate(raw.air_date),
    runtimeMinutes: positive(raw.runtime),
    stillPath: jpegPath(raw.still_path),
  };
}

/** The first image in this language. TMDB lists the best rated first. */
function pick(
  images: RawImage[] | undefined,
  language: string | null,
): { path: string; language: string | null } | null {
  const found = (images ?? []).find(
    (one) => (one.iso_639_1 ?? null) === language && jpegPath(one.file_path) !== null,
  );
  return found?.file_path === undefined ? null : { path: found.file_path, language };
}

/**
 * The best rated picture without words that is wide enough for a banner. A few votes do not
 * count for much, so one enthusiast does not decide.
 */
function bestBanner(images: RawImage[] | undefined): { path: string; language: null } | null {
  const score = ({ vote_average: average = 0, vote_count: count = 0 }: RawImage): number =>
    (average * count + 5 * 5) / (count + 5);
  const fitting = (images ?? []).filter(
    ({ iso_639_1: language, width = 0, height = 0, file_path: path }) =>
      (language ?? null) === null &&
      jpegPath(path) !== null &&
      width >= NORMAL_BACKDROP &&
      height > 0 &&
      width / height >= 1.6 &&
      width / height <= 2.4,
  );
  // Sorting keeps TMDB's order between equals.
  const best = [...fitting].sort((a, b) => score(b) - score(a))[0];
  return best?.file_path === undefined ? null : { path: best.file_path, language: null };
}

/**
 * Whether a logo can stand on a banner. Only PNG: an SVG is a program as much as a picture,
 * and not every one has a drawn version.
 */
function fitsAsLogo({ file_path: path, width = 0, height = 0 }: RawImage): boolean {
  if (path === undefined || !imagePath("logo", path)) return false;
  if (width < 200 || width > 4000 || height < 40 || height > 4000) return false;
  return width / height >= 0.8 && width / height <= 12;
}

/** Whether this is a path at the provider that a picture of this kind can have. */
function studio(kind: Studio["kind"], raw: RawStudio): Studio | null {
  const name = text(raw.name);
  if (name === null || !Number.isInteger(raw.id) || (raw.id ?? 0) <= 0) return null;
  return {
    kind,
    id: raw.id ?? 0,
    name,
    logoPath: raw.logo_path && LOGO_PATH.test(raw.logo_path) ? raw.logo_path : null,
    country: text(raw.origin_country),
  };
}

export function imagePath(kind: ArtworkKind, path: string): boolean {
  return kind === "logo" ? /^\/[\w-]+\.png$/i.test(path) : jpegPath(path) !== null;
}

function own(path: string | null | undefined): { path: string; language: string | null } | null {
  const valid = jpegPath(path);
  return valid === null ? null : { path: valid, language: null };
}

function jpegPath(path: string | null | undefined): string | null {
  return path && /^\/[\w-]+\.jpe?g$/i.test(path) ? path : null;
}
function text(value: string | null | undefined): string | null {
  const trimmed = value?.trim();
  return trimmed ? trimmed : null;
}
function isoDate(value: string | null | undefined): string | null {
  return value && /^\d{4}-\d{2}-\d{2}$/.test(value) ? value : null;
}
function yearOf(date: string | null): number | null {
  return date === null ? null : Number(date.slice(0, 4));
}
function positive(value: number | null | undefined): number | null {
  return value && value > 0 ? value : null;
}
function imdb(value: string | null | undefined): string | null {
  return value && /^tt\d{7,}$/.test(value) ? value : null;
}

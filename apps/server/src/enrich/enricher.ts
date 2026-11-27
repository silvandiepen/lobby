// SPDX-License-Identifier: MPL-2.0
import type { Catalogue } from "../library/catalogue.ts";
import type { Database } from "../db/database.ts";
import { sortTitle, type ParsedMedia } from "../library/parse.ts";
import { Studios, type Studio } from "../library/studios.ts";
import { saveSearchFacts, searchFactsOf, type SearchFacts } from "../search/credits.ts";
import { errorMessage, log } from "../log.ts";
import { DEFAULT_LIMITS, LimitedFetch, type FetchLimits } from "./http.ts";
import { ImageFiles, type ImageFolder, type PreparedImage } from "./images.ts";
import {
  isPlaceholder,
  matchByTitle,
  matchNumbered,
  matchTitle,
  type Candidate,
  type Decision,
  type WantedEpisode,
  type WantedTitle,
} from "./match.ts";
import {
  ProviderError,
  ProviderUnavailable,
  type ArtworkKind,
  type EpisodeDetails,
  type ImageOption,
  type ImageOwner,
  type MetadataProvider,
  type RemoteImage,
  type SearchHit,
  type StudioLogo,
  type SeasonDetails,
  type TitleDetails,
  type TitleType,
  type Trailer,
} from "./provider.ts";
import { TmdbProvider } from "./tmdb.ts";

const DAY_MS = 86_400_000;
const FIRST_RETRY_MS = 60_000;
const MAX_RETRY_MS = DAY_MS;
const MAX_PAUSE_MS = 3_600_000;
/** Bump when the matching rules change, so what needs review is looked at again. */
const MATCHER_VERSION = 2;
/** This many titles failing in a row means TMDB is down, not that the titles are odd. */
const OUTAGE_AFTER = 3;

export interface EnricherOptions {
  db: Database;
  catalogue: Catalogue;
  /** A TMDB v3 key or v4 read token. Without one, `run` does nothing. */
  key: string | null;
  /** Household language as a TMDB locale, e.g. "en-US". */
  language: string;
  /** Where downloaded pictures are kept. Never inside a library root. */
  artworkDir: string;
  /** Makes pictures from TMDB smaller. Default "ffmpeg". */
  ffmpegPath?: string;
  baseUrl?: string;
  imageBaseUrl?: string;
  limits?: Partial<FetchLimits>;
  /** How many titles become visible to the apps at once. */
  batchSize?: number;
  /** How long a match stands before its details are fetched again. */
  refreshAfterMs?: number;
  /** How long before something without a strong match is looked up again. */
  reviewRetryMs?: number;
  /** How long before popularity, ratings and the pictures for a banner are looked at again. */
  factsAfterMs?: number;
  /** How many titles that are there already get those in one run. */
  factsPerRun?: number;
  now?: () => number;
}

export interface EnrichSummary {
  matched: number;
  needsReview: number;
  failed: number;
  /** True when the run ended early because TMDB could not be used. */
  interrupted: boolean;
}

interface ItemRow {
  id: string;
  kind: "movie" | "show" | "season" | "episode";
  parent_id: string | null;
  title: string;
  year: number | null;
  season_number: number | null;
  episode_number: number | null;
  overview: string | null;
  air_date: string | null;
  runtime_ms: number | null;
  match_status: string;
  tmdb_type: string | null;
  tmdb_id: number | null;
  imdb_id: string | null;
  metadata_json: string | null;
  tagline: string | null;
  popularity: number | null;
  vote_average: number | null;
  vote_count: number | null;
  enriched_at: number | null;
  enrich_attempts: number;
}

interface AssetRow {
  parsed_json: string | null;
  duration_ms: number | null;
  part: number | null;
  items: number;
}

interface Fields {
  title?: string;
  year?: number | null;
  overview?: string | null;
  air_date?: string | null;
  runtime_ms?: number | null;
  tmdb_type?: TitleType | null;
  tmdb_id?: number;
  imdb_id?: string | null;
  tagline?: string | null;
  popularity?: number | null;
  vote_average?: number | null;
  vote_count?: number | null;
}

/** What a home page needs of a title, apart from what it is. */
function factsOf(details: TitleDetails): Fields {
  return {
    tagline: details.tagline,
    popularity: details.popularity,
    vote_average: details.rating,
    vote_count: details.votes,
  };
}

/** For something below a show: the show's match this was looked up with. */
interface Basis {
  showRowId: string;
  showId: number;
}

interface Match {
  kind: "match";
  item: ItemRow;
  basis?: Basis;
  fields: Fields;
  genres: string[] | null;
  /** Of a film or show. Null: nothing about them was read. */
  studios: Studio[] | null;
  /** Of a film or show: its people, other names and collection, for search. */
  search: SearchFacts | null;
  trailer: Trailer | null | undefined;
  images: PreparedImage[];
}
interface Review {
  kind: "review";
  item: ItemRow;
  basis?: Basis;
  reason: string;
  candidates: Candidate[];
}
/** Popularity and pictures of a title that is settled; nothing else about it is looked at. */
interface Facts {
  kind: "facts";
  item: ItemRow;
  basis?: Basis;
  fields: Fields;
  studios: Studio[] | null;
  search: SearchFacts | null;
  images: PreparedImage[];
}
/** The provider has nothing new. What is there stays. */
interface Unchanged {
  kind: "unchanged";
  item: ItemRow;
  basis?: Basis;
}
type Change = Match | Review | Facts | Unchanged;

/**
 * Gives films, shows, seasons and episodes their titles, summaries, genres, ids,
 * trailers and pictures from TMDB. It only ever adds to the catalogue: identity keys,
 * files and progress are untouched, and while TMDB is away nothing else waits for it.
 */
export class Enricher {
  private readonly db: Database;
  private readonly catalogue: Catalogue;
  private provider: MetadataProvider | null = null;
  /** For someone waiting: does not queue behind a run through the whole library. */
  private direct: TmdbProvider | null = null;
  /** Where and in which language TMDB is asked. Never the key: that is only in the providers. */
  private readonly tmdbPlace: {
    language: string;
    baseUrl: string | undefined;
    imageBaseUrl: string | undefined;
  };
  private readonly limits: FetchLimits;
  private readonly folder: ImageFolder;
  private readonly background = new Set<Promise<void>>();
  private readonly now: () => number;
  private readonly batchSize: number;
  private readonly workers: number;
  private readonly refreshAfterMs: number;
  private readonly reviewRetryMs: number;
  private readonly factsAfterMs: number;
  private readonly factsPerRun: number;
  private readonly stopping = new AbortController();
  private current: Promise<EnrichSummary> | null = null;
  private pausedUntil = 0;
  private outages = 0;

  constructor(options: EnricherOptions) {
    this.db = options.db;
    this.catalogue = options.catalogue;
    this.folder = {
      dir: options.artworkDir,
      ffmpegPath: options.ffmpegPath ?? "ffmpeg",
      reducing: Promise.resolve(),
      inFlight: new Set(),
      tended: false,
    };
    this.now = options.now ?? Date.now;
    this.batchSize = options.batchSize ?? 20;
    this.refreshAfterMs = options.refreshAfterMs ?? 90 * DAY_MS;
    this.reviewRetryMs = options.reviewRetryMs ?? 14 * DAY_MS;
    this.factsAfterMs = options.factsAfterMs ?? 30 * DAY_MS;
    this.factsPerRun = options.factsPerRun ?? 40;
    const limits = { ...DEFAULT_LIMITS, ...options.limits };
    this.limits = limits;
    this.tmdbPlace = {
      language: options.language,
      baseUrl: options.baseUrl,
      imageBaseUrl: options.imageBaseUrl,
    };
    this.workers = limits.maxConcurrent;
    this.setKey(options.key);
  }

  /**
   * Uses another TMDB key from now on, or none. A run under way finishes with the key it had;
   * the next one takes the new key.
   */
  setKey(key: string | null): void {
    const options = this.tmdbPlace;
    const limits = this.limits;
    if (key === null || key.trim() === "") {
      this.provider = null;
      this.direct = null;
    } else {
      const tmdb = {
        key,
        language: options.language,
        baseUrl: options.baseUrl,
        imageBaseUrl: options.imageBaseUrl,
      };
      const { signal } = this.stopping;
      this.provider = new TmdbProvider(new LimitedFetch(limits, signal), tmdb);
      const patience = { retries: Math.min(limits.retries, 1), maxBackoffMs: 3_000 };
      this.direct = new TmdbProvider(
        new LimitedFetch(
          { ...limits, ...patience, timeoutMs: Math.min(limits.timeoutMs, 10_000) },
          signal,
        ),
        tmdb,
      );
    }
  }

  /**
   * Ends the current run. From the moment this returns its promise, the run no longer
   * touches the database; the promise resolves once its files are tidied up as well.
   */
  async stop(): Promise<void> {
    this.stopping.abort();
    // Whoever called run() hears about its failure.
    await Promise.allSettled([this.current, ...this.background]);
  }

  /** Looks up everything that is due. A call during a run joins that run. */
  run(): Promise<EnrichSummary> {
    this.current ??= this.runOnce().finally(() => {
      this.current = null;
    });
    return this.current;
  }

  private isStopping(): boolean {
    return this.stopping.signal.aborted;
  }

  // For a manager choosing things by hand

  get isConfigured(): boolean {
    return this.provider !== null;
  }

  /** TMDB for search beyond the library; null without a key. Shares the patient limits. */
  get outside(): TmdbProvider | null {
    return this.direct;
  }

  private atOnce(): MetadataProvider {
    if (!this.direct) throw new ProviderUnavailable("This server has no TMDB key.");
    return this.direct;
  }

  /**
   * What a file about to be imported is, by the same rules as the library's own matching: only
   * a strong match with nothing else like it is accepted; anything less comes back with candidates.
   */
  identify(wanted: WantedTitle): Promise<Decision<TitleDetails>> {
    return matchTitle(this.atOnce(), wanted);
  }

  async search(type: TitleType, title: string, year: number | null): Promise<SearchHit[]> {
    return (await this.atOnce().search(type, title, year)).hits;
  }

  searchLogos(name: string): Promise<StudioLogo[]> {
    return this.atOnce().searchLogos(name);
  }

  details(type: TitleType, id: number): Promise<TitleDetails | null> {
    return this.atOnce().details(type, id);
  }

  imageOptions(owner: ImageOwner, kind: ArtworkKind): Promise<ImageOption[]> {
    return this.atOnce().imageOptions(owner, kind);
  }

  preview(kind: ArtworkKind, path: string): Promise<Uint8Array<ArrayBuffer> | null> {
    return this.atOnce().image(kind, path, "preview");
  }

  /**
   * Downloads a picture a manager picked and files it with `save`, which runs in a
   * transaction with the picture's artwork id. False when the provider does not have it.
   */
  async addImage(
    itemId: string,
    remote: RemoteImage,
    save: (artworkId: string) => void,
  ): Promise<boolean> {
    const images = this.imageFiles(this.atOnce());
    try {
      const image = await images.prepare(itemId, remote);
      if (!image) return false;
      this.db.transaction(() => {
        save(images.insert(itemId, image));
      });
      return true;
    } finally {
      await images.discardLoose();
    }
  }

  /**
   * Looks one film or show up right away. Resolves when the title itself is done; the
   * seasons and episodes of a show follow in the background.
   */
  async enrichNow(itemId: string): Promise<void> {
    const direct = this.atOnce();
    const { provider } = this;
    if (!provider || this.isStopping()) return;
    const summary: EnrichSummary = { matched: 0, needsReview: 0, failed: 0, interrupted: false };
    const images = this.imageFiles(direct);
    try {
      await this.newRun(direct, images, summary).title(itemId);
    } finally {
      await images.discardLoose();
    }
    const below = this.imageFiles(provider);
    const work = this.newRun(provider, below, summary)
      .children(itemId)
      .catch((error: unknown) => {
        if (!this.isStopping()) {
          log.warn("Could not look up what is in a show", {
            item: itemId,
            error: errorMessage(error).slice(0, 200),
          });
        }
      })
      .finally(() => below.discardLoose())
      .finally(() => {
        this.background.delete(work);
      });
    this.background.add(work);
  }

  /** Waits for lookups that `enrichNow` left running. */
  async settled(): Promise<void> {
    await Promise.allSettled([...this.background]);
  }

  private imageFiles(provider: MetadataProvider): ImageFiles {
    return new ImageFiles(this.db, provider, this.folder, this.stopping.signal);
  }

  private newRun(provider: MetadataProvider, images: ImageFiles, summary: EnrichSummary): Run {
    return new Run(this.db, this.catalogue, provider, images, this.stopping.signal, {
      now: this.now,
      batchSize: this.batchSize,
      workers: this.workers,
      refreshAfterMs: this.refreshAfterMs,
      reviewRetryMs: this.reviewRetryMs,
      factsAfterMs: this.factsAfterMs,
      factsPerRun: this.factsPerRun,
      summary,
    });
  }

  /** After the matching rules got better, what they could not match before gets another try. */
  private lookAgainIfImproved(): void {
    if (this.db.getMeta("matcher_version") === String(MATCHER_VERSION)) return;
    this.db.transaction(() => {
      this.db.run(
        "update item set enrich_next_attempt_at = 0 where match_status = 'needs_review' and candidates_json is not null",
      );
      this.db.setMeta("matcher_version", String(MATCHER_VERSION));
    });
  }

  private async runOnce(): Promise<EnrichSummary> {
    const summary: EnrichSummary = { matched: 0, needsReview: 0, failed: 0, interrupted: false };
    const { provider } = this;
    if (!provider || this.isStopping() || this.now() < this.pausedUntil) return summary;
    this.lookAgainIfImproved();
    const images = this.imageFiles(provider);
    const run = this.newRun(provider, images, summary);
    try {
      await run.work();
    } catch (error) {
      if (!this.isStopping()) throw error;
    } finally {
      await images.discardLoose();
    }
    if (this.isStopping()) return summary;
    if (run.outage) {
      summary.interrupted = true;
      const pause = run.outage.keyRefused
        ? MAX_PAUSE_MS
        : Math.min(FIRST_RETRY_MS * 2 ** this.outages, MAX_PAUSE_MS);
      this.outages += 1;
      this.pausedUntil = this.now() + pause;
      log.warn("TMDB cannot be used now; titles and pictures wait", {
        error: run.outage.message,
        retryInSeconds: Math.round(pause / 1000),
      });
    } else {
      this.outages = 0;
    }
    if (summary.matched + summary.needsReview + summary.failed > 0) {
      log.info("Looked titles up on TMDB", {
        matched: summary.matched,
        needsReview: summary.needsReview,
        failed: summary.failed,
      });
    }
    return summary;
  }
}

interface RunOptions {
  now: () => number;
  batchSize: number;
  workers: number;
  refreshAfterMs: number;
  reviewRetryMs: number;
  factsAfterMs: number;
  factsPerRun: number;
  summary: EnrichSummary;
}

/** One pass over what is due. */
class Run {
  outage: ProviderUnavailable | null = null;
  private readonly db: Database;
  private readonly catalogue: Catalogue;
  private readonly provider: MetadataProvider;
  private readonly images: ImageFiles;
  private readonly studios: Studios;
  private readonly signal: AbortSignal;
  private readonly options: RunOptions;
  private failuresInARow = 0;
  private batch: Change[] = [];

  constructor(
    db: Database,
    catalogue: Catalogue,
    provider: MetadataProvider,
    images: ImageFiles,
    signal: AbortSignal,
    options: RunOptions,
  ) {
    this.db = db;
    this.catalogue = catalogue;
    this.provider = provider;
    this.images = images;
    this.studios = new Studios(db);
    this.signal = signal;
    this.options = options;
  }

  async work(): Promise<void> {
    try {
      await this.images.tend();
    } catch (error) {
      if (!(error instanceof ProviderUnavailable)) throw error;
      this.outage = error;
      return;
    }
    const due = this.due();
    const dueIds = new Set(due.map((item) => item.id));
    const shows = new Map<string, ItemRow>();
    for (const item of due) {
      let top: ItemRow | undefined = item;
      while (top && top.kind !== "show") {
        top = top.parent_id === null ? undefined : this.item(top.parent_id);
      }
      if (top) shows.set(top.id, top);
    }
    const tasks: (() => Promise<unknown>)[] = [
      ...due
        .filter((item) => item.kind === "movie")
        .map((item) => () => this.attempt([item], () => this.movie(item))),
      ...[...shows.values()].map((show) => () => this.show(show, dueIds)),
    ];

    let next = 0;
    const worker = async (): Promise<void> => {
      while (!this.outage && !this.signal.aborted) {
        const task = tasks[next];
        next += 1;
        if (!task) return;
        await task();
      }
    };
    await allDone(Array.from({ length: this.options.workers }, worker));
    this.flush();
    await this.facts();
  }

  /**
   * Popularity, taglines and the pictures for a banner, for titles that are settled: what was
   * there before these were kept, and after that once a month. One at a time and a few per run;
   * each is saved with the moment it was looked at, so a restart goes on where it was.
   */
  private async facts(): Promise<void> {
    const now = this.options.now();
    const due = this.db.all<ItemRow>(
      `select * from item where kind in ('movie', 'show') and match_status in ('matched', 'locked')
         and tmdb_id is not null and enriched_at is not null
         -- What was settled before studios and credits were kept gets them with the next few runs.
         and (facts_at is null or facts_at <= ? or studios_at is null or credits_at is null)
         and (enrich_next_attempt_at is null or enrich_next_attempt_at <= ?)
       order by facts_at is not null, facts_at, added_at desc limit ?`,
      [now - this.options.factsAfterMs, now, this.options.factsPerRun],
    );
    for (const item of due) {
      if (this.outage || this.signal.aborted) break;
      await this.attempt([item], async () => {
        if (!isSettled(item)) return;
        const type = item.kind === "movie" ? "movie" : "tv";
        const details = await this.provider.details(type, item.tmdb_id);
        this.signal.throwIfAborted();
        if (!details) {
          this.batch.push({
            kind: "facts",
            item,
            fields: {},
            studios: null,
            search: null,
            images: [],
          });
          return;
        }
        const wanted = details.images.filter((one) => one.kind !== "poster");
        const images = await this.prepare(item, wanted);
        this.batch.push({
          kind: "facts",
          item,
          fields: factsOf(details),
          studios: details.studios,
          search: searchFactsOf(details),
          images,
        });
      });
      if (this.batch.length >= this.options.batchSize) this.flush();
    }
    this.flush();
  }

  /** Looks up this film or show itself. */
  async title(itemId: string): Promise<void> {
    const item = this.item(itemId);
    if (item?.kind === "movie") await this.attempt([item], () => this.movie(item));
    if (item?.kind === "show") await this.showTitle(item);
    this.flush();
  }

  /** Looks up every season and episode of this show that is not settled. */
  async children(itemId: string): Promise<void> {
    const show = this.item(itemId);
    if (show?.kind !== "show") return;
    const ids = this.catalogue
      .followers(show.id)
      .filter((id) => this.item(id)?.match_status !== "matched");
    await this.showChildren(show, new Set(ids), null);
  }

  private due(): ItemRow[] {
    const now = this.options.now();
    return this.db.all<ItemRow>(
      `select * from item where (
         (match_status = 'unmatched' and (enrich_next_attempt_at is null or enrich_next_attempt_at <= ?1
           -- The file names were read again since it was looked up.
           or candidates_json is not null))
         or (match_status = 'needs_review' and (enrich_next_attempt_at <= ?1
           or (kind = 'episode' and enrich_next_attempt_at is null)))
         or ((match_status = 'matched' or (match_status = 'locked' and tmdb_id is not null))
           and (enriched_at is null or enriched_at <= ?2)
           and (enrich_next_attempt_at is null or enrich_next_attempt_at <= ?1)))
       and (kind in ('movie', 'show', 'episode') or (kind = 'season' and season_number is not null))
       -- A file whose name gave no usable title; a file name is not sent to anyone.
       and ident_key not like 'unknown:%'
       order by added_at desc`,
      [now, now - this.options.refreshAfterMs],
    );
  }

  private item(id: string): ItemRow | undefined {
    return this.db.get<ItemRow>("select * from item where id = ?", [id]);
  }

  /** Runs one lookup. A failure delays these items, and never ends the whole run by itself. */
  private async attempt(items: ItemRow[], work: () => Promise<void>): Promise<boolean> {
    try {
      await work();
      this.failuresInARow = 0;
      return true;
    } catch (error) {
      this.signal.throwIfAborted();
      const now = this.options.now();
      this.db.transaction(() => {
        for (const item of items) {
          const wait = Math.min(
            FIRST_RETRY_MS * 2 ** Math.min(item.enrich_attempts, 20),
            MAX_RETRY_MS,
          );
          this.db.run(
            `update item set enrich_attempts = enrich_attempts + 1, enrich_next_attempt_at = ?,
               candidates_json = case when match_status = 'unmatched' then null else candidates_json end
             where id = ?`,
            [now + wait, item.id],
          );
        }
      });
      this.options.summary.failed += items.length;
      if (error instanceof ProviderUnavailable) {
        this.failuresInARow += 1;
        if (error.keyRefused || this.failuresInARow >= OUTAGE_AFTER) this.outage ??= error;
      } else {
        log.warn("Could not look a title up", {
          item: items[0]?.id,
          error: errorMessage(error).slice(0, 200),
        });
      }
      return false;
    }
  }

  // Films

  private async movie(item: ItemRow): Promise<void> {
    const decision = await this.findTitle(item, "movie");
    this.signal.throwIfAborted();
    const change: Change = await this.titleChange(item, decision);
    this.batch.push(change);
    if (this.batch.length >= this.options.batchSize) this.flush();
  }

  private async findTitle(item: ItemRow, type: TitleType): Promise<Decision<TitleDetails> | null> {
    if (isSettled(item)) {
      const details = await this.provider.details(type, item.tmdb_id);
      return details ? { accepted: details } : null;
    }
    return matchTitle(this.provider, this.wantedTitle(item, type));
  }

  private async titleChange(
    item: ItemRow,
    decision: Decision<TitleDetails> | null,
  ): Promise<Change> {
    if (decision === null) return { kind: "unchanged", item };
    if (decision.accepted === null) return { ...decision, kind: "review", item };
    const details = decision.accepted;
    return {
      kind: "match",
      item,
      fields: {
        title: details.title,
        year: details.year ?? item.year,
        overview: details.overview,
        air_date: details.date,
        ...(details.type === "movie"
          ? { runtime_ms: details.runtimeMinutes === null ? null : details.runtimeMinutes * 60_000 }
          : {}),
        tmdb_type: details.type,
        tmdb_id: details.id,
        imdb_id: details.imdbId,
        ...factsOf(details),
      },
      genres: details.genres,
      studios: details.studios,
      search: searchFactsOf(details),
      trailer: details.trailer,
      images: await this.prepare(item, details.images),
    };
  }

  private async prepare(item: ItemRow, remote: RemoteImage[]): Promise<PreparedImage[]> {
    const prepared: PreparedImage[] = [];
    for (const one of remote) {
      // The rest are there for when the first is no logo to draw.
      if (one.kind === "logo" && prepared.some((other) => other.remote.kind === "logo")) continue;
      try {
        const image = await this.images.prepare(item.id, one);
        if (image) prepared.push(image);
      } catch (error) {
        // One unusable picture costs only that picture.
        if (!(error instanceof ProviderError)) throw error;
      }
    }
    return prepared;
  }

  private assets(itemId: string): AssetRow[] {
    return this.db.all<AssetRow>(
      `select asset.parsed_json, asset.duration_ms, item_asset.part,
         (select count(*) from item_asset as other where other.asset_id = asset.id) as items
       from item_asset join asset on asset.id = item_asset.asset_id
       where item_asset.item_id = ? and item_asset.role = 'main' and asset.state = 'probed'`,
      [itemId],
    );
  }

  private wantedTitle(item: ItemRow, type: TitleType): WantedTitle {
    const wanted: WantedTitle = {
      type,
      title: item.title,
      year: item.year,
      tmdbIds: [],
      imdbIds: [],
      runtimes: [],
      episodes: [],
    };
    const assets: AssetRow[] = [];
    if (type === "movie") {
      assets.push(...this.assets(item.id));
      wanted.runtimes = filmRuntimes(assets);
    } else {
      const episodes = this.db.all<ItemRow>(
        `select episode.* from item as episode join item as season on season.id = episode.parent_id
         where season.parent_id = ? and episode.kind = 'episode'`,
        [item.id],
      );
      for (const episode of episodes) {
        const own = this.assets(episode.id);
        assets.push(...own);
        wanted.episodes.push({
          season: episode.season_number,
          episode: episode.episode_number,
          title: fileTitle(own),
        });
      }
    }
    for (const asset of assets) {
      const parsed = readParsed(asset);
      if (parsed?.tmdbId != null && !wanted.tmdbIds.includes(parsed.tmdbId)) {
        wanted.tmdbIds.push(parsed.tmdbId);
      }
      if (parsed?.imdbId != null && !wanted.imdbIds.includes(parsed.imdbId)) {
        wanted.imdbIds.push(parsed.imdbId);
      }
    }
    return wanted;
  }

  // Shows

  private async show(show: ItemRow, dueIds: Set<string>): Promise<void> {
    const details = dueIds.has(show.id) ? await this.showTitle(show) : null;
    const current = this.item(show.id);
    if (current) await this.showChildren(current, dueIds, details);
  }

  private async showTitle(show: ItemRow): Promise<TitleDetails | null> {
    let details: TitleDetails | null = null;
    await this.attempt([show], async () => {
      const decision = await this.findTitle(show, "tv");
      this.signal.throwIfAborted();
      this.apply([await this.titleChange(show, decision)]);
      details = decision?.accepted ?? null;
    });
    return details;
  }

  /** Only a show that is matched leads on to its seasons; nothing below a guess is guessed. */
  private async showChildren(
    show: ItemRow,
    dueIds: Set<string>,
    known: TitleDetails | null,
  ): Promise<void> {
    if (!isSettled(show)) return;
    const id = show.tmdb_id;
    const basis: Basis = { showRowId: show.id, showId: id };
    let details = known;

    const seasons = this.db.all<ItemRow>(
      "select * from item where parent_id = ? and kind = 'season' order by season_number",
      [show.id],
    );
    const loaded = new Map<number, SeasonDetails | null>();
    const season = async (number: number): Promise<SeasonDetails | null> => {
      const known = loaded.get(number);
      if (known !== undefined) return known;
      const details = await this.provider.season(id, number);
      loaded.set(number, details);
      return details;
    };
    const everyEpisode = async (): Promise<EpisodeDetails[]> => {
      details ??= await this.provider.details("tv", id);
      const all: EpisodeDetails[] = [];
      for (const { number } of details?.seasons ?? [])
        all.push(...((await season(number))?.episodes ?? []));
      return all;
    };

    for (const row of seasons) {
      if (this.outage) return;
      this.signal.throwIfAborted();
      const episodes = this.db
        .all<ItemRow>("select * from item where parent_id = ? and kind = 'episode'", [row.id])
        .filter((episode) => dueIds.has(episode.id));
      const seasonDue = dueIds.has(row.id);
      const items = seasonDue ? [row, ...episodes] : episodes;
      if (items.length === 0) continue;
      const changes: Change[] = [];
      const ok = await this.attempt(items, async () => {
        const number = row.season_number;
        const details = number === null ? null : await season(number);
        this.signal.throwIfAborted();
        if (seasonDue) changes.push(await this.seasonChange(row, details));
        const pool =
          number === null || episodes.some((one) => one.episode_number === null)
            ? await everyEpisode()
            : [];
        // LimitedFetch bounds how many of these really run at once.
        changes.push(
          ...(await allDone(
            episodes.map((episode) => this.episodeChange(id, episode, details, pool)),
          )),
        );
      });
      if (ok) this.apply(changes.map((change) => ({ ...change, basis })));
    }
  }

  private async seasonChange(row: ItemRow, details: SeasonDetails | null): Promise<Change> {
    if (!details) {
      return isSettled(row)
        ? { kind: "unchanged", item: row }
        : { kind: "review", item: row, reason: "TMDB does not have this season.", candidates: [] };
    }
    return {
      kind: "match",
      item: row,
      fields: {
        // "Season 2" here and "Series 2" there would only look untidy.
        ...(/^\p{L}+ \d+$/u.test(details.title) ? {} : { title: details.title }),
        overview: details.overview,
        air_date: details.airDate,
        year: details.airDate === null ? row.year : Number(details.airDate.slice(0, 4)),
        tmdb_id: details.id,
      },
      genres: null,
      studios: null,
      search: null,
      trailer: undefined,
      images: await this.prepare(row, details.poster ? [details.poster] : []),
    };
  }

  private async episodeChange(
    showId: number,
    item: ItemRow,
    season: SeasonDetails | null,
    everywhere: EpisodeDetails[],
  ): Promise<Change> {
    const episodes = season?.episodes ?? [];
    let found: EpisodeDetails;
    if (isSettled(item)) {
      const same = [...episodes, ...everywhere].find((one) => one.id === item.tmdb_id);
      if (!same) return { kind: "unchanged", item };
      found = same;
    } else {
      const wanted = this.wantedEpisode(item);
      const decision =
        item.season_number !== null && wanted.episode !== null
          ? matchNumbered({ ...wanted, episode: wanted.episode }, episodes)
          : matchByTitle(wanted, everywhere);
      if (decision.accepted === null) return { ...decision, kind: "review", item };
      found = decision.accepted;
    }
    const imdbId = await this.provider.episodeImdbId(showId, found.season, found.episode);
    return {
      kind: "match",
      item,
      fields: {
        ...(found.title === "" || isPlaceholder(found.title, found.episode)
          ? {}
          : { title: found.title }),
        overview: found.overview,
        air_date: found.airDate ?? item.air_date,
        runtime_ms: found.runtimeMinutes === null ? null : found.runtimeMinutes * 60_000,
        tmdb_id: found.id,
        imdb_id: imdbId,
      },
      genres: null,
      studios: null,
      search: null,
      trailer: undefined,
      images: await this.prepare(
        item,
        found.stillPath === null ? [] : [{ kind: "still", path: found.stillPath, language: null }],
      ),
    };
  }

  private wantedEpisode(item: ItemRow): WantedEpisode {
    const assets = this.assets(item.id);
    const single = assets.find((asset) => asset.items === 1);
    return {
      season: item.season_number,
      episode: item.episode_number,
      title: fileTitle(assets),
      airDate: item.air_date,
      runtimeMinutes: single?.duration_ms == null ? null : single.duration_ms / 60_000,
    };
  }

  // Saving

  private flush(): void {
    const changes = this.batch;
    this.batch = [];
    this.apply(changes);
  }

  /** Saves changes as one library revision, so apps refresh once for all of them. */
  private apply(changes: Change[]): void {
    this.signal.throwIfAborted();
    if (changes.length === 0) return;
    this.db.transaction(() => {
      let revision: number | null = null;
      for (const change of changes) {
        // A scan or a manager may have changed the item while it was being looked up.
        const row = this.item(change.item.id);
        if (
          !row ||
          row.match_status !== change.item.match_status ||
          row.title !== change.item.title ||
          row.tmdb_id !== change.item.tmdb_id ||
          (change.basis && this.item(change.basis.showRowId)?.tmdb_id !== change.basis.showId)
        ) {
          continue;
        }
        const visible =
          change.kind === "match"
            ? this.saveMatch(row, change)
            : change.kind === "review"
              ? this.saveReview(row, change)
              : change.kind === "facts"
                ? this.saveFacts(row, change)
                : this.saveChecked(row);
        if (visible) {
          revision ??= this.db.nextRevision();
          this.catalogue.touch(row.id, revision);
        }
      }
    });
  }

  private saveChecked(row: ItemRow): boolean {
    this.db.run(
      "update item set enriched_at = ?, enrich_attempts = 0, enrich_next_attempt_at = null where id = ?",
      [this.options.now(), row.id],
    );
    return false;
  }

  private saveFacts(row: ItemRow, facts: Facts): boolean {
    const { columns, values } = this.changed(row, facts.fields);
    let visible = columns.length > 0;
    columns.push("facts_at = ?", "enrich_attempts = 0", "enrich_next_attempt_at = null");
    this.db.run(`update item set ${columns.join(", ")} where id = ?`, [
      ...values,
      this.options.now(),
      row.id,
    ]);
    for (const image of facts.images) visible = this.images.save(row.id, image) || visible;
    if (facts.studios !== null) visible = this.studios.save(row.id, facts.studios) || visible;
    if (facts.search !== null) saveSearchFacts(this.db, row.id, facts.search, this.options.now());
    return visible;
  }

  /** The columns that are different now. */
  private changed(
    row: ItemRow,
    fields: Fields,
  ): { columns: string[]; values: (string | number | null)[] } {
    const columns: string[] = [];
    const values: (string | number | null)[] = [];
    for (const [column, value] of Object.entries(fields) as [
      keyof Fields,
      string | number | null,
    ][]) {
      if (value === row[column]) continue;
      // A summary or id that went missing at the provider is better kept than lost.
      if (value === null && row.enriched_at !== null) continue;
      columns.push(`${column} = ?`);
      values.push(value);
      if (column === "title") {
        columns.push("sort_title = ?");
        values.push(sortTitle(String(value)));
      }
    }
    return { columns, values };
  }

  private saveReview(row: ItemRow, review: Review): boolean {
    const now = this.options.now();
    this.db.run(
      `update item set match_status = 'needs_review', candidates_json = ?, enrich_attempts = 0,
         enrich_next_attempt_at = ? where id = ?`,
      [
        JSON.stringify({
          provider: "tmdb",
          searchedAt: now,
          reason: review.reason,
          candidates: review.candidates,
        }),
        now + this.options.reviewRetryMs,
        row.id,
      ],
    );
    this.options.summary.needsReview += 1;
    return row.match_status !== "needs_review";
  }

  private saveMatch(row: ItemRow, match: Match): boolean {
    const locked = row.match_status === "locked";
    const { columns, values } = this.changed(row, match.fields);
    let visible = columns.length > 0;
    if (!locked) {
      columns.push("match_status = 'matched'", "candidates_json = null");
      visible ||= row.match_status !== "matched";
    }
    const metadata = (JSON.parse(row.metadata_json ?? "{}") ?? {}) as Record<string, unknown>;
    if (
      match.trailer !== undefined &&
      JSON.stringify(metadata["trailer"] ?? null) !== JSON.stringify(match.trailer)
    ) {
      columns.push("metadata_json = ?");
      values.push(JSON.stringify({ ...metadata, trailer: match.trailer }));
      visible = true;
    }
    const now = this.options.now();
    columns.push("enriched_at = ?", "enrich_attempts = 0", "enrich_next_attempt_at = null");
    values.push(now);
    if (row.kind === "movie" || row.kind === "show") {
      columns.push("facts_at = ?");
      values.push(now);
    }
    values.push(row.id);
    this.db.run(`update item set ${columns.join(", ")} where id = ?`, values);

    if (match.genres !== null) {
      visible = this.saveGenres(row.id, match.genres) || visible;
    }
    if (match.studios !== null) {
      visible = this.studios.save(row.id, match.studios) || visible;
    }
    if (match.search !== null) saveSearchFacts(this.db, row.id, match.search, now);
    for (const image of match.images) {
      visible = this.images.save(row.id, image) || visible;
    }
    this.options.summary.matched += 1;
    return visible;
  }

  private saveGenres(itemId: string, genres: string[]): boolean {
    const wanted = [...new Set(genres)].sort();
    const before = this.db
      .all<{ name: string }>(
        "select genre.name from item_genre join genre on genre.id = item_genre.genre_id where item_id = ?",
        [itemId],
      )
      .map((row) => row.name)
      .sort();
    if (wanted.length === 0) return false;
    if (JSON.stringify(wanted) === JSON.stringify(before)) return false;
    this.db.run("delete from item_genre where item_id = ?", [itemId]);
    for (const name of wanted) {
      this.db.run("insert into genre (name) values (?) on conflict (name) do nothing", [name]);
      this.db.run(
        "insert into item_genre (item_id, genre_id) select ?, id from genre where name = ?",
        [itemId, name],
      );
    }
    return true;
  }
}

/** Already matched, by Lobby or by a manager: refreshed by id, never matched again. */
function isSettled(item: ItemRow): item is ItemRow & { tmdb_id: number } {
  return (
    item.tmdb_id !== null && (item.match_status === "matched" || item.match_status === "locked")
  );
}

/** Waits for every promise, so nothing runs on unseen, then fails if any of them did. */
async function allDone<T>(promises: Promise<T>[]): Promise<T[]> {
  const results = await Promise.allSettled(promises);
  return results.map((result) => {
    if (result.status === "rejected") throw result.reason;
    return result.value;
  });
}

function readParsed(asset: AssetRow): ParsedMedia | null {
  return asset.parsed_json === null ? null : (JSON.parse(asset.parsed_json) as ParsedMedia);
}

/** The episode title in the file name, unless the file holds several episodes. */
function fileTitle(assets: AssetRow[]): string | null {
  for (const asset of assets) {
    if (asset.items > 1) continue;
    const title = readParsed(asset)?.episodeTitle;
    if (title != null) return title;
  }
  return null;
}

/** One running time per copy of the film; a film split over discs counts as a whole. */
function filmRuntimes(assets: AssetRow[]): number[] {
  const parts = new Map<number, number>();
  const whole: number[] = [];
  for (const { part, duration_ms: duration } of assets) {
    if (duration === null) continue;
    if (part === null) whole.push(duration / 60_000);
    else parts.set(part, Math.max(parts.get(part) ?? 0, duration / 60_000));
  }
  const joined = [...parts.values()].reduce((sum, one) => sum + one, 0);
  return joined > 0 ? [...whole, joined] : whole;
}

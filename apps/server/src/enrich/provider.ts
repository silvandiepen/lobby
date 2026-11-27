// SPDX-License-Identifier: MPL-2.0
/**
 * What Lobby asks of a metadata provider, in Lobby's own words. Nothing outside
 * the adapter sees the provider's response shapes.
 */
import type { Studio } from "../library/studios.ts";

export type TitleType = "movie" | "tv";
export type ArtworkKind = "poster" | "backdrop" | "still" | "logo";

export interface SearchHit {
  type: TitleType;
  id: number;
  title: string;
  originalTitle: string;
  year: number | null;
  overview: string | null;
  posterPath: string | null;
}

export interface SearchResult {
  hits: SearchHit[];
  /** False when the provider has more results than were read. */
  complete: boolean;
}

export interface RemoteImage {
  kind: ArtworkKind;
  path: string;
  language: string | null;
  /** Wider than the provider's ordinary size, and shown wide: get more of it. */
  large?: boolean;
  /** Also when it is not transparent: a manager saw it and chose it. */
  anyShape?: boolean;
}

/** A picture to choose from. */
export interface ImageOption extends RemoteImage {
  width: number | null;
  height: number | null;
}

/** What to list pictures of. */
export interface ImageOwner {
  type: TitleType;
  id: number;
  season?: number;
  episode?: number;
}

export interface Trailer {
  provider: "youtube";
  key: string;
}

export interface TitleDetails {
  type: TitleType;
  id: number;
  imdbId: string | null;
  title: string;
  originalTitle: string;
  /** Other names it is known by, in any language. */
  aliases: string[];
  year: number | null;
  /** A film's release date, or the day a show first aired. */
  date: string | null;
  overview: string | null;
  runtimeMinutes: number | null;
  genres: string[];
  trailer: Trailer | null;
  images: RemoteImage[];
  /** For a show: its seasons. */
  seasons: { number: number; episodes: number }[];
  /** How many people rated it: next to nothing for an obscure namesake. */
  votes: number;
  /** The provider's average rating, 0 to 10; null when nobody rated it. */
  rating: number | null;
  /** The provider's measure of how much it is looked at now. No upper end. */
  popularity: number | null;
  tagline: string | null;
  posterPath: string | null;
  /** The companies that made it, and for a show the networks that showed it. */
  studios: Studio[];
  /** Who played in it and made it, the most important first. Empty when the provider has none. */
  credits: Credit[];
  /** The collection a film belongs to ("Toy Story Collection"). */
  collection: { id: number; name: string } | null;
}

export type CreditRole = "cast" | "director" | "writer" | "creator";

/** A person in a title, as the provider knows them. */
export interface Credit {
  personId: number;
  name: string;
  role: CreditRole;
  /** Whom they played; cast only. */
  character: string | null;
  /** The provider's order within the role: 0 is the lead. */
  order: number;
  profilePath: string | null;
}

export interface EpisodeDetails {
  id: number;
  season: number;
  episode: number;
  title: string;
  overview: string | null;
  airDate: string | null;
  runtimeMinutes: number | null;
  stillPath: string | null;
}

export interface SeasonDetails {
  id: number;
  season: number;
  title: string;
  overview: string | null;
  airDate: string | null;
  poster: RemoteImage | null;
  episodes: EpisodeDetails[];
}

export interface StudioLogo {
  name: string;
  country: string | null;
  path: string;
}

export type ImageSize = "preview" | "normal" | "original";

export interface MetadataProvider {
  search(type: TitleType, title: string, year: number | null): Promise<SearchResult>;
  /** Studios with a logo. */
  searchLogos(name: string): Promise<StudioLogo[]>;
  /** What an IMDb id stands for. An episode's id answers with its show. */
  findByImdb(imdbId: string): Promise<{ type: TitleType; id: number }[]>;
  details(type: TitleType, id: number): Promise<TitleDetails | null>;
  season(showId: number, season: number): Promise<SeasonDetails | null>;
  episodeImdbId(showId: number, season: number, episode: number): Promise<string | null>;
  /** A few dozen pictures at most. */
  imageOptions(owner: ImageOwner, kind: ArtworkKind): Promise<ImageOption[]>;
  /** The bytes of the JPEG, or of the PNG for a logo; null when the provider does not have it. */
  image(kind: ArtworkKind, path: string, size?: ImageSize): Promise<Uint8Array<ArrayBuffer> | null>;
}

/** The provider cannot be used right now: it is unreachable, overloaded or refuses the key. */
export class ProviderUnavailable extends Error {
  readonly keyRefused: boolean;
  constructor(message: string, keyRefused = false) {
    super(message);
    this.name = "ProviderUnavailable";
    this.keyRefused = keyRefused;
  }
}

/** The provider answered one request with something that cannot be used. */
export class ProviderError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ProviderError";
  }
}

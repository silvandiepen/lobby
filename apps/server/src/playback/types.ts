// SPDX-License-Identifier: MPL-2.0
/**
 * What the playback module needs to know about a file. The catalogue has all of it;
 * the HTTP layer maps its rows to this shape in the injected asset lookup.
 */
export interface PlaybackTrack {
  /** The stream's index in the source file, as ffprobe reports it. */
  index: number;
  kind: "video" | "audio" | "subtitle";
  codec: string;
  /** The container's sample entry, `hvc1` or `hev1` say; "" when it has none, null when not read. */
  codecTag?: string | null;
  language: string | null;
  title: string | null;
  channels: number | null;
  isDefault: boolean;
  isForced: boolean;
}

export interface PlaybackSubtitle {
  /** The id the apps use in the subtitle URL. Letters, digits, `_` and `-` only. */
  id: string;
  /** An embedded track is read from the asset by stream index, a sidecar from its own file. */
  source: { kind: "embedded"; streamIndex: number } | { kind: "sidecar"; path: string };
  codec: string;
  language: string | null;
  title: string | null;
  isForced: boolean;
}

export interface PlaybackAsset {
  id: string;
  /** Changes when the file's bytes change. Prepared copies of another revision are stale. */
  revision: string;
  /** Absolute path of the original, already checked to lie inside its library folder. */
  path: string;
  sizeBytes: number;
  durationMs: number | null;
  /** False when the drive is not mounted. */
  available: boolean;
  playability: "direct" | "remux" | "transcode" | "unsupported";
  playabilityReason: string | null;
  tracks: PlaybackTrack[];
  subtitles: PlaybackSubtitle[];
}

/** One sound track of a prepared copy, in the order it has in the prepared file. */
export interface PreparedAudio {
  /** The track's stream index in the original, which is `AudioTrack.index` in the catalogue. */
  index: number;
  /** The codec in the prepared file: the original's when copied; `ac3` (surround) or `aac` when converted. */
  codec: string;
  converted: boolean;
  language: string | null;
  title: string | null;
  channels: number | null;
  isDefault: boolean;
}

export type PreparationState = "queued" | "preparing" | "ready" | "failed";

export interface Preparation {
  assetId: string;
  revision: string;
  state: PreparationState;
  /** 0 to 1. */
  progress: number;
  /** How much of the film, from its start, can be played and seeked already. */
  preparedMs: number;
  durationMs: number | null;
  /** True once enough is written for the stream to start without stalling. */
  streamable: boolean;
  /** True when the picture is converted to H.264, which is much slower than copying it. */
  videoConverted: boolean;
  /**
   * How fast the copy is being written, as a multiple of playback speed: 4 means
   * four minutes of film per minute. Null unless `state` is `preparing`.
   */
  speed: number | null;
  /** Size of `media.mp4`, the file a device downloads. Final once `state` is `ready`. */
  sizeBytes: number;
  audio: PreparedAudio[];
  /** A sentence for the viewer when `state` is `failed`. */
  error: string | null;
}

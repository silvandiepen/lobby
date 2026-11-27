// SPDX-License-Identifier: MPL-2.0
/** What a stream playlist written by ffmpeg says so far. */
export interface StreamPlaylistInfo {
  segments: number;
  /** Total length of the listed segments. */
  durationMs: number;
  /** True once ffmpeg wrote the end marker: the playlist is complete and fully seekable. */
  ended: boolean;
}

export function readStreamPlaylist(text: string): StreamPlaylistInfo {
  let segments = 0;
  let seconds = 0;
  for (const match of text.matchAll(/^#EXTINF:([0-9.]+)/gm)) {
    segments += 1;
    seconds += Number(match[1]);
  }
  return {
    segments,
    durationMs: Math.round(seconds * 1000),
    ended: /^#EXT-X-ENDLIST/m.test(text),
  };
}

export interface SubtitleRendition {
  name: string;
  /** BCP 47, e.g. "en". Null when the language is unknown. */
  language: string | null;
  isForced: boolean;
  /** URI of the rendition's playlist, relative to the master playlist. */
  uri: string;
}

export interface AudioRendition {
  name: string;
  language: string | null;
  /** Null for the sound track that is inside the stream's own segments. */
  uri: string | null;
}

export interface MasterPlaylistInput {
  /** Every sound track, the stream's own first. Left out of the playlist when there is only one. */
  audio: AudioRendition[];
  /** Peak bits per second. An estimate is fine: there is one variant, so nothing is chosen by it. */
  bandwidth: number;
  streamUri: string;
  subtitles: SubtitleRendition[];
}

function quote(value: string): string {
  // A quoted-string in a playlist cannot hold a quote or a line break.
  return `"${value.replace(/["\r\n]/g, " ").trim()}"`;
}

/**
 * The master playlist: one variant (the copy), one audio rendition per sound track
 * when there are several, and one subtitle rendition per text track. CODECS is left out on purpose: AVPlayer reads the codecs from the
 * initialisation segment, and a wrong string is worse than none.
 */
export function masterPlaylist(input: MasterPlaylistInput): string {
  const lines = [
    "#EXTM3U",
    "#EXT-X-VERSION:7",
    "#EXT-X-INDEPENDENT-SEGMENTS",
    // While ffmpeg is still writing, the stream playlist has no end marker and AVPlayer
    // would start at its newest segment, as for a live broadcast. This starts it at the beginning.
    "#EXT-X-START:TIME-OFFSET=0",
  ];
  const unique = (taken: Set<string>, wanted: string): string => {
    // Names must be unique inside a group.
    let name = wanted;
    for (let count = 2; taken.has(name); count += 1) name = `${wanted} (${count})`;
    taken.add(name);
    return name;
  };

  const audio = input.audio.length > 1 ? input.audio : [];
  const audioNames = new Set<string>();
  audio.forEach((rendition, position) => {
    const attributes = [
      "TYPE=AUDIO",
      'GROUP-ID="audio"',
      `NAME=${quote(unique(audioNames, rendition.name))}`,
      ...(rendition.language ? [`LANGUAGE=${quote(rendition.language)}`] : []),
      `DEFAULT=${position === 0 ? "YES" : "NO"}`,
      "AUTOSELECT=YES",
      ...(rendition.uri ? [`URI=${quote(rendition.uri)}`] : []),
    ];
    lines.push(`#EXT-X-MEDIA:${attributes.join(",")}`);
  });

  const subtitleNames = new Set<string>();
  for (const subtitle of input.subtitles) {
    const attributes = [
      "TYPE=SUBTITLES",
      'GROUP-ID="subs"',
      `NAME=${quote(unique(subtitleNames, subtitle.name))}`,
      ...(subtitle.language ? [`LANGUAGE=${quote(subtitle.language)}`] : []),
      "DEFAULT=NO",
      // A forced track holds only the lines for foreign speech, so the player may pick it itself.
      `AUTOSELECT=${subtitle.isForced ? "YES" : "NO"}`,
      `FORCED=${subtitle.isForced ? "YES" : "NO"}`,
      `URI=${quote(subtitle.uri)}`,
    ];
    lines.push(`#EXT-X-MEDIA:${attributes.join(",")}`);
  }
  const stream = [
    `BANDWIDTH=${Math.max(1, Math.round(input.bandwidth))}`,
    // Without this AVPlayer offers a closed-captions option that holds nothing.
    "CLOSED-CAPTIONS=NONE",
    ...(audio.length > 0 ? ['AUDIO="audio"'] : []),
    ...(input.subtitles.length > 0 ? ['SUBTITLES="subs"'] : []),
  ];
  lines.push(`#EXT-X-STREAM-INF:${stream.join(",")}`, input.streamUri);
  return `${lines.join("\n")}\n`;
}

/** A subtitle rendition's playlist: the whole WebVTT file as one segment. */
export function subtitlePlaylist(durationMs: number, vttUri: string): string {
  const seconds = Math.max(1, Math.ceil(durationMs / 1000));
  return [
    "#EXTM3U",
    "#EXT-X-VERSION:7",
    `#EXT-X-TARGETDURATION:${seconds}`,
    "#EXT-X-MEDIA-SEQUENCE:0",
    "#EXT-X-PLAYLIST-TYPE:VOD",
    `#EXTINF:${seconds.toFixed(3)},`,
    vttUri,
    "#EXT-X-ENDLIST",
    "",
  ].join("\n");
}

// ISO 639-2 bibliographic codes, which Matroska uses and BCP 47 does not know.
const BIBLIOGRAPHIC: Record<string, string> = {
  alb: "sq",
  arm: "hy",
  baq: "eu",
  bur: "my",
  chi: "zh",
  cze: "cs",
  dut: "nl",
  fre: "fr",
  geo: "ka",
  ger: "de",
  gre: "el",
  ice: "is",
  mac: "mk",
  mao: "mi",
  may: "ms",
  per: "fa",
  rum: "ro",
  slo: "sk",
  tib: "bo",
  wel: "cy",
};

/** Turns a track's language tag ("eng", "dut", "pt-BR") into BCP 47, or null when it is not one. */
export function languageTag(language: string | null): string | null {
  if (language === null) return null;
  const lower = language.trim().toLowerCase();
  if (lower === "" || lower === "und") return null;
  try {
    // Canonical form also maps three-letter codes to two-letter ones ("eng" to "en").
    return Intl.getCanonicalLocales(BIBLIOGRAPHIC[lower] ?? language.trim())[0] ?? null;
  } catch {
    return null;
  }
}

/** A name for a track in the player's menu: its title, else its language in English. */
export function trackName(title: string | null, language: string | null, fallback: string): string {
  if (title !== null && title.trim() !== "") return title.trim();
  const tag = languageTag(language);
  if (tag === null) return fallback;
  return new Intl.DisplayNames(["en"], { type: "language" }).of(tag) ?? fallback;
}

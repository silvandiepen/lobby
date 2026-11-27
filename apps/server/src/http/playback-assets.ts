// SPDX-License-Identifier: MPL-2.0
import { realpath, stat } from "node:fs/promises";
import { join, sep } from "node:path";
import type { Database } from "../db/database.ts";
import { sidecarCodec } from "../library/probe.ts";
import type { VideoTags } from "../library/video-tags.ts";
import type { PlaybackAsset, PlaybackSubtitle, PlaybackTrack } from "../playback/index.ts";

interface AssetRow {
  id: string;
  rel_path: string;
  size: number;
  revision: string;
  duration_ms: number | null;
  playability: PlaybackAsset["playability"] | null;
  playability_reason: string | null;
  available: number;
  source_path: string;
  source_available: number;
}

interface TrackRow {
  idx: number;
  kind: PlaybackTrack["kind"];
  codec: string;
  codec_tag: string | null;
  language: string | null;
  title: string | null;
  channels: number | null;
  is_default: number;
  is_forced: number;
}

interface SidecarRow {
  id: string;
  rel_path: string;
  format: string;
  language: string | null;
  is_forced: number;
}

/** The real path of an indexed file, or null when it cannot be read or lies outside its library folder. */
async function fileInside(root: string, relPath: string): Promise<string | null> {
  try {
    const realRoot = await realpath(root);
    const path = await realpath(join(root, relPath));
    if (!path.startsWith(realRoot + sep)) return null;
    return (await stat(path)).isFile() ? path : null;
  } catch {
    return null;
  }
}

/**
 * Maps a catalogue asset to what the playback module needs. Subtitle ids are the
 * ones the library gives the apps: `t<stream index>` for a track inside the file,
 * `s<sidecar id>` for a file beside it.
 */
export function createAssetLookup(
  db: Database,
  tags?: VideoTags,
): (assetId: string) => Promise<PlaybackAsset | null> {
  return async (assetId) => {
    // Whether an older HEVC file plays as it is depends on its label, which is read first.
    await tags?.ensure(assetId);
    const asset = db.get<AssetRow>(
      `select asset.id, asset.rel_path, asset.size, asset.revision, asset.duration_ms,
         asset.playability, asset.playability_reason, asset.available,
         source.path as source_path, source.available as source_available
       from asset join source on source.id = asset.source_id
       where asset.id = ? and asset.state = 'probed'`,
      [assetId],
    );
    if (!asset) return null;

    const mounted = asset.available === 1 && asset.source_available === 1;
    const path = mounted ? await fileInside(asset.source_path, asset.rel_path) : null;

    const tracks = db
      .all<TrackRow>(
        "select idx, kind, codec, codec_tag, language, title, channels, is_default, is_forced from track where asset_id = ? order by idx",
        [assetId],
      )
      .map((track): PlaybackTrack => ({
        index: track.idx,
        kind: track.kind,
        codec: track.codec,
        codecTag: track.codec_tag,
        language: track.language,
        title: track.title,
        channels: track.channels,
        isDefault: track.is_default === 1,
        isForced: track.is_forced === 1,
      }));

    const subtitles: PlaybackSubtitle[] = tracks
      .filter((track) => track.kind === "subtitle")
      .map((track) => ({
        id: `t${String(track.index)}`,
        source: { kind: "embedded", streamIndex: track.index },
        codec: track.codec,
        language: track.language,
        title: track.title,
        isForced: track.isForced,
      }));
    for (const sidecar of db.all<SidecarRow>(
      "select id, rel_path, format, language, is_forced from sidecar where asset_id = ? order by rel_path",
      [assetId],
    )) {
      const sidecarPath = mounted ? await fileInside(asset.source_path, sidecar.rel_path) : null;
      subtitles.push({
        id: `s${sidecar.id}`,
        // An unreadable sidecar keeps its place in the list; reading it then fails as unavailable.
        source: { kind: "sidecar", path: sidecarPath ?? join(asset.source_path, sidecar.rel_path) },
        codec: sidecarCodec(sidecar.format),
        language: sidecar.language,
        title: null,
        isForced: sidecar.is_forced === 1,
      });
    }

    return {
      id: asset.id,
      revision: asset.revision,
      path: path ?? join(asset.source_path, asset.rel_path),
      sizeBytes: asset.size,
      durationMs: asset.duration_ms,
      available: path !== null,
      playability: asset.playability ?? "unsupported",
      playabilityReason: asset.playability_reason,
      tracks,
      subtitles,
    };
  };
}

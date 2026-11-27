# Converting old files and replacing the originals

Some files in a library cannot be played by Apple devices as they are: AVI files with MPEG-4 Part 2 video, and AV1 files. Lobby can convert them while someone waits ([playback.md](playback.md)), but that costs a small server minutes per film every time the copy has left the cache. This page is about the lasting answer: convert each file once, in the background, and put the result in the original's place, so the library itself becomes playable.

For this Lobby gets its own folder on the media drive, and a converted file replaces the original only once it is proven good.

The API is in [api.md](api.md) under "Converting files". The code is `apps/server/src/conversion/`. **It is built and tested on a Mac with generated files only. It has not yet been verified on a Raspberry Pi or on real library files.** It is off until `conversion.dir` is set, in the config or by a manager in the app (Settings → Server → Converting; see [api.md](api.md#server-settings)). The hours and choices change live there; Lobby's folder needs a restart, and once it holds originals the app refuses another one.

## What it does, in order

1. A manager puts a title, a season, a show, a category or "everything old" into a **queue**. Every file is judged; what will not be converted is listed as skipped, with the reason.
2. A file is **converted** into a staging folder inside Lobby's folder on the drive. By the server itself (one file at a time, niceness 19, only inside the hours set for it and only while nobody plays or downloads anything), or by a Mac that takes the job, fetches the original and sends the result back.
3. The server **proves** the result, whoever made it. Every check below is required.
4. The result **takes the original's place**: the original is renamed into `originals/` in Lobby's folder, the new file is renamed to the original's name with the extension `.mp4`. Two renames on the same drive, written to a journal first. Nothing is overwritten and nothing is deleted.
5. The catalogue keeps the title: same item, same file id, a new revision. Progress, edits, the match, artwork and wanted lists are untouched; devices that hold the old file fetch the new one.
6. A manager can **undo** a replacement, and can **purge** a kept original. Nothing is ever purged by itself.

## Which files, and how

| Kind | From | To | Who |
| --- | --- | --- | --- |
| `h264` | MPEG-4 Part 2 or MS-MPEG-4 v3 video (the old AVI films) | H.264, `libx264 -preset veryfast -crf 21`, as measured in [playback.md](playback.md). A Mac may use VideoToolbox instead. | Server or Mac |
| `hevc` | AV1 | HEVC (`hvc1`) | A Mac only: the Pi manages 1.4 times playback speed at 1080p |
| `repackage` | MKV whose picture Apple devices already play, or an MP4 whose HEVC is labelled `hev1` (relabelled `hvc1`: see docs/playback.md) | The same picture and sound, untouched, in MP4 | Server or Mac. **Off unless `conversion.repackage` is true.** |

Every sound track is kept, in the file's order, with its language: copied when it is AAC, AC-3 or E-AC-3, otherwise converted (surround to AC-3, stereo to AAC). Text subtitles inside the file are kept as text (`mov_text`; the styling of ASS subtitles is lost). Chapters and tags are kept. The file is an ordinary MP4 with its index at the front (`-movflags +faststart`), not the fragmented kind the streaming copies are.

Not kept: files attached inside an MKV (fonts for styled subtitles, a cover picture). A `repackage` is only done when nothing else has to change: a file whose sound would have to be converted (DTS, Opus) is skipped.

Subtitle files beside a film are not touched. The new file has the same base name, so they still belong to it.

## Files that are left alone

A file is skipped, with the reason shown, when it is hard to judge:

- it plays as it is, or its video is something Lobby does not convert;
- it has subtitles stored as pictures (PGS, DVD), which MP4 cannot hold: such a file is never replaced;
- it is one part of a film kept in several files, or it holds several episodes;
- it has a second name somewhere (a hard link);
- it is in a download folder (`Downloads`, `Torrents`, `incomplete`, `seeding`, and the like), or a download program's file sits beside it (`.torrent`, `.!qB`, `.part`, `.aria2`, `.crdownload`, `.nzb`);
- an MP4 with the same name is already beside it;
- it is not on the drive Lobby's folder is on.

A file waits, without being skipped, while: the drive is not connected, there is too little free space (1.5 times its size plus `conversion.minFreeGb`), it changed since the library last read it, or another program has it open. The last check works on Linux for programs of the same user only: **Plex runs as another user, and Lobby cannot see what Plex has open.** On a Mac it finds nothing (there is no `/proc`), and in a container only the container's own programs: keep `hours` to a time when nothing copies into the library ([release.md](release.md#macos-what-differs)).

A title is not replaced within ten minutes of anyone playing or fetching it.

## The proof

| Check | Passes when |
| --- | --- |
| The original is unchanged | size, date and fingerprint are what they were when the job began |
| It can be read | ffprobe reads it, it is an MP4, and the catalogue's own rules call it playable as it is |
| Length | within 1 s of the original, or 0.2% for a long film |
| Picture | one picture track, of the codec asked for, the original's size (one row or column less for an odd size) |
| Sound | as many tracks as the original, the same languages in the same order, the channels asked for |
| Subtitles | every text track of the original is there, with its language |
| Chapters | as many as the original |
| Size | between 0.05 and 3 times the original's |
| It plays through | ffmpeg decodes every picture and every sound track to the end without one error |
| The same pictures | SSIM over 8 samples of 4 s spread over the film: mean at least 0.95, no sample below 0.85 |
| No drift | the gap between the end of sound and the end of picture differs from the original's by at most 250 ms |

The first failure ends the proof, the job fails with a sentence, and what was converted is deleted. The original is not touched. The numbers of every proof are kept with the job.

### Where the SSIM thresholds come from

SSIM is 1 for identical pictures. What was measured:

| Case | SSIM |
| --- | --- |
| Two real AVI clips converted with `veryfast`, CRF 21, on the Pi (150 s each, [playback.md](playback.md)) | 0.981 and 0.989 |
| One real AVI on a Mac, 5 minutes: VideoToolbox, and `libx264 veryfast` CRF 21 | 0.988, 0.986 |
| Generated test film, right conversion | 0.982 to 0.987 |
| A generated film that is as hard to encode as a picture gets (a fractal zoom), right conversion | 0.921 |
| The same, one frame late | 0.878 |
| The same, five frames late / one second late | 0.773 / 0.616 |
| The same, converted far too coarsely (CRF 32 / CRF 40) | 0.911 / 0.869 |
| Another film altogether | 0.456 |
| The first second of an AVI against its conversion (the first frames do not line up) | 0.487 |

So a wrong, shifted or damaged picture is far below 0.85, and a right conversion of ordinary film is at 0.98. The mean of 0.95 also refuses a conversion made too coarsely, which matters for results a Mac sends in with its own encoder. It will refuse a right conversion of an unusually hard film too (0.92 above): that film then simply stays as it is. Samples keep away from the first and last moments of the film, because of the last line of the table.

These are four real measurements and a handful of generated ones. **The thresholds have not met a real library yet.** The first real runs should be looked at in the queue (`proof` on each job) before a long list is let loose.

## Replacing, and what a crash leaves

Lobby's folder holds:

| | |
| --- | --- |
| `lobby-folder.json` | A marker with an id the catalogue knows. Only a folder with this marker is used. |
| `staging/` | Files being converted or uploaded. Emptied when a job ends. |
| `journal/` | One small file per replacement in progress. Normally empty. |
| `originals/<date>/<library folder>/<path>` | The originals that were replaced, with their own date, and beside each a `.lobby.json` saying where it came from and what the proof measured. |
| `undone/<date>/…` | Converted files set aside by an undo. |

A replacement is: write the journal entry and flush it; rename the original into `originals/`; rename the staged file into the library; write the manifest and the database; remove the journal entry. Each rename is refused when something is already at the destination, and each is followed by a flush of the folders.

When the server starts, and whenever the drive comes back, the journal is read before anything else, and before the library is scanned. Each entry is judged by where the files are: when the remaining renames can still be made they are made; when the converted file is gone, or another file is in the way, the renames that were made are taken back and the job fails with that reason; when files are in two places at once, nothing is touched and the queue stops until a person has looked (`needsAttention` in the status).

Tests stop a replacement after each step (the journal entry, the first rename, the second, the database) and start a fresh service: every time the original's bytes exist exactly once, untouched, and the replacement is completed. They also pull the "drive" out after the first rename: nothing is created at the empty mount point, the job waits, and it completes when the drive is back.

**An unplugged drive leaves an empty folder where it was mounted.** A program that creates its folders there writes to the system disk. Lobby's folder is therefore only created on a volume the library is known to be on, and afterwards only a folder with the right marker counts as the drive being there.

## Undo and purge

- **Undo** puts the original back under its name and sets the converted file aside in `undone/`. It is refused when the converted file was changed or moved since, when a file is again where the original was, or while someone watches the title.
- **Purge** deletes what Lobby keeps for one replacement: the original, or after an undo the converted file that was set aside. It needs the words `"delete for good"` in the request. There is no purge of everything, and nothing is purged by time.

Until originals are purged the drive holds both: converting all AVI films needs about as much extra space as they take now (124 GB, less what H.264 saves).

## Plex and other programs on the same folders

- Plex sees a file disappear and a file with the same name and another extension appear. It normally treats that as the same title with new media and keeps watch state, but it analyses the new file again, and "optimised versions" or a sync of the old file are made again. Not tested here.
- **Lobby's folder must not be inside a folder Plex indexes**, or Plex shows every kept original as a second copy. When the Plex libraries are subfolders of the drive, so a folder at the drive's root is outside them.
- A program that holds the original open while it is renamed (Plex streaming it, Samba serving it to a Mac) keeps playing: a rename does not disturb an open file. Lobby cannot see such use (see above), so a replacement can happen while Plex plays the film; the next play in Plex opens the new file.
- Anything that refers to the file by its full name (a playlist, a download program) loses it. That is why download folders are skipped.

## Not verified

- **Not yet verified on a Raspberry Pi, on exFAT, or on a real file.** exFAT has no hard links and no ownership; the replacement uses only rename, which exFAT has, but that is reasoning, not a test.
- Whether flushing a folder does anything on exFAT. The code tolerates a refusal.
- The proof on real films: thresholds, the drift check on AVI files with variable-rate MP3, the time the checks take (a full decode of every converted film; minutes each on the Pi).
- A Mac worker. The API is tested with a stand-in that fetches, converts with ffmpeg and uploads; the Mac app does not exist yet.
- AV1 to HEVC: no AV1 file could be generated for a test, so the `hevc` kind is covered by the routing (Mac only) and not by a real conversion.
- Plex's reaction.
- Two things at once on the drive: converting while the playback cache or a download is busy on the same disk.

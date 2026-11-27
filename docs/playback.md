# Playing MKV and old AVI files on Apple devices

A large part of a typical home library is Matroska (MKV) with H.264 or HEVC video. AVPlayer does not open MKV. This page records how Lobby gets those files to play and download without re-encoding the video: what was measured (24 November 2026, on a Raspberry Pi 5 with a 5 TB test library), what was rejected, what was built, and what the Apple apps have to do.

A second part, [Converting the old AVI films](#converting-the-old-avi-films), covers the files whose picture has to be converted.

The API is in [api.md](api.md) under Media. The code is `apps/server/src/playback/`.

## The decision

One ffmpeg pass repackages the file into **one fragmented MP4 with an HLS playlist beside it**, in a cache on the server.

- **Streaming** uses the playlist. ffmpeg rewrites it after every segment, so AVPlayer starts while ffmpeg is still working: on the Pi the stream was offered 0.3 to 1.4 s after the request and the first frame came about a second later. What is written can be seeked; the rest becomes seekable as it is written.
- **Downloading** uses the MP4 itself, once ffmpeg is done. It is an ordinary file for a background `URLSession` download, checked by its length, and AVPlayer plays it from local storage with all its sound tracks.
- The video is copied bit for bit (HEVC is retagged `hvc1`). Sound is copied when it is AAC, AC-3 or E-AC-3. Anything else (DTS, Opus, TrueHD, FLAC, MP3, Vorbis) is converted: surround to AC-3, stereo to AAC.
- Text subtitles become WebVTT, as renditions in the stream and as plain `.vtt` files.
- **An MP4 or MOV with HEVC labelled anything but `hvc1` is repackaged too.** AVFoundation shows HEVC only under the sample entry `hvc1` (or `dvh1` for Dolby Vision). Under `hev1` it plays the sound over a black picture, with no error: a real MP4 did exactly that (26 November 2026). The probe keeps the label (`track.codec_tag`, ffprobe's `codec_tag_string`; `""` for Matroska, which has none), and such a file is judged `remux`. Its copy is the same picture relabelled `hvc1` (`dvhe` becomes `dvh1`). Files probed before the label was kept have `codec_tag` null: the server reads their headers once, one at a time, half a minute after it starts (`library/video-tags.ts`), and before playing or offering for download any such file it has not read yet. `lobby tags` lists the files whose label is not `hvc1`.
- Old AVI films in MPEG-4 Part 2 or MS-MPEG-4 v3 take the same route with one difference: their video is converted to H.264 (see the second part).

The original file is only ever read: ffmpeg opens it as input and writes only into the cache. A test hashes an original before and after. On the Pi, the two files whose size and date had been noted beforehand (F2, F4) had the same size and date afterwards; the originals there were not hashed.

## What it was measured on

| | |
| --- | --- |
| Server | Raspberry Pi 5, 8 GB, Debian 13 arm64, kernel 6.12, ffmpeg 7.1.3 |
| Library drive | 5 TB 2.5-inch USB hard disk (shingled), exFAT, USB 3 |
| System disk | 57 GB USB flash stick (SanDisk Ultra), ext4. The cache was on it for these tests. |
| Player | AVFoundation on macOS 26 (the same media stack as iOS and tvOS), and the `iPhone 17 Pro Max` simulator |
| Network | Mac to Pi over the tailnet, direct on the home network |
| Also on the Pi | Other home services (a media server, file sharing, home automation, Docker). Some early runs overlapped a library scan by another process; those are marked. |

Six files from the test library, described by what is in them:

| | Size | Length | Video | Sound | Subtitles |
| --- | --- | --- | --- | --- | --- |
| F1 | 2.29 GB | 89 min | 1080p HEVC Main 10, 3.4 Mbit/s | E-AC-3 5.1 | 2 × ASS |
| F2 | 0.87 GB | 22 min | 1080p H.264 High, 5.3 Mbit/s | AAC stereo | SubRip |
| F3 | 8.22 GB | 90 min | 1080p H.264 High, 12.1 Mbit/s | DTS 5.1 | 2 × SubRip |
| F4 | 0.24 GB | 25 min | 480p HEVC Main 10 | AAC stereo + Opus stereo | 3 × PGS (pictures) |
| F5 | 0.57 GB | 22 min | 1080p HEVC Main 10, 3.5 Mbit/s | AC-3 5.1 | SubRip |
| F6 | 2.57 GB | 95 min | 1080p H.264 High, 3.6 Mbit/s | DTS 5.1 | none |

A probe of 140 MKV files from the library: 90 are 10-bit HEVC, 18 have more than one sound track, 8 have a first sound track that must be converted (DTS). None is HDR or Dolby Vision, so HDR was tested on a generated file only (see below).

### The harness

`tools/playback-experiments` is a Swift command-line tool, `avprobe`. It opens a URL or a local file with `AVURLAsset` and `AVPlayer`, waits for `readyToPlay`, times the first decoded frame (through an `AVPlayerItemVideoOutput`), lists the audio and subtitle options, seeks to a fraction of what is seekable, checks that playback advances, and can select an audio or subtitle option and report the subtitle cues the player hands out. It prints JSON.

```bash
cd tools/playback-experiments && swift build -c release
.build/release/avprobe <url-or-path> --seek 0.95 --play 4 [--watch-seekable 30] [--audio 1] [--subtitle 0]

# The same source built for the simulator and run inside it:
xcrun --sdk iphonesimulator swiftc -target arm64-apple-ios17.0-simulator -swift-version 6 -O \
  Sources/avprobe/main.swift -o /tmp/avprobe-ios
xcrun simctl spawn "iPhone 17 Pro Max" /tmp/avprobe-ios <url>
```

`apps/server/test/playback-experiment-server.ts` serves a list of files through the real playback module without the rest of the server. That is what ran on the Pi for the end-to-end numbers.

## Measurements

"× real time" is the film's length divided by the time ffmpeg took.

### Reading and repackaging are cheap; writing is the limit

| What | Result |
| --- | --- |
| F1 repackaged to `/dev/null` (cold cache, scan running) | 36 s, 6.5 s of CPU. 148 × real time, 64 MB/s off the library drive. |
| F3 repackaged to `/dev/null`, video only, sound dropped | 59 s, 10 s of CPU. 92 × real time. (A second pass over the file; part of it came from memory.) |
| F3 repackaged to `/dev/null`, DTS 5.1 converted to AAC 5.1 at 384 kbit/s | 568 s, 621 s of CPU. 9.5 × real time, one core, nearly all of it the AAC encoder. |
| 10 minutes of DTS 5.1, decoded only | 3.9 s |
| the same, encoded to AC-3 5.1 at 640 kbit/s | 7.1 s (85 × real time) |
| the same, encoded to E-AC-3 5.1 at 640 kbit/s | 7.1 s |
| the same, encoded to AAC 5.1 at 384 kbit/s | 64.6 s (9.3 ×); 29.7 s with `-aac_coder fast` |
| 10 minutes of stereo Opus, encoded to AAC at 160 kbit/s | 26.9 s (22 ×) |
| System disk, 300 MB written and synced (scan running) | 122 s: 2.5 MB/s. |
| System disk, sustained rate seen during every long run | 2 to 3 MB/s, with 50 to 95% of CPU time waiting on it. |

Copying video costs almost no CPU. The Pi reads the library drive at 60 to 100 MB/s. The USB stick the system runs on accepts a burst (Linux buffers roughly the first 0.9 GB in memory) and then writes at 2 to 3 MB/s. So a file under about 0.9 GB is finished in seconds, and a larger one is finished at the stick's pace. Converting sound is the other limit: it runs on one core, and ffmpeg's AAC encoder is nine times slower than its AC-3 encoder on surround sound. That is why converted surround becomes AC-3.

### A. HLS with fragmented MP4, written while ffmpeg runs — chosen

```bash
ffmpeg -nostdin -hide_banner -v error -progress pipe:1 -y -i SOURCE.mkv \
  -map 0:VIDEO -map 0:AUDIO1 -map 0:AUDIO2 \
  -c:v copy -tag:v hvc1 \
  -c:a:0 copy -disposition:a:0 default \
  -c:a:1 aac -b:a:1 160k -ac:a:1 2 -disposition:a:1 0 \
  -map_chapters -1 -dn \
  -f hls -hls_time 6 -hls_list_size 0 -hls_playlist_type event -hls_segment_type fmp4 \
  -hls_flags single_file+independent_segments \
  -hls_segment_filename CACHE/media.mp4 CACHE/index.m3u8 \
  -map 0:AUDIO2 -c:a:0 aac -b:a:0 160k -ac:a:0 2 -map_chapters -1 -dn \
  -f hls (the same options) -hls_segment_filename CACHE/audio-1.mp4 CACHE/audio-1.m3u8 \
  -map 0:SUBTITLE -c:s webvtt -f webvtt CACHE/subtitle.vtt
```

`-tag:v hvc1` only for HEVC. The second and third outputs exist only when the file has a second sound track or an embedded text subtitle.

Through the real module on the Pi, cold cache, AVPlayer on the Mac:

| | F2 (H.264, AAC) | F5 (HEVC 10-bit, AC-3) | F4 (HEVC 10-bit, AAC + Opus) | F6 (H.264, DTS to AC-3) |
| --- | --- | --- | --- | --- |
| Stream offered after the request | 0.7 s | 0.3 s | 1.4 s | 0.6 s |
| AVPlayer: first frame after opening the stream | 1.6 s | 0.9 s | 0.9 s | 1.0 s |
| Seekable at that moment | 2 min | 2 min | 9 s | 40 s |
| Seekable 10 s later | 15 min | all 22 min | 5 min | 6 min |
| Whole file ready | 40 s (33 × real time) | 4 s (330 ×) | 120 s (12 ×) | 351 s (16 ×) |
| Finished stream: first frame | 0.9 s | 0.9 s | 0.9 s | 5.1 s (stick still writing) |
| Finished stream: seek to 95%, frame shown | 1.1 s | 0.4 s | 0.2 s | 0.4 s |
| Same, in the iPhone 17 Pro Max simulator | 0.9 s, seek 1.2 s | 0.7 s, seek 0.5 s | not run | 0.8 s, seek 0.4 s |

F1 by hand with the same command (2.29 GB onto the system disk): first frame 0.8 s after opening, 25 minutes seekable after 6 s, the first 34 minutes of film written in 45 s, and the whole file after **9.0 minutes** (9.8 × real time, 10 s of CPU). The last 1.4 GB went at the stick's 2.9 MB/s.

F3 (8.22 GB) was not written to the stick. At 2 to 3 MB/s it would take 45 to 70 minutes, and that rate is only about twice the film's own 1.5 MB/s, so it is the one case here where a viewer could catch up with ffmpeg and stall. This is an estimate from the measured write rate, not a measurement. Read and converted without writing, F3 takes 59 s (sound dropped) to 568 s (sound to AAC); see the table above.

F4 is slower than its size suggests because its Opus track is converted to AAC twice, once into the main file and once as its own rendition: 97 s of CPU for 25 minutes of sound. A first run of F4, started while the stick was still writing out F2's copy, took 311 s instead of 120 s. That is what a second viewer would see today.

What was learned about AVPlayer and a playlist that is still growing:

- **It plays.** `EXT-X-PLAYLIST-TYPE:EVENT` with no end marker is treated like a broadcast with a full history. Everything listed can be seeked. When ffmpeg writes `EXT-X-ENDLIST` the item turns into ordinary video on demand with its full duration, without restarting.
- **It starts at the newest segment, not the beginning**, unless told otherwise. `EXT-X-START:TIME-OFFSET=0` in the master playlist fixes that (measured: position 0.9 s one second into playback, against 122 s without it).
- **It learns about new segments only when it reloads the playlist**, once per target duration (10 to 13 s for these files). The seekable range grows in those steps and stays about three segments behind what is written.
- **It waits for a buffer before the first frame.** Offered a stream with 19 s written and growing slowly (the first run of F4), it took 18.8 s to show a picture. Offered one with 30 s or more written, 0.9 to 1.6 s (every run in the table). The server therefore offers the stream only once 30 s of film are written. That takes under a second when the sound is copied and 1.4 s for F4.
- **Segments follow keyframes.** ffmpeg can cut only where the video has a keyframe. With a 6 s target the three finished copies have segments of 1.1 to 13.4 s, median 6.0 s. A file with long gaps between keyframes gets long segments, and AVPlayer fetches a segment from its start: a seek into a 37 MB segment of F3 (about 30 s of 10 Mbit/s video without a keyframe) took 7 s to show a frame over a link that carried 45 Mbit/s, where the same seek elsewhere in the file took 0.9 s. Slower, not broken, and seeking stays exact.
- **`-hls_flags temp_file` must not be combined with `single_file`**: ffmpeg (7.1 and 8.1) then lists `media.mp4.tmp` in the playlist, a file that does not exist. Without the flag ffmpeg still replaces the playlist atomically (0 partial reads in 10,000 while it was being rewritten).
- **`CODECS` in the master playlist is not needed.** With and without it the first frame came after 0.3 to 0.5 s on a local server. It is left out, because a wrong string is worse than none.
- Without `CLOSED-CAPTIONS=NONE` AVPlayer lists an empty captions option.

Single file against many segment files: the single file is the same bytes plus one playlist line per segment, costs one open file instead of a thousand, and is what makes the download possible. Nothing favoured separate files.

### B. A prepared MP4 with `-movflags +faststart` — rejected

```bash
ffmpeg -i SOURCE.mkv -map 0:v:0 -map 0:a -c copy -tag:v hvc1 -movflags +faststart CACHE/film.mp4
```

Nothing can play until ffmpeg is done, and `faststart` rewrites the whole file a second time to move the index to the front. F1 onto the system disk: the first pass took about 5.5 minutes; the rewrite was still running when the run was stopped after 16.5 minutes, with the Pi at load 7 and 95% of CPU time waiting on the disk (a library scan was running too). F3 was not attempted: 8 GB written twice at 2 to 3 MB/s is over an hour of a saturated system disk on a machine the family is using.

On a fast cache disk B would take roughly the time of the read (36 s for F1). It would still make the first play of every file wait for the whole file, where A starts in a second or two. A's finished `media.mp4` serves the same purposes B's file would.

### C. A fragmented MP4 over plain range requests, no playlist — rejected for streaming

The finished `media.mp4` of F1, opened by URL: **not ready after 120 s.** AVPlayer made 1,301 range requests walking the file fragment by fragment and had reached 68 MB of 2,288 MB. Without a playlist it has no index of a fragmented file and builds one by reading through it.

From local storage the same walk is quick, which is why the file works as a download. F4's copy was fetched with a plain HTTP GET of `downloadUrl` (225,419,339 bytes, equal to `downloadBytes` and to `Content-Length`). From the local file it was ready in 0.43 s on macOS and 0.25 s in the simulator, seeked to 95% in 0.06 s and 0.11 s, and offered both sound tracks, each of which played. A 0.9 GB and a 2.3 GB copy were not downloaded to the Mac (it had under 5 GB free); the walk reads only the few bytes of each fragment's header, so it should scale with the number of fragments, not the size, but that is an expectation, not a measurement.

### Other things tried

- **Text subtitles inside the MP4 (`mov_text`)**: AVPlayer listed the track from a fragmented MP4 but delivered no cues in 8 s of playback. Rejected; subtitles stay outside the file as WebVTT.
- **`AVAssetDownloadURLSession`** (Apple's own HLS download): not tried. It does not run in the simulator, would be a second download path beside the plain one for MP4 files, and is not needed, since the MP4 downloads as a file.
- **Cutting segments on demand** (no cache; one ffmpeg per segment request, or restarting ffmpeg at the seek position as Jellyfin does): not built. It would allow seeking anywhere at once and need no cache, at the price of exact agreement between a precomputed playlist and what ffmpeg cuts, and of nothing to download. With the whole file ready in seconds to minutes it was not worth that.

### Sound

- The track flagged as default in the file comes first (else the first track). The stream plays it. The MP4 carries every track.
- A stream cannot switch to a second track that only exists inside the main segments: AVPlayer played the first and listed nothing. So each further track is also written on its own (`audio-N.mp4` with a playlist) and listed in the master playlist as an audio rendition; the first track is listed without a URL, meaning "in the stream itself". Selecting the second option switched to it (F4, and a generated file with E-AC-3 + AAC). F4's separate track is 19 MB.
- AVPlayer picks an audio rendition by the device's languages on its own (`AUTOSELECT=YES`, `LANGUAGE` set from the track). That automatic choice was not tested with a second language installed.
- From the local file AVPlayer lists the tracks itself, by language. Both of F4's played.
- Converted sound: more than two channels become AC-3 5.1 at 640 kbit/s (6.1 and 7.1 are mixed down), stereo and mono become AAC at 160 kbit/s. AC-3 because of the encoder speeds above: a 90-minute film with DTS 5.1 would be complete after about 9.5 minutes with AAC whatever the disk, and is limited only by the disk with AC-3. Every Apple device decodes AC-3, and an Apple TV can pass it to a receiver.
- DTS 5.1 converted to AC-3 5.1 plays: all of F6 through the module (table above), and a three-minute cut of F3 converted both ways (AC-3 and AAC 5.1), each on macOS and in the simulator. AVFoundation reports `ac-3`, six channels.

### Subtitles

- `ffmpeg -i SOURCE -map 0:N -c:s webvtt -f webvtt out.vtt` handles SubRip, ASS/SSA (styling dropped, text and timing kept), `mov_text` and WebVTT.
- The lines of an embedded track are spread through the file, so getting them out means reading all of it: 21.5 s for F1 on its own. Written as an extra output of the repackaging pass they cost nothing, so that is where they are made. They are complete when the copy is.
- **As HLS renditions they work**: a master playlist entry of `TYPE=SUBTITLES` pointing at a one-segment playlist around the whole `.vtt`. AVPlayer listed them by name and language and delivered the right cues after a seek to 95% (F2 and F5, macOS and simulator). Cue times were within 45 ms of the source.
- **Image subtitles (PGS, DVD)** cannot become text. 69 of the 140 probed MKV files have only those (55 have a text track, 16 have none). The API reports the track with `isText: false` and the `.vtt` URL answers `422 unsupported_subtitle`. Showing them would need OCR or burning them into re-encoded video; neither is part of this.
- Old sidecar `.srt` files are often Windows-1252. They are detected (not valid UTF-8) and converted, so accented letters survive.

### 10-bit, HDR and Dolby Vision

- **HEVC Main 10** is copied and plays: AVFoundation reports `hvc1`, 10 bits per component, on macOS and in the simulator (F1, F4, F5).
- **HDR10**, on a generated file (HEVC 10-bit, PQ, BT.2020, mastering display and content light level): after repackaging AVFoundation reports the PQ transfer function, BT.2020 primaries, both metadata blocks and `containsHDRVideo`, through the stream and from the local file.
- **Dolby Vision and HDR10+** were not tested: the library sample has none and ffmpeg cannot generate them. ffmpeg carries the Dolby Vision configuration into MP4, and a Dolby Vision original (`dvhe` or `dvh1`) is now relabelled `dvh1`; any other HEVC gets `hvc1`. Still untested on real Dolby Vision files.

## Where the cache should live — a decision for Sil

The module takes a folder and a size limit. Where that folder is decides how the feature feels:

| | System disk (USB stick) | Library drive (hard disk) |
| --- | --- | --- |
| Free | 35 GB | 2.4 TB |
| Writes | 2 to 3 MB/s sustained (measured) | not measured. It reads at 60 to 100 MB/s. |
| A 2.3 GB film is complete after | 9 minutes | about a minute, if it writes as it reads |
| Side effects | The stick is saturated while a copy is written (the catalogue database, Plex and Home Assistant live on it), and flash wears out. | Reads and writes share one spindle. The drive is exFAT and so far read-only for Lobby. |

**Recommendation: a folder on the library drive, outside every library folder**, for example `/srv/media/.lobby-cache`, with a limit of 100 GB. It is a rebuildable cache and Lobby would be the only thing writing there; the scanner already skips hidden folders and the config refuses a data folder inside a library root. Until Sil agrees, the default is `<dataDir>/cache/playback` on the system disk with a limit of 20 GB: it works (streams start in a second or two, the numbers above are from it), but a long film takes minutes to be complete and the Pi is sluggish meanwhile. A small SSD for the system would solve the same problem without touching the library drive.

Streaming does not wait for the cache in either case. What the slow disk costs is the time until the end of a long film is seekable, the time until a download can start, and the responsiveness of everything else on the Pi.

## Converting the old AVI films

Older libraries often hold AVI files in MPEG-4 Part 2 or MS-MPEG-4 v3, whose video no Apple decoder plays. Repackaging is not enough for them: the picture itself has to be converted to H.264. They are small (a probe of 60 such files: 560 to 720 pixels wide, 272 to 480 high, 24 to 30 frames a second, 1 to 3.5 Mbit/s), and at that size the Pi converts several times faster than the film plays. So they go through the same module, in the same form: one fragmented MP4 with a growing HLS playlist, a stream after a few seconds, a download when it is done. Measured on 24 November 2026 on the same Pi and Mac as above.

Of the 60 probed files, 37 have MP3 sound (stereo or mono), 23 have AC-3 (mono, stereo or 5.1), 3 have two sound tracks. 44 are episodes of about 7 minutes; 16 are films of 40 to 126 minutes.

### The command

```bash
ffmpeg -nostdin -hide_banner -v error -progress pipe:1 -y -i SOURCE.avi \
  -map 0:VIDEO -map 0:AUDIO \
  -c:v libx264 -preset veryfast -crf 21 -profile:v high -pix_fmt yuv420p \
  -vf "crop=trunc(iw/2)*2:trunc(ih/2)*2" \
  -force_key_frames "expr:gte(t,n_forced*6)" \
  -c:a:0 aac -b:a:0 160k -ac:a:0 2 -disposition:a:0 default \
  -map_chapters -1 -dn \
  -f hls -hls_time 6 (the same HLS options as for a repackaged file)
```

- **`-force_key_frames`** puts a keyframe exactly every 6 seconds, where the segments are cut. Every segment of the converted copies is 6.0 s long (the last one shorter), unlike a repackaged file, whose segments follow the keyframes it happens to have. The encoder still adds keyframes at scene changes in between.
- **`crop`** removes one row or column from a picture with an odd size, which H.264 with this pixel format cannot store. None of the 60 probed files has one; it is a guard that no real file has exercised.
- **Packed B-frames** (common in DivX 5 files) and files without timestamps need nothing extra: ffmpeg's decoder handles both. The DivX 5 file below converted and played without an option for it.
- **Sound** follows the existing rule. AC-3 is copied. MP3 is converted to AAC, because AVPlayer does not play MP3 from a fragmented MP4: with the MP3 copied, the stream failed to open (`AVFoundationErrorDomain -11829`) and the local file opened without a sound track (generated file, macOS).

### Preset and quality

150 seconds from the middle of two films, converted on the otherwise idle Pi at niceness 15, written to memory, sound left out. SSIM compares the result with the decoded original (1 is identical).

Film X: 640×352, 25 frames/s, 1.15 Mbit/s, calm picture.

| Preset, CRF | Speed | CPU seconds | Result | SSIM |
| --- | --- | --- | --- | --- |
| ultrafast, 21 | 29.4 × | 14 | 1,153 kbit/s | 0.9908 |
| superfast, 21 | 20.6 × | 22 | 746 kbit/s | 0.9917 |
| **veryfast, 21** | **13.9 ×** | 32 | **392 kbit/s** | 0.9890 |
| faster, 21 | 8.5 × | 58 | 425 kbit/s | 0.9904 |
| fast, 21 | 6.1 × | 78 | 459 kbit/s | 0.9914 |
| medium, 21 | 4.9 × | 99 | 447 kbit/s | 0.9915 |
| veryfast, 19 | 11.9 × | 38 | 509 kbit/s | 0.9910 |
| veryfast, 23 | 13.2 × | 34 | 303 kbit/s | 0.9865 |
| superfast, 19 | 15.7 × | 30 | 978 kbit/s | 0.9933 |

Film Y: 656×480, 25 frames/s, 3.08 Mbit/s, the highest bitrate in the sample.

| Preset, CRF | Speed | CPU seconds | Result | SSIM |
| --- | --- | --- | --- | --- |
| ultrafast, 21 | 12.1 × | 39 | 2,808 kbit/s | 0.9737 |
| superfast, 21 | 6.0 × | 85 | 2,865 kbit/s | 0.9821 |
| **veryfast, 21** | **3.9 ×** | 135 | **2,166 kbit/s** | 0.9807 |
| faster, 21 | 2.5 × | 213 | 2,243 kbit/s | 0.9820 |
| fast, 21 | 1.6 × | 320 | 2,297 kbit/s | 0.9824 |
| medium, 21 | 1.3 × | 422 | 2,218 kbit/s | 0.9817 |
| veryfast, 19 | 3.2 × | 167 | 2,660 kbit/s | 0.9842 |
| veryfast, 23 | 3.5 × | 149 | 1,744 kbit/s | 0.9768 |
| superfast, 19 | 4.6 × | 112 | 3,706 kbit/s | 0.9861 |

**Chosen: `veryfast`, CRF 21.**

- `veryfast` gives the smallest file of all presets at the same CRF and stays 3.9 times faster than playback on the hardest clip. The slower presets buy at most 0.002 of SSIM for 1.6 to 3 times the CPU, and `medium` at 1.3 × leaves no room for anything else on the Pi.
- `superfast` and `ultrafast` are faster but need 30 to 190% more bytes for the same picture, and those bytes are written to the slow system disk.
- CRF 21 keeps the copy at or below the original's bitrate (0.34 and 0.70 of it here) with SSIM of 0.98 to 0.99. CRF 23 saves another 20% and loses the most quality of the options tried; CRF 19 costs 23 to 30% more bytes for 0.002 to 0.004. The source is a lossy 480-line encode already, so there is little to preserve beyond that.
- SSIM is a number, not a viewing test. Nobody has looked at these copies on a television yet.

### End to end on the Pi

Through the real module (`playback-experiment-server.ts`), cold cache, AVPlayer on the Mac.

| | A1 | A2 | A3 | A4 |
| --- | --- | --- | --- | --- |
| Video | MPEG-4 (DivX 5), 720×480, 29.97 frames/s | MS-MPEG-4 v3 (DivX 3), 640×432, 23.98 | MPEG-4 (XviD), 656×480, 25, 3.1 Mbit/s (film Y) | MPEG-4 (XviD), 640×352, 25 (film X) |
| Sound | MP3 mono, to AAC | MP3 stereo, to AAC | AC-3 5.1, copied | MP3 stereo, to AAC |
| Length, size | 7 min, 68 MB | 70 min, 521 MB | 40 min, 1,047 MB | 75 min, 734 MB |
| Stream offered after the request | 4.5 s | 4.4 s | 4.7 s | not timed |
| AVPlayer: first frame after opening the stream | not recorded | 0.4 s | 0.5 s | not run |
| Seekable 25 s after opening | not recorded | 3.2 min | 2.4 min | not run |
| Whole file ready | 95 s (4.5 ×) | 694 s (6.1 ×) | 749 s (3.2 ×) | 622 s (7.3 ×) |
| Size of the copy | 75 MB (1.11 of the original) | 425 MB (0.82) | 630 MB (0.60) | 340 MB (0.46) |
| Finished stream: first frame, seek to 95% | 0.4 s, 0.6 s | 0.4 s, 0.2 s | 0.6 s, 0.5 s | not run |
| Same, in the iPhone 17 Pro Max simulator | 0.4 s, 0.4 s | 0.4 s, 0.9 s | 0.6 s, 0.4 s | not run |

- No run stalled, while the copy was being written or after.
- While A2 and A3 were being converted, AVPlayer played from the start, was seeked to 90% of what was seekable and played on. Its seekable range grew by 30 to 54 s of film for every 6 s of watching.
- A1's copy was downloaded with a plain GET of `downloadUrl` (75,212,749 bytes, equal to `downloadBytes`). From the local file it showed its first frame after 0.3 s on macOS and in the simulator, and a frame after a seek to 95% in under 0.1 s.
- A1's segments: 70 of 71 are 5.97 or 6.01 s long (a whole number of frames at 29.97 frames a second); the last is shorter.
- A3 ran together with the other work described below, and A4 started when A3 was done. A1 and A2 ran alone. The originals of A1, A2 and A3 had the same size and date afterwards.
- The conversions took 4.4 to 4.7 s to write the 30 s of film the stream waits for. That is the price against a repackaged file, which is offered after 0.3 to 1.4 s.
- A converted copy is 0.46 to 1.1 times the size of its original. The module reserves 1.5 times the original's size in the cache before it starts.
- While a conversion runs the Pi's load average is 8 to 9.5 (four cores, six encoder threads at niceness 15).

### A conversion beside other work

With A3 (the hardest film of the sample) being converted, on the Pi:

| Meanwhile | Result |
| --- | --- |
| A second AVI (A4) was asked for | `queued`. It started by itself when A3 was done. |
| A finished stream (A2) was opened, seeked to 50% and played for 20 s | First frame 0.4 s, frame after the seek 0.4 s, 19.9 s of film in 20 s, no stall. |
| An MKV (1440×1080 HEVC, AAC, 0.37 GB) was repackaged | Stream offered after 0.6 s, whole file ready after 4.5 s. Alone, a 0.57 GB MKV took 4 s. |
| A3 itself | 3.2 × over the whole film, against 3.9 × for a 150 s clip of it alone. |

Not measured: a conversion while Plex transcodes, and a conversion while a second viewer's long MKV is being written to the slow system disk. Both compete for the same four cores and the same stick.

How the module keeps a conversion from getting in the way:

- **One conversion at a time** (`maxConversions`, default 1), inside the general limit of two preparations. A second AVI waits in the queue as `queued`; a file that is only repackaged does not wait for it.
- **Lower priority**: ffmpeg runs at niceness 15 when it converts (10 when it repackages). The server process itself, which serves the bytes of a running stream, runs at 0.
- **The stream is offered only when the viewer cannot catch up with it.** The module measures how fast the playlist has grown since ffmpeg started (`speed`, film seconds per second, an average over the run so far). At 1.1 × or more the stream is offered once 30 s are written, as for repackaged files. Below that, it is held back until the head start is large enough that a viewer who starts now reaches the end after ffmpeg does. `preparedMs`, `progress` and `speed` keep reporting the truth meanwhile, so an app can show how long it will take. On the Pi every real conversion ran at 3.2 × or more, so this rule never held a stream back there; it is exercised by a test that paces the real ffmpeg at 0.6 ×.

### AV1

106 files (165 hours) are AV1, 1080p, in MP4. They stay `unsupported` with a reason. What was measured on a 90 s clip of one of them (1920×1080, 23.98 frames/s, 0.8 Mbit/s video, Opus sound), on the idle Pi at niceness 15, output to memory:

| What | Speed | Result |
| --- | --- | --- |
| Decoding only (libdav1d) | 7.9 × | |
| To H.264 1080p, `veryfast`, CRF 21 | 1.4 × | 2,083 kbit/s, about 2.5 times the original |
| To H.264 1080p, `superfast`, CRF 21 | 1.6 × | 3,575 kbit/s |
| To H.264 720p, `veryfast`, CRF 21 | 1.9 × | 1,307 kbit/s |

So the Pi can convert AV1, but not cheaply: a 97-minute film would hold all four cores for about 70 minutes, leave almost no margin over playback (a second task on the Pi would push it below 1 ×), and produce a copy more than twice the size of the original on the slow disk. Converting 165 hours this way is about 120 hours of full load. That is not the "cheap, measured answer" this was allowed to add, so it was not built.

Two cheaper routes exist and are not built either:

- **Devices that decode AV1 in hardware** (iPhone 15 Pro and later, M3 and later; no Apple TV so far) could play these files with the video copied. The probed file has Opus sound, so it would still need the repackaging pass (video copied, Opus to AAC), which costs seconds. The server cannot know what the device decodes: the app would have to say so in the playback request, which is a change to the contract.
- **Converting on the Mac**, once, in the background, as the original spec suggested.

Only one AV1 file was measured. Others may be harder or easier.

## What was built

`apps/server/src/playback/`:

| File | Does |
| --- | --- |
| `plan.ts` | Chooses the video track and whether it is copied or converted to H.264, orders the sound tracks, decides copy or convert for each, builds the ffmpeg command. |
| `service.ts` | `PlaybackService`: a queue with bounded concurrency (2 by default, of which one video conversion), ffmpeg at niceness 10 (15 when it converts video), progress, speed, state, subtitles, cancellation, clean shutdown. |
| `cache.ts` | The cache folder: one hashed folder per asset, a size limit with least-recently-used eviction, a free-space reserve, deletion of half-written copies at start, invalidation when the revision changes. |
| `subtitles.ts` | One subtitle to WebVTT. |
| `playlist.ts` | The master and subtitle playlists; reading ffmpeg's stream playlist. |
| `files.ts`, `routes.ts` | Byte-range file responses and the Hono routes. |

Rules it keeps:

- A copy counts only once `meta.json` says `complete`. Anything else found at start is a crash leftover and is deleted.
- A copy belongs to one revision of a file. A request for another revision deletes it and starts again; URLs carry the revision.
- Requests never name paths. The asset id is hashed into a folder name and file names must match a fixed pattern (`index.m3u8`, `media.mp4`, `audio-N.m3u8`, `audio-N.mp4`).
- Copies in progress are never evicted, and neither is a copy that was used in the last two minutes (someone is playing or downloading it).
- A copy can be prepared ahead of need (`prepare` with `background`, used for the downloads a manager puts on a device, see [api.md](api.md)): one at a time, at niceness 19, outside the limit on preparations. Its ffmpeg is stopped (`SIGSTOP`) while any other file is prepared or the service is told someone is watching, and continued afterwards. It may only replace copies nobody waits for and nobody used for a day. Asking for the same file in the ordinary way turns it into an ordinary preparation. A file larger than the whole cache fails with a sentence that says so.
- If ffmpeg fails with subtitle outputs attached, the copy is made once more without them, so an unreadable subtitle track cannot cost the film.
- File names never reach the log: ffmpeg's messages are stripped of the source path.

## What the Apple apps must do

1. **Always ask first.** `POST /v1/assets/{id}/playback` for every file, direct or not, and use the URLs it returns. Never build a playback URL.
2. **Play `streamUrl` with AVPlayer**, sending the device credential as the `lobby_device` cookie (`AVURLAssetHTTPCookiesKey`). While `streamUrl` is `null`, show "Preparing…" and ask again every second. This normally lasts one or two calls.
3. **Seek explicitly to the start or resume position before playing.** The playlist asks for a start at zero, but an explicit seek does not depend on that.
4. **Resuming beyond `preparedMs`**: keep asking until `preparedMs` has passed the position (show `progress`), then start. AVPlayer's own seekable range lags `preparedMs` by up to 40 s while a copy is being written; if a seek target is beyond `seekableTimeRanges`, wait and retry rather than seeking past the end.
5. **Scrubbing while a copy is written**: limit the scrubber to `AVPlayerItem.seekableTimeRanges`. The item's duration is indefinite until the copy is complete; use `durationMs` from the catalogue for the bar. The apps draw that bar themselves: the film's whole length, what the server has prepared, what the device holds (`loadedTimeRanges`) and where the viewer is. A complete copy and a direct file are ordinary video on demand, with the system's own bar. When the copy is finished under a playing film, the same item learns it at its next look at the playlist (2.5 s in the end-to-end test) and gets the film's length; the app then hands over to the system's bar on that item and opens nothing again. Only an item that has not seen the end after 30 s is opened once more on the complete copy, where the viewer is (that reopening cost a blink, and could stall on a busy Pi while the new item filled its buffer from nothing).
6. **Audio and subtitle menus**: use the item's media selection groups (`.audible`, `.legible`). In a stream they come from the master playlist; in a downloaded file from the file. `Playback.audio` says which original tracks they are.
7. **Subtitles a stream does not list.** A stream started while its copy was being written lists only sidecar subtitles, because embedded ones are finished with the copy. Direct MP4 files and downloads have no playlist at all. For those the app fetches `/v1/assets/{id}/subtitles/{subtitleId}.vtt` and draws the cues itself over the video, timed from the player's clock. One renderer covers every case, including offline; the HLS renditions are a convenience on top (they also work over AirPlay). The apps keep drawing those after the copy is finished, rather than opening the item again for the native menu to gain them. Picture subtitles (PGS, DVD) are never in a stream: the app fetches `….json`, placed PNG cues, and draws them where they belong (D-057).
8. **Downloads**: ask for playback until `state` is `ready`, then download `downloadUrl` with a background `URLSession`, with the cookie. Check the finished file against `downloadBytes`, store `revision` with it, and promote it atomically. Resume with `Range` and `If-Range: <ETag>`. Download the `.vtt` of each text subtitle next to it. Give the local file an `.mp4` extension.
9. **A `404` on a prepared URL** means the copy was evicted or the file changed: ask for playback again. During a download, restart from the new answer.
10. **Never open `downloadUrl` in AVPlayer over the network.** It works only from local storage (see C).
11. **`unsupported` and `failed`** carry a `message` to show as it is.
12. **Converted files** (`videoConverted: true`): the stream comes after about 5 s instead of 1, and the whole copy takes minutes (a 75-minute film: 10 to 12 minutes). Say that the film is being converted, show `progress`, and estimate the time left as `(durationMs - preparedMs) / speed`. If `streamUrl` stays `null` while `preparedMs` grows, the server is converting more slowly than the film plays and is holding the stream back; keep asking. A second converted film asked for meanwhile answers `queued` until the first is done.

13. **How far ahead the player fetches** (`preferredForwardBufferDuration`, for a stream or file over the network, not a growing copy): 60 s at home, enough to ride out a Pi whose disk is busy writing a copy and little to throw away on a jump; 60 s away on a phone, tablet or Mac, where mobile data is what is spent ahead and the direct road mends a broken path within seconds; 180 s away on an Apple TV, on a hotel's slow line where pausing lets more arrive. Left to itself AVPlayer fetches as much as it can: the owner's iPhone took 283 MB in two minutes over the direct road.
14. **Saying why the picture waits** (tvOS): from what the player holds ahead of where it is, not from everything it holds. With 10 s or more ahead the wait is not the connection's and is called buffering; below that a slow arrival is called slow, and nothing for 20 s (90 s while the server still prepares that part) that nothing arrives.

## When something ends

What the player does at the end of a film or episode goes by the preferences of the viewer it plays as (`Profile.playback`, [api.md](api.md#profiles), D-058), on every device: a TV that plays as a viewer, also one started from a phone with Play On, goes by that viewer's. The decisions are in `apps/apple/Shared/Models/UpNext.swift`; `PlayerModel` carries them out.

- **An episode with a next one.** The Up Next card: the next episode's picture and line, Play Now, and Cancel while it counts down (`countdownSeconds`, 10 by default). When it is over the next episode starts in the same player. With `episodeAutoplay` off or the countdown off, the card waits for Play Now. The last episode of a season goes on to the next season's first (the series' regular episodes are one order; Specials are their own). Cancel stops the countdown and leaves Play Next. In the credits (the part Continue Watching counts as finished) Play Next is offered as before.
- **A film, or a series' last episode.** The suggestions over the last picture: what goes with it (the title's Related rows, `RelatedTitles`), then up to four from Continue Watching, at most twelve, only what the viewer may see and what plays here; big artwork, select to play, Back or Close to close. Nothing starts by itself unless the viewer turned on `filmAutoplay`: then the first one starts after the countdown. With `filmSuggestions` off, or nothing to suggest, the player closes as before.
- **"Still watching?"** Before anything starts by itself, after `stillWatchingEpisodes` titles in a row without a touch (3; kids 2) or `stillWatchingHours` without one (off by default). Playback waits; Continue Watching plays what would have come, Stop closes. A touch is anything the viewer does: play, pause, a jump, a sound or subtitle choice, Play Now, Cancel, a suggestion, and every command from a remote. Changes the player makes itself (starting, stopping at the end of an episode's part, opening again) do not count.
- **Credits.** With `startAtCredits` (on by default) Up Next comes where the episode's credits start, when the server knows (`MediaFile.markers.credits`, from chapters, a manager or found by Skip Intro, D-059) and the viewer has Next Episode on at the credits (`Profile.skipping.credits`); the episode plays on under the card. When the countdown is over the next episode starts and this one counts as finished there. Cancel in the credits leaves Play Next, and the end does not count down again. "Still watching?" is not asked over the credits: it waits for the end. Without credits markers Up Next comes at the end. None are guessed. Films keep their suggestions for the end.
- **On the remote.** The playing device says what it shows in `player.upNext` (kind, what starts, the countdown, the suggestions). A phone that controls it shows the same with the same buttons: Play Now, Cancel, Continue Watching and Stop (`upNext` and `stop` commands), and a suggestion is played there with `play` as the same viewer.
- **Kids.** A child's preferences are set by a grown-up on the viewer's page (a manager); the child's own device cannot change them. Kids control (D-062) goes before them: a next episode or suggestion the child's mode does not let play now is not offered and never starts by itself, also when the mode changes during the countdown. The server refuses it as well.

## Not verified

- **Up Next, the suggestions and "Still watching?" on a screen.** The decisions are unit-tested; the screens were built for iPhone and iPad, Mac and Apple TV but not watched to the end of a real episode on a device, nor a Play On session answered from a phone.

- **A real iPhone, iPad or Apple TV.** Everything ran on macOS and in the iPhone 17 Pro Max simulator. Hardware decoding of 10-bit HEVC, AC-3 and E-AC-3 output on a television, and behaviour on a slow link away from home are untested.
- **The iPad download in airplane mode.** The app does not exist yet. The equivalent was done by hand: a plain HTTP download of `downloadUrl`, length checked against `downloadBytes`, played from the local file on macOS and in the simulator.
- **Local playback of a large downloaded copy** (2 GB and up): only a 225 MB copy was tried.
- **Writing the cache to the library drive.**
- **Dolby Vision, HDR10+ and real HDR10 files.**
- **AVPlayer's automatic choice of sound track by device language.**
- **Converted AVI films** (see that part): nobody has watched a converted copy on a screen; quality is an SSIM number. Interlaced sources (AVI does not say whether a file is interlaced; all 60 probed report unknown), files with an odd picture size, a conversion beside a Plex transcode, and conversions slower than playback on the real Pi were not met. 5 of 533 files were converted.
- **Two viewers at once on the Pi.** The queue and its limit are tested. The only measurement of two copies competing for the system disk is the first run of F4 (311 s instead of 120 s); two films starting together were not tried.

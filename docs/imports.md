# Import folders and uploads

Two ways new films and episodes reach the library besides being copied into a library folder by hand: **import folders**, folders on the server where files land, and **uploads** from the Mac, iPhone and iPad apps. Both end in the same pipeline. The API is in [api.md](api.md#imports-and-uploads); why it is this way is D-050 in [decisions.md](decisions.md).

Lobby itself never fetches media from anywhere. An import folder is any folder where files appear by whatever means the household uses; Lobby only looks at what is already there.

## Import folders

A server admin adds them in Settings → Imports and Uploads, with the folder browser. There are none by default. Each folder has a **mode**:

| Mode | What happens to a finished file |
| --- | --- |
| `move` (default) | Moved into the library under a neat name, when Lobby is sure what it is; otherwise it waits in the Inbox. |
| `index` | Left where it is and listed in the library from there. The folder is a library source of its own (a category named after it). Nothing in it is moved unless a manager chooses that for a file. |

A folder whose name says a download program may be using it (`Downloads`, `Incoming`, `Incomplete` and the like, the same names converting already avoids) starts in `index` mode. A program that still serves or checks a file loses it when it is moved, so moving such a file is the manager's explicit choice: per file in the Inbox, or for the whole folder by switching it to `move`.

An import folder may not be inside, or contain, a library folder, the data folder or Lobby's folder.

### When a file counts as finished

A file is looked at only when all of these hold:

1. **Its name ends in a video extension** (`.mkv`, `.mp4`, `.m4v`, `.avi` and the other video extensions the library knows). A name with anything after the video extension (`Film.mkv.part`, `Film.mp4.abc`) is a file still being written, and waits until it is renamed.
2. **No control file beside it.** A file of the same name with a temporary or control extension (`.part`, `.partial`, `.tmp`, `.crdownload` and similar) means a program is still at work.
3. **It kept its size and date** for the wait set in Settings → Imports and Uploads (`import.waitMinutes`, 10 by default), measured by Lobby itself across its looks, not taken from the file's date.
4. **No other program has it open**, where that can be seen: on Linux, the processes of the user Lobby runs as (`/proc/<pid>/fd`). On a Mac this cannot be seen and is not checked.

Until then it is in the **waiting** view, with the reason.

### What is left out

Never moved and never listed; shown only in the Inbox's **ignored** view, with the reason:

- **Not the feature.** A name or folder with one of the words sample, trailer, featurette, extras, behind the scenes, deleted scenes, interview or teaser, as a whole word in any case (also `-sample`). A film that is really called so ("The Interview") is left out too, and a manager imports it from the ignored view.
- **Too small.** A film under 100 MB, an episode under 20 MB, and a film less than a quarter of the size of the largest film beside it.
- **Not a video.** `.nfo`, `.txt`, `.jpg`, `.png`, `.url`, `.exe`, `.srr`, `.sfv` and everything else that is not a video or a subtitle.

Subtitles go along with their video: the ones whose name starts with the video's name, or all of them when the folder has one video, also from a `Subs` or `Subtitles` folder beside it.

### Where a file goes, and under what name

The parser reads the name as it reads library files, and TMDB is asked with the same rules as the library's own matching (D-021), with the file's running time from ffprobe. Only a strong match with nothing else like it is used. Then:

| | Goes to | As |
| --- | --- | --- |
| A film | The first `movies` library folder (or `mixed`), or the category's folder the manager chose | `Title (Year)/Title (Year).ext`, with ` - Edition` and ` - Part N` where the name had them |
| An episode | The first `series` library folder (or `mixed`) | `Show/Season 01/Show - S01E02 - Episode title.ext` |
| A subtitle | Beside its video | The video's new name, with what followed the old name kept: `Title (Year).en.srt` |

Names keep out what exFAT cannot hold (`/ \ : * ? " < > |`, control characters, a trailing dot).

Anything less than a strong match waits in the **Inbox**: no TMDB key, nothing found, several fitting titles (they are offered as candidates), a name the parser cannot place, an episode without numbers. Lobby never guesses. A manager confirms the kind, title, year (season and episode) and where it goes, and it is moved.

### Moving

- Only with Lobby's folder set (`conversion.dir`) and its drive connected: the journal lives there, as for converting.
- **On one drive only**: a rename. A file on another drive than its library folder waits in the Inbox, unless *Copy between drives* is on; then it is copied beside its target under a hidden name, read back and compared by SHA-256, renamed into place, and only then removed where it was.
- **Never over anything**: when the target name is taken, the file waits in the Inbox with that reason.
- **Journalled**: the same journal as converting ([conversion.md](conversion.md#replacing-and-what-a-crash-leaves)). A move stopped at any step (the journal entry, any rename, the database) is finished or taken back at the next start, before the library is scanned. Another file in the way at that point means it is taken back, and the file waits in the Inbox.
- **Nothing is deleted** but what a manager confirms: after a film was moved, what is left of its folder, when all of it is leftovers (descriptions, pictures, checksums, samples, small videos) is offered as **Clean up**. The request must say `"delete leftovers"`; each file is judged again first, and only files and empty folders below that folder go.
- A file in an old format (AVI, WMV, MPEG, …) can be put in the conversion queue from the item once it is in the library.

## Uploads

From the Mac (drag files or folders onto the window, or Upload…) and from iPhone and iPad (Upload from Files, external drives included). The manager chooses where it goes: Films, Series, or one library folder (a category).

- **Resumable**, in the manner of tus: create, then pieces at the offset where the last one ended, each with its SHA-256; ask where it is with `HEAD`; complete with the whole file's SHA-256. A piece that does not start where the upload is, arrives damaged or is cut off is refused with the offset to go on from; nothing of it is kept.
- Into Lobby's folder on the media drive (`<conversion.dir>/uploads/`), as `<name>.lobby-upload` until it is whole and proven, so neither the library nor anything else reads it halfway.
- Then the same pipeline as a file in a `move` folder: the rules, the matching, the Inbox, the journalled move. A dismissed upload's copy in Lobby's folder is removed (the original is still on the device).
- **Limits**: managers only, at home or over Tailscale; the largest file (`uploads.maxFileGb`, 100), the room unfinished uploads may take together (`uploads.quotaGb`, 500), the free space that must stay on the drive (`conversion.minFreeGb`), eight unfinished uploads per device, one piece at a time per upload, and a rate limit on starting them. An upload that received nothing for a week is given up and its bytes removed.
- **Not from outside, for now**: neither the relay nor the direct road carries uploads. The outside entrance closes every manager's route by design (D-028); a relay would also carry tens of gigabytes through a machine that is not the household's, under body limits of 1 MB; and the direct road would need the entrance to tell its roads apart, which is a change to the connection layer of its own.
- The apps show each file's progress, from the live channel's `upload` events; iPhone and iPad go on in the background with background `URLSession` upload tasks, one per piece; the Mac uploads while the app is open.

## Not verified

- **Not yet verified on a Raspberry Pi, on exFAT or with a real Downloads folder.** The rename between folders on the same exFAT drive is the same call converting uses.
- Which control files other download programs leave, beyond the generic list.
- `/proc` shows only the processes of Lobby's own user. A program running as another user (a system service) that has a file open is not seen; the wait for a quiet file is the only guard then. On the server, check which user writes the Downloads folder.
- Uploads over a real network from a real iPhone in the background, and how often iOS lets background pieces run.

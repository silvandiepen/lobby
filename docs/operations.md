# Operating a Lobby server

This guide is for whoever runs a Lobby Server for a household. Lobby Server runs on any computer that stays on: a Raspberry Pi, a NAS, an old Mac, a mini PC, with Linux or macOS. How it is installed, updated and removed, and what differs on a Mac and in Docker: [release.md](release.md). The installer and archives are built and tested on macOS and, in the release workflow, on Linux.

## First setup

1. Record the computer's model, OS and architecture, media mount points, free space, and whether Tailscale is connected. Verify connectivity from one intended client. If another media server runs there, keep it available for comparison while you try Lobby.
2. Install Lobby Server with `install.sh` ([release.md](release.md#the-installer)) as the user it should run as, with a service that starts at boot. Assign read access to existing media. Give write access to staging, the selected upload destination, the catalogue and cache.
3. Select the library roots and a persistent location for the catalogue. Bind the service on the intended private interface, configure trusted HTTPS, and claim the first manager from the local setup flow.
4. Enter the metadata provider credential on the server. Start the scan. A visible status shows discovered files, indexed titles, incomplete files, failed lookups and items needing review.
5. Pair the Mac and one viewer. Try a film and one episode locally, seek within both, then try the same titles remotely. Test the iPad download with networking disabled.
6. To add a household member, approve their device and choose a profile. On a shared TV, pair once and present the household profile picker. Check the approved Tailscale route on devices that will connect remotely.

## Settings in the app, and the first setup

**Built (server and apps).** A manager changes most of the server in the app (Settings → Server), and sets a fresh server up there: name, library folders picked from the server's own drives, the TMDB key or none, then the first look through the folders. [api.md](api.md#server-settings) lists what can be changed and what restarts.

- **Where a setting comes from.** `lobby.config.json` keeps what the server starts from: `host`, `port`, `dataDir`, `ffmpegPath`, `ffprobePath`, `claim`, `backup.dir`, the cache folders and the outside entrance (`outside`, apart from the direct connection's upload limit). Everything a manager can change is kept in `<dataDir>/settings/settings.json`, and for those keys it wins over the file. The first start with this version makes that file from `lobby.config.json`, so nothing changes then; after that, editing those keys in `lobby.config.json` does nothing, and the server says so in its log at start. Order: the settings store, then the file, then the defaults. The TMDB key is in `secrets.json`; `LOBBY_TMDB_API_KEY` in the environment wins over it, and the app then cannot change it.
- **Versions.** Every change is a new version; the 50 before the current one are in `<dataDir>/settings/history/`. A manager restores one in the app. On the server, with it stopped: `lobby settings` shows the current one, `lobby settings history` lists them, `lobby settings restore <n>` uses one again. Each change, refusal and TMDB key change is in the audit log in the catalogue (`settings_audit`). Backups carry `settings.json`, and a restore into an empty data folder puts it back.
- **Restarting.** For a setting that cannot change while it runs, the server answers first, closes down cleanly and exits with code **75**. Both systemd units start it again (`RestartForceExitStatus=75` in the installer's units; the user unit restarts on any exit anyway). launchd and Docker set no `INVOCATION_ID`: the installer's launch agent and the image set `LOBBY_SUPERVISED=1`, which makes the server exit the same way. Without either (as with `npm run server:dev`) it starts again in the same process.
- **Fresh server.** A config without `roots` is fine: nothing is looked through until a manager has claimed the server, picked folders and finished the setup in the app. A server that had folders when it first started with this version is never asked to set up again.
- **Folders.** Only folders below the mounted drives (`/proc/mounts` on Linux, `/Volumes` on a Mac; in a container, what is mounted into it) and the service user's home folder can be picked, without hidden folders and links that lead elsewhere. Lobby still only reads library folders.

## Moving from Plex or another media server

Lobby can run beside another media server on the same folders: point Lobby at them read-only first. Compare counts by media type, inspect a few remakes and season mappings, then test actual files with audio and subtitles on each target device. DVD ordering, Plex-managed collections, chosen posters, and watch history may need reconciliation. Raw media scanning cannot reconstruct all Plex-specific state. Keep a backup of the other server's data before retiring it, and retire it only once the comparison and the offline tests are good enough for the household.

## Backup and recovery

The media drive holds originals. Back it up independently of the catalogue. For recoverable household state, use a consistent SQLite backup plus configuration, manual matches, collection memberships and profile progress. Keep enrollment secrets in protected storage. Re-fetch replaceable artwork when practical. Test restoration to a separate data directory before relying on backups.

**Built.** The server backs the catalogue up once a day into `backups/` in the data folder and keeps the newest seven (`backup.dir`, `backup.keep`, `backup.everyHours` in the config). Each backup is a folder named by its UTC time holding `lobby.db` and a copy of the config. `lobby backup` makes one now, `lobby backups` lists them, and `lobby restore <backup>` puts one into a data folder that has no catalogue yet; it refuses to replace an existing one. Paired devices, viewers, progress, matches and collections come back. Devices that were removed since the backup stay removed: the server keeps `revoked-devices.json` in the data folder and in the backups folder, and a restore reads it, and the other backups. Keep that file with the backups when you copy them elsewhere; without it, and without a later backup, a device removed since would be let in again, so look through the devices after a restore. A restore stops at a list it cannot read. The outside entrance is off after a restore, no device is let in there or may control others from there, and devices that were waiting to be paired start again. If no manager is left the server is claimed with the setup secret. `secrets.json` is never in a backup, so the TMDB key is entered again after a restore. The backups live on the same disk as the catalogue: copy the `backups` folder elsewhere to survive a dead disk.

Statistics (what is watched, when and by whom; docs/api.md, Statistics) are kept for `statistics.keepDays` days, 730 by default, a setting in the app under General. Older sittings, counts and the music play history are deleted by the server itself; they are in the backups for as long as those are kept.

On mount loss, mark affected items unavailable and suspend destructive reconciliation. On return, verify root identity, then rescan incrementally. On provider failure, continue serving cached data and retry with a bounded queue. On server failure, finished downloads continue playing on the device.

| Symptom | First checks |
| --- | --- |
| New movie missing | Correct root, mount online, file readable, copy finished, scan job status, Needs Review. |
| Wrong season or remake | Inspect parsed title/year or episode order. Lock the chosen match and verify over a rescan. |
| Plays at home, fails away | Check the server's power, tailnet connectivity, permissions, certificate host name and home uplink. |
| Slow playback or missing subtitles | Inspect container, bitrate and selected tracks. Test direct play on the target. Prepare a compatible copy on Mac if needed. |
| Download stalls | Check storage, partial transfer revision, network route and expired device permission. Retry the affected episode. |

Keep logs local and bounded. Include job IDs and actionable failure reasons, redact credentials and avoid publishing household filenames in diagnostics.

## Reaching the server away from home

**Built (the server's part).** List where the server can be reached from outside the home network under `addresses.remote` in the config, for example `{ "addresses": { "remote": ["http://lobby.example.ts.net:8674"] } }` for its name in the household's tailnet. Each entry is an `http://` or `https://` address without a path; a wrong one stops the server from starting, with the entry named. Paired devices are told these addresses and try them when the home address does not answer. The list opens nothing: Tailscale, or whatever road is chosen, is set up outside Lobby, and the server must listen on an interface that road reaches (`host`). A name of another kind than those in [api.md](api.md#who-may-ask), for example one in the household's own domain, must be listed here: requests for a name the server does not know are refused.

## The direct connection

**Built (the server's part); not yet verified on a Raspberry Pi.** Off until `outside.direct` is in the config; [outside.md](outside.md#the-direct-road) has the steps. `lobby direct id` prints the box id for the introducer, `lobby direct rotate` takes the next certificate, `lobby direct reset` forgets all keys. The keys are in `direct/keys.json` in the data folder, mode 600, and deliberately in no backup: with a new data folder the box is a new one, and every device connects at home once. If the keys cannot be read the server starts without the direct road and says so in the log; they are never replaced by themselves. The log names devices by id and paths by kind (`srflx/srflx`), never an address; the access log keeps the address ICE saw for 30 days, like the other roads.

## Push notifications

**Built (server and apps).** With push, a child's question (Ask first, [kids-control.md](kids-control.md)) reaches the grown-ups' iPhones, iPads and Macs as a notification with Watch, Listen and No, also when Lobby is not open, and a device that waits to be paired tells the household's admins. Lobby Server sends them through Apple's push service (APNs) with a token-based key.

**Three ways (`push.mode`, D-064).** `relay`: through the push relay, which holds the publisher's key, so any Lobby Server reaches the App Store apps without having it ([outside.md](outside.md#the-push-relay)); with `"push": { "relay": "https://lobby-push.vandipyan.workers.dev" }`, the publisher's relay, named in the config like the introducer. `direct`: with a key of your own, as below; what a config with `push.apns` and no mode does. `off`: nothing. `GET /v1/settings/push` says which.

**Who can push to which apps.** APNs accepts a notification only when it is signed with a key of the Apple developer team that signed the app, for that app's bundle id (the *topic*). The App Store builds of Lobby are signed by the publisher's team, and that key is not shared, so **a server you run yourself reaches the App Store apps only through the relay.** Pushing directly works when you build and sign the apps yourself, with your own team and bundle id ([CONTRIBUTING.md](../CONTRIBUTING.md#building-the-apple-apps)), and give your server a key of that team.

**Without push**, everything else works. The difference: a question or a pairing request is seen only by a grown-up's device whose Lobby app is running (the app shows it at once over its live connection, and as a local notification while it runs in the background). A phone where Lobby has been closed for a while hears nothing until it is opened.

To push directly, for your own build:

1. **A key.** In the Apple developer portal (Certificates, Identifiers & Profiles → Keys), use or make a key with the Apple Push Notifications service enabled. One key serves all of a team's apps. Note its key id and your team id (ten characters each). Download the `.p8` file once and keep it out of any repository.
2. **The capability.** Your App ID needs Push Notifications; `project.yml` asks for it with `aps-environment`, and provisioning profiles made after that carry it.
3. **Copy the key to the server**, readable only by the user Lobby runs as (a key file others can read is refused):

   ```sh
   mkdir -p ~/lobby/keys && chmod 700 ~/lobby/keys
   # copy AuthKey_ABCDE12345.p8 there, then:
   chmod 600 ~/lobby/keys/AuthKey_ABCDE12345.p8
   ```

4. **Name it in `lobby.config.json`** (a relative path is from the config file). `topic` is your build's bundle id; set it, because the default is the App Store apps' id:

   ```json
   "push": {
     "apns": {
       "keyFile": "keys/AuthKey_ABCDE12345.p8",
       "keyId": "ABCDE12345",
       "teamId": "FGHIJ67890",
       "topic": "com.example.lobby"
     }
   }
   ```

5. **Restart the server.** Server Settings say "Push notifications: on" (`GET /v1/settings/push` → `{ "configured": true }`), and nothing more of the key. The log never shows the key.

The apps register when they start and send their token with the environment of their build: `development` (built from Xcode, APNs sandbox) or `production` (TestFlight and the App Store); the server sends each to the matching one.

## Waking the Apple TV

**Built (server and apps).** Play On can turn an Apple TV on and open Lobby on it, so a film can be sent to a TV that is asleep ([api.md](api.md#waking-an-apple-tv), D-046). Lobby Server does it with [pyatv](https://pyatv.dev) over Apple's Companion protocol. That protocol is Apple's own and not offered to others; pyatv speaks it by having worked it out. **A tvOS update can break it**, and then waking fails with a reason while Play On falls back to AirPlay as before. It is optional: without it nothing changes.

1. **Install pyatv in a virtual environment** of its own, as the user Lobby runs as. pyatv 0.18 wants Python 3.10 or later; srptools 2 breaks its pairing, so pin it below 2:

   ```sh
   # Debian or Raspberry Pi OS: sudo apt install python3-venv
   # macOS: the Python from python.org or Homebrew
   python3 -m venv ~/lobby/pyatv
   ~/lobby/pyatv/bin/pip install "pyatv==0.18.0" "srptools<2"
   ~/lobby/pyatv/bin/python3 -c "import pyatv; print('ok')"
   ```

2. **Tell Lobby where it is**, in `lobby.config.json`, and restart:

   ```json
   { "remote": { "wake": { "pyatv": "/home/me/lobby/pyatv/bin" } } }
   ```

   `pyatv` is the venv's `bin` folder; Lobby runs its `python3` with `apps/server/tools/wake.py`, and never a program named elsewhere. Optional: `storage` (pyatv's credentials file, default `~/.pyatv.conf` of that user), `hosts` (IPv4 addresses of the TVs, when multicast does not reach them, as in some Docker networks), `app` (the bundle id of the Lobby app on the TV, default `mt.sil.lobby`, the App Store app's; set it for your own build), `holdPlaySeconds` (how long Wake and Play keeps the play for a TV that is slow to open Lobby, 15 to 900, default 180). Whether TVs are woken at all is a setting in the app (`remote.wake.enabled`, on by default). Whether kids mode may wake one too is another (`remote.wake.kids`, "Kids can turn on the TV", off by default). A third (`remote.wake.pickProfile`, "Get past “Who is watching?”", on by default) has Lobby press select once on a TV that asks who is watching after it wakes: that picks **whichever profile is focused**, normally the last one used. To have no picker at all, switch off showing profiles on wake on the TV (Settings → Users and Accounts). The path is only in the file, like `ffmpegPath`: a setting in the app must not choose a program to run.

3. **Connect each TV** in the app: Settings → Server → Apple TVs → Look for Apple TVs → Connect. The TV shows a code; type it in the app within a minute. Then confirm which Lobby device it is: tvOS tells an app nothing the Companion protocol knows, so the app suggests the Apple TV with the same name, and a manager confirms. A TV that was paired by hand (`~/lobby/pyatv/bin/atvremote --id <id> --protocol companion pair`) into the same `~/.pyatv.conf` shows up as connected after a look.

The credentials file is the helper's: it keeps it readable by that user only (mode 600), Lobby never reads it, and no log or answer has a credential or a code. It is not in Lobby's backups; after a new install the TVs are connected again. "Disconnect" makes Lobby forget the credentials; the TV lists "Lobby" under Settings → Remotes and Devices until it is removed there.

In Docker, pyatv is not in the image, which has no Python ([release.md](release.md#the-container-image)); leave waking off there, or build an image of one's own with it. The container needs the host network for multicast, or `hosts`.

| Symptom | First checks |
| --- | --- |
| "Apple TVs cannot be reached now" | The Apple TVs page shows why: no Python at that path, or pyatv not installed in it. |
| Not found on the network | The TV is plugged in and on the same network; try `hosts` with its address. |
| "No longer accepts Lobby Server" | The TV was reset or Lobby removed on it: connect again. |
| Woke, but stopped at "who is watching" | With `remote.wake.pickProfile` on, Lobby presses select after about 6 s; the log says "Pressed select on a woken Apple TV". Off, or still there: pick a profile on the TV, and the film starts within `holdPlaySeconds`. |
| Woke, but the film did not start | The log says "Lobby did not come up on a woken Apple TV" (it never opened), "A play for a woken Apple TV was not taken in time", or "…was not allowed any more" with the reason. An Apple TV with a Lobby from before D-056 opens on what it showed before. |

## Music and audiobooks

**Built (the server's part).** Add the folders to `roots` with the hint `music` or `audiobooks`, for example `{ "path": "/srv/media/Music", "name": "Music", "hint": "music" }`, and restart. `group` and `logo` do not apply to them, and two audio folders may not lie inside each other. Files are only read. Covers come from the files or from `cover`, `folder` or `front` (`.jpg`, `.jpeg`, `.png`) beside them.

Compact and converted copies are kept in `cache/music` in the data folder: `"music": { "cacheDir": "…", "maxCacheGb": 5, "minFreeGb": 2 }` are the settings and their defaults. Scaled covers are in `cache/music-covers`. Both can be deleted while the server is stopped and are made again. On a computer with a slow system disk (an SD card, for example), point `music.cacheDir` at a faster one, never inside a library folder; a 4-minute song takes about 8 MB at 256 kbit/s.

The apps show music as soon as a folder of either kind has files (D-044). To try it without real music, `tools/music-sample/make-library.sh <folder>` writes an invented library of tones and drawn covers into `<folder>/Music` and `<folder>/Audiobooks`.

Playlists, favourites, history, places in books and edits are in the catalogue and so in its backups. A file that is gone for thirty days is forgotten, and leaves playlists then; a missing drive forgets nothing. The first scan reads one file at a time at low priority.

## Converting old files

**Built; not yet verified on a Raspberry Pi.** Off until the config names a folder:

```json
{ "conversion": { "dir": "/media/<drive>/.lobby", "hours": "01:00-07:00", "repackage": false, "server": true, "minFreeGb": 5 } }
```

- `dir`: Lobby's own folder **on the same drive as the library and outside every library folder** (the server refuses to start otherwise). Also keep it outside every folder another media server indexes. The service user needs write access to it and to the library folders, because replacing a file is a rename out of and into them. Without `dir` nothing is converted and no library file is ever moved.
- `hours`: when the server itself converts, local time; may cross midnight. Leave it out for any hour. The server also waits until nobody has played or downloaded anything for five minutes.
- `repackage`: also turn MKV files with a good picture into MP4. Off by default.
- `server`: set to `false` to leave all converting to Macs.

What it does to files, how to read the queue, and what to do after a power cut are in [conversion.md](conversion.md). In short: originals that were replaced are in `<dir>/originals/` and stay there until a manager purges them one by one; after any interruption the server finishes or takes back the replacement by itself when it starts; if `GET /v1/conversion` shows `needsAttention`, files are in two places at once and Lobby will not choose, so look at `<dir>/journal/`.

## Intros and credits

**Built; not yet verified on a Raspberry Pi.** Nothing has to be set: the server reads the chapters of every film and episode, and compares the sound of the episodes of each season to find their intros and credits (D-059), at the same `conversion.hours` and only while nobody watches, one file at a time at the lowest priority. Without `conversion.hours` that is at any hour, still only when nobody has played anything for five minutes. The fingerprints are in `cache/markers` in the data folder (about 55 KB an episode, some 55 MB for 1,000 episodes, written a little at a time); they can be deleted while the server is stopped and are made again. Where the data folder is on a small drive that should hold only the system, put them elsewhere with `"markers": { "cacheDir": "…" }` in `lobby.config.json`, as `playback.cacheDir` and `music.cacheDir`: an absolute path or one relative to the config file, never inside a library folder (the server refuses to start), on a drive Lobby may write to (a systemd unit with `ProtectSystem=strict` needs it in `ReadWritePaths`). Changing it means a restart; the old folder can be deleted. `GET /v1/markers` says how far it is; a server admin has a season looked at again from the season's More menu (**Find Intros and Credits Again**), at once. A file it could not read three times is left until it changes.

## Import folders and uploads

**Built; not yet verified on a Raspberry Pi.** What it does: [imports.md](imports.md). Two things must be in place first:

1. **Lobby's folder** (`conversion.dir`, above), on the media drive and with its marker: moves are journalled there and uploads are received there. Without it files of import folders wait in the Inbox and uploads are refused.
2. **Write access** for the user Lobby runs as: to the library folders that receive imports (Films, Series), to the import folders (a move takes a file out of them; clean-up removes leftovers), and to Lobby's folder.

Then, in the app, Server Settings → Import folders → Add, and pick the folder with the browser, for example a Downloads folder on the media drive. It starts as *listed where it is*: its finished files appear in the library under a category named after it, and nothing there is moved. Switch it to *move into the library* only when nothing needs its files where they are; otherwise move single files from the Inbox. Or in the file, before the first start with the settings store:

```json
{ "import": { "folders": [{ "path": "/media/<drive>/Downloads", "mode": "index" }], "waitMinutes": 10, "copyAcrossDrives": false },
  "uploads": { "maxFileGb": 100, "quotaGb": 500 } }
```

- An import folder must not be inside, or contain, a library folder, the data folder or Lobby's folder: the server refuses it.
- `waitMinutes`: how long a file must keep its size and date. Raise it when files land slowly.
- The check for a file another program has open sees only the processes of Lobby's own user. When the files are written by another user, the wait is the only guard.
- What was moved where is in the Inbox's history (`GET /v1/imports/activity`); a move interrupted by a power cut is finished or taken back at the next start, from `<conversion.dir>/imports/journal/`.

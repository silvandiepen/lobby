# Status and roadmap

What exists, what is being checked, and what is open. [product.md](product.md) says what Lobby is;
[architecture.md](architecture.md) how it is built. Topic docs end with a "Not verified" section
where something is built but not yet tried on real hardware.

## Built

- **Lobby Server 1.0.0**: scanning and matching, the catalogue, pairing and devices, playback
  repackaging for Apple devices, conversion of old files, Skip Intro, music and audiobooks, search,
  statistics, Play On and waking an Apple TV, push notifications, kids limits and kids control,
  households, import folders and uploads, settings in the app, backups. Released as archives with
  an installer and as a container image ([release.md](release.md)).
- **The outside entrance**: the direct road (lobby-direct and the introducer, server and apps) and
  the relay road on the server ([outside.md](outside.md)).
- **The Apple apps**: iPhone and iPad, Mac and Apple TV, with downloads, uploads, remote play,
  kids mode and several servers in one app.

## Being verified

These are built and tested, but not yet proven on every kind of hardware and network:

- The relay road against a real relay.
- Long runs on a Raspberry Pi with a large library: full-scan time, peak memory, simultaneous
  streams, background downloads.
- What each topic doc lists under "Not verified".

Results are recorded with their test environment, in the topic doc they belong to.

## Acceptance checks

The checks a change to playback, downloads or the catalogue should keep passing:

| Check | What has to work |
| --- | --- |
| Folder to iPad | A season copied into a watched folder appears on a paired iPad; play, seek, download, turn networking off, relaunch, finish the episode offline. |
| A catalogue to trust | An incremental scan of a large library; remakes, specials, combined files and home videos come out right; chosen artwork and matches survive a restart and a folder rename. |
| Ingestion | An upload from the Mac while another file arrives in an import folder; an interrupted upload resumes; a restart mid-scan; every finished file appears exactly once. |
| Several viewers | Two viewers on one Apple TV, resume on a phone, one viewer's progress never overwrites another's. |
| Recovery | Restore a catalogue backup, a missing mount, an iPad close to full. |
| Playback | A typical DVD-derived file, a second audio track, subtitles, an unsupported format, a long seek near the end. |
| Refusals | The metadata service away, an expired pairing code, a viewer trying to upload or change a match, a kids viewer asking for a title outside its limits. |
| Offline | With the server off, Downloads opens at once with the finished items playable; removing a download leaves the server's copy. |

## Open

- Storage beyond local and mounted folders, such as a private object store: it would need someone
  to publish the catalogue, short-lived authorised links and renewal during long downloads.
- A web interface.
- Plugins ([plugins.md](plugins.md)).
- Push for self-hosted servers with the App Store apps: APNs needs the key of the team that signs
  the app, so push works for a server whose operator built and signed the apps themselves
  ([operations.md](operations.md)).

## Out of scope

- Transcoding live for every device: Lobby repackages, and converts files that need it once,
  ahead of time ([playback.md](playback.md), [conversion.md](conversion.md)).
- Paid cloud storage, accounts or subscriptions.

References: [TMDB FAQ](https://developer.themoviedb.org/docs/faq),
[Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/).

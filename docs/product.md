# What Lobby is

Lobby turns the films, series and music a household already keeps on a drive into a library
everyone in it can recognise, on every Apple device they own. Lobby Server runs on a computer that
stays on (a Raspberry Pi, a NAS, an old Mac, a mini PC; Linux or macOS). The apps for iPhone,
iPad, Mac and Apple TV pair with it. There is no Lobby account, no subscription and no cloud
library: the files stay where they are, and the household runs the server.

How it is built is in [architecture.md](architecture.md); what is built and what is next is in
[delivery.md](delivery.md).

## What each part does

| Part | What a household does with it |
| --- | --- |
| Lobby Server | Watches folders, identifies films and episodes from their names, finds artwork, summaries and trailers at TMDB (with the operator's own key), keeps the catalogue, each viewer's progress and statistics, and serves video in a form Apple devices play. |
| iPhone and iPad | Browse, search, play and resume; pick a viewer; download films, episodes or seasons to watch offline; play on another device; manage the server for a manager. |
| Mac | The same, plus uploads (drag files or folders onto the window) and a roomy place to correct matches, artwork and categories. |
| Apple TV | Choose a viewer, browse by artwork, resume, Up Next and Skip Intro, and be the screen other devices play on (Play On). Lobby can wake it to play. |

## A typical evening

A parent copies a season into the series folder, or uploads it from the Mac. Once the files have
stopped changing, the server indexes them and the season appears in Recently Added. Opening the
show lists its seasons in order; Resume takes the active viewer to their unfinished episode, and
after the credits Up Next offers the next one. Changing viewer restores that person's place.

Before a trip, a season is downloaded on the iPad. Downloads open and play with the server out of
reach, and progress made offline is sent when the iPad is back.

## Who may do what

- **Server admin.** Runs the server: library folders, settings, households, devices.
- **Household admin.** Manages one household on the server: its devices, viewers, kids rules and
  invitations. A server can host several households (family elsewhere, friends) that share the one
  library, each with its own viewers and history (D-052, D-053).
- **Viewer.** A paired device that browses and plays. A device can hold several viewers (people);
  each viewer has their own progress, Up Next and statistics.

A device pairs once, with a short code a manager approves or an invitation. Family members with
separate Apple Accounts each pair their own devices. The server decides every permission; the app
only shows what the server allows.

## Kids

A viewer can be a kids viewer and a device a kids device. The server then decides which titles a
child sees (kids limits, by category), and when and what kind (kids control: schedules, places,
"Ask first" with an answer from a grown-up's phone). A grown-up leaves kids mode through a gate.
Everything is enforced on the server and fails closed. [kids.md](kids.md) describes all of it.

## Organising the library

Films and series are the main sections. Categories (with categories inside them) group titles the
way the household thinks of them, and studios get their own pages. Genres come from the match. A
manager corrects a match, a title or the artwork once, and the correction holds through rescans,
renames and new matches. A family-friendly genre alone never lets a kids viewer see a title.

## Reaching it

At home the apps find the server on the network. Away from home they use Tailscale where it is set
up, or the outside entrance: a direct connection found through an introducer, with no port opened
at home ([outside.md](outside.md)). The operator turns the outside entrance on; it is off by
default.

## Boundaries

- Lobby plays what the household already has. It does not download, buy or stream from elsewhere.
- Not built yet: a web interface in the browser, storage other than local or mounted folders
  (for example an object store), and enrolment through Apple Family Sharing.
- Plugins are designed, not built ([plugins.md](plugins.md)).

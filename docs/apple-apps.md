# Apple apps and visual direction

Build the Apple clients in one Swift 6 project generated with XcodeGen. Share catalogue models, networking, pairing, metadata, playback coordination, progress reconciliation, and offline state. Use platform-specific navigation, keyboard commands, and tvOS focus behavior. Uploading is for a manager's Mac, iPhone and iPad (docs/imports.md); the Apple TV has none. Viewer actions such as local deletion must never delete source media.

## Main screens

| Screen | Interaction and state |
| --- | --- |
| Connect | Discover or enter a trusted server, verify its name, pair, choose a profile. Remember the server address and device grant. Explain an unreachable server separately from a revoked grant. |
| Library | Continue Watching per viewer, Recently Added grouped by season, then Movies, Series, and Categories. Expose search from the main navigation. A newly paired empty library explains how the owner adds media. |
| Movie | Poster or backdrop, title, year, duration, categories and summary. Play or Resume is primary. Trailer, audio/subtitles, availability and local download are secondary. |
| Show and season | One show entry, season selector, full episode titles, runtime, played state, and device download state. Download Season previews bytes and available space. |
| Downloads | Works from cold launch with the server offline. Distinguish queued, downloading, paused, failed and verified. Show episode counts and size before removing local files. |
| Upload and the Inbox | Built. Mac: drop files or folders on the window, or File → Upload… (⇧⌘U). iPhone and iPad: Settings → Imports and Uploads → Upload → Upload from Files, also from a connected drive; pieces go on in the background. Choose Movies, Series or a library folder; progress per file, pause, resume, stop. The Inbox (also in Settings → Imports and Uploads) shows what waits, what is still being written, what was left out and what arrived; a file is confirmed with its kind, title, year and place. Not yet: previewing an episode before it is placed. |
| tvOS player | Resume from the selected viewer, remote-friendly seeking, audio and subtitle options, and a clear Play Next action. Return focus to the same item after closing playback. |

## Server settings and the first setup, as built

On iPhone, iPad and Mac a server admin has the **Server** group of Settings (see the Settings map above): General, Library Folders with a browser of the server's own drives, Imports and Uploads, Matching (the TMDB key: set or not, replace, remove; never shown), Converting, Apple TVs, Speakers, Away From Home, Households, Statistics, Backups and Advanced, with every setting as stored and the earlier versions to go back to. Each page collects its changes and sends them together: **Review…** asks the server what they will do and shows its words before **Save**; a change that needs a restart says so on the row and on the button, and the page waits until the server answers as a new start. After claiming a fresh server the app offers the first setup over the library: a name, the folders and what is in each (films, series, home videos, music, audiobooks; for the children or not), a TMDB key or Skip, then the first look through the folders with what was found so far. "Later" puts it off until the app starts again; Settings offers it again meanwhile. The Apple TV shows only that the server is being set up, and where that is done. The code is `ServerSettingsModel`, `ServerSetupModel` and `Views/Manage/ServerSettingsView.swift` (`ServerSettingsPage`), `ServerSetupView.swift`; [api.md](api.md#server-settings) is the contract.

## Settings map

D-069. Settings is a short list in groups, as in the system's Settings app; each row opens one page about one subject, with a one-line note at its foot. A narrow window pushes the pages; a wide one (iPad, the Mac's Settings window) shows the list beside the page. Search on the list finds a page by its name, the words on it and the titles of the server's settings on it. The list is chosen by `SettingsMap` (`Shared/Models/SettingsMap.swift`) from who is in front: **V** any viewer, **H** a household admin (and a server admin), **S** a server admin. Kids mode sees only About; the kids screens have no way into Settings at all, and the Mac's Settings window says it is for grown-ups.

| Page (group) | What is on it | Who | Was |
| --- | --- | --- | --- |
| You (You) | The viewer's picture; Your Month in Lobby | V | Settings → This Device; viewer menu |
| Playback (You) | Next episode, countdown, start at the credits, suggestions after a film, "still watching" | V | Settings → This Device → Playback |
| Subtitles (You) | Languages, forced subtitles, size, background | V | Settings → This Device → Subtitles |
| Intros and Credits (You) | Skip intro, show next episode | V, not a kids viewer | Settings → This Device |
| Connection (This Device) | Server name, household (guest), address, status, version, road; Use the Direct Connection; Sign Out | V | Settings → Lobby Server, Direct Connection, Sign Out |
| Servers (This Device) | The servers on this device: add, rename, look, order, remove; Ask Which Library at Start | V, not a kids device | Settings → Servers |
| This Device (This Device) | Device name and role; Others Can Play on This Device | V | Settings → This Device |
| Downloads (This Device) | Download over Mobile Data; space used; Downloaded Only | V | Settings → Downloads |
| Kids Mode (This Device) | Kids Icon in Kids Mode; Trailers in Kids Mode | V | Settings → This Device, Kids Mode |
| Devices (Household) | Waiting to connect, the devices (each opens its page), type a code, Invite Someone, Add a Device (guest), the server's status | H | Devices and Viewers |
| Viewers (Household) | The viewers (each opens its page: kids, limits, intros), Add a Viewer, remove | H | Devices and Viewers |
| Kids (Household) | The kids viewers (to their plan), Code for Grown-ups | H | Devices and Viewers |
| Categories (Household) | Arranging the categories (iPhone and iPad; the Mac has it in its sidebar) | S | Settings → Household |
| Household Statistics (Household) | The household's overview | H, not S | Settings |
| General (Server) | Name, show on the home network, language of titles | S | Server Settings → General |
| Library Folders (Server) | The folders, what is in each, for the children; look through everything every… | S | Server Settings → Library Folders |
| Imports and Uploads (Server) | Import folders, Inbox, wait, copy between drives, upload sizes; Upload | S | Server Settings → Import Folders; Devices and Viewers → Upload |
| Matching (Server) | The TMDB key | S | Server Settings → Matching |
| Converting (Server) | Lobby's folder, hours, the server converts, repackage MKV, keep free | S | Server Settings → Converting |
| Apple TVs (Server) | Wake Apple TVs, kids can turn on the TV, the TVs; Get past "Who is watching?" | S | Server Settings → General and → Apple TVs |
| Speakers (Server) | Play on HomePods and speakers, the speakers | S | Server Settings → Speakers |
| Away From Home (Server) | Addresses away from home, upload limit; Access From Outside | S | Server Settings → Away From Home; Devices and Viewers |
| Households (Server) | Guest households, invite one | S | Settings, Server Settings, Devices and Viewers |
| Statistics (Server) | What is watched on the server; keep viewing history | S | Settings → Statistics; Server Settings → General |
| Backups (Server) | Back up every, backups to keep | S | Server Settings → Backups |
| Advanced (Server) | Wait for copies, files read at once, space and number of prepared copies, music copies, any setting of a newer server; All Settings as Stored; Earlier Versions | S | Server Settings → Advanced |
| About (About) | Version, Suggest Updates, Check for Updates, Acknowledgements, the TMDB notice | everyone | Settings → This App |

The server's settings are reviewed per page: a page's bar (Undo Changes, Review… or Review and Restart…) holds only that page's changes, and the restart notice shows on the page that made it. A change left on another page waits there. On the Apple TV, the viewer page keeps the few settings it has (switch viewer, picture, playback, servers, kids icon, updates, sign out). The iPad and Mac sidebar's Devices and Viewers shows the household's devices and viewers together, without the server's pages, which are in Settings.

## Households, as built

D-052. A manager of the owner's household has **Households** in the Server group of Settings: the guests with how many devices and viewers each has, **Invite a Household…** (name, the whole library or chosen groups and categories, from outside, a speed limit for all their devices, a number of devices, how long the invitation lasts), then the invitation's code, QR code and link (`lobby://pair?i=…&c=…&h=<household>&s=<server>`) to send. A household's page changes the same, lists its devices (not what they watch), takes invitations back, invites another manager, pauses and removes it. The invited device's request shows under Access From Outside, marked as invited; it becomes that household's manager. On the guest's side the link or code goes into Pair From Outside, which says whose household and whose server it joins. A guest household's manager sees the Household group of Settings (and Devices and Viewers in the sidebar) for their own household, with the server's name and their household at the top, and **Add a Device** opens their own window from outside: the same code, QR code and six digits. Editing titles, categories, server settings, Apple TVs and the households are not there for them. Settings and the Apple TV's viewer page say whose household a guest's device is in. The code is `HouseholdsModel`, `Views/Manage/HouseholdsView.swift`, and `OutsideModel` for both kinds of manager; LobbyKit's `Client/Households.swift`.

## Music, as built

D-044. A **Music** tab on iPhone, a **Music** section in the sidebar on iPad and Mac (Music, Artists, Albums, Songs, Stories, Playlists, Favourites), and a Music tab on the Apple TV to browse albums and books and play them. Pages take their colours from the covers. The mini player sits above the tabs, or at the foot of the content on iPad and Mac; it opens the full player: cover, scrubber, previous / play / next, shuffle, repeat, the sleep timer, AirPlay, and Up Next to reorder; for a book its chapters, ±15/30 s and the speed. Albums, playlists and books download from their page and are listed under Music on the Downloads screen; offline the same pages show what is on the device. The code is `Shared/State/MusicModel.swift`, `MusicPlayer.swift`, `Shared/Views/Music/` and `tvOS/Views/TVMusicViews.swift`; LobbyKit's `Music/` holds the catalogue, the viewer's store, the queue and the downloads. For trying it without a music folder, `tools/music-sample/make-library.sh` makes an invented library (the UI test server uses it).

**Stories** (D-067) are the audiobooks under one word. Home has **Continue Listening** under Continue Watching and a **Stories** row; Music's front page starts with Continue Listening; a tap on a begun story goes on at once. A film's page has **Story** when a story of the same name is there, and a story's page **Watch the Film** (`StoryFilms` in LobbyKit matches them by title). A story's credit leaves out a writer who is only its reader ("Read by …"). For children, the kids screens have a Stories place, a story page and a player of their own ([kids.md](kids.md#4-kids-music-and-stories)); `UITests/StoriesWalkthrough.swift` takes pictures of all of it against a server somebody set up for it.

## Categories inside a category, as built

The apps' half of D-040 and D-041. A category with others inside it is one tile and one sidebar entry. Its page has the banner of all of it, chips for All and each section (on the Apple TV tabs that stay put while the section below changes), a row per section, then the grid; a section shows its own rows and grid under the same banner. Kids pages do the same. Search finds sections by name. A title's `categoryIds` never name the parent: `Shelves` works it out from `parentId`, and `ruleCategoryIds` put a title on a studio category's page without moving it to that category's group. Without `parentId` (an older server) everything is flat as before, and a drag in a flat list still sends the plain order.

Managers arrange on **Categories**: dragging a row between a category's sections puts it inside, dragging it among top-level rows takes it out (a category with others inside stays top-level); the row's menu has Put Inside, Take Out and Add a Category Inside; **Make a Category of Several…** makes a new one around chosen categories, with new names for them and the logo and colour of one (`logoFrom`), in one arrangement. **Undo the Last Arrangement** shows while the server's undo token is there. Any change that the server answers with `409 kids_confirmation` opens a sheet with per child how many titles would appear and a few of them; Allow sends it again with the token, Cancel sends nothing. Studio suggestions are a card with the TMDB logo, Accept (into a group) and Dismiss; a category that follows studios says "Follows …". A kids viewer's page lists categories as a tree with Allowed, Blocked or what the parent or group says; ids the app does not know stay in the lists. The code is `CategoryTree`, `CategoriesModel`, `Views/Manage/CategoryArranging.swift`; `MacTests/SubcategoriesLook.swift` makes pictures of the screens with invented films.

## Skip Intro, as built

D-059. During an episode's intro the player shows **Skip Intro**: over the system player at the bottom right on iPhone, iPad and Mac, and as the system player's own contextual button on the Apple TV, where the remote's focus goes by itself. From where the credits start it offers Play Next (`PlayerModel.creditsStartMs` is where an up-next countdown begins). What each viewer wants is under Settings → Intros and Credits on their own device, and on a viewer's page for a manager, also for a kids viewer (a child's device cannot change it): Show Skip Intro, Skip Automatically or Off; Show Next Episode or Off. The remote on a phone that controls another device shows Skip Intro during that player's intro. A server admin has a season's intros found again from the season's More menu. The logic is LobbyKit's `Playback/SkipMoment.swift`; the button is `SkipIntroButton` in `Views/Player/PlayerOverlay.swift`.

## Design direction

Use compact near-black controls, subtly translucent surfaces, colorful recognizable navigation icons, generous poster art, and restrained motion. Use tinted fills for selection. Reserve focus treatments for actual keyboard or remote focus. Home screen labels must remain readable over bright cover art. Prefer native playback, menus, and platform navigation. Never start a trailer simply because a card has focus.

Adapt split navigation for Mac and wider iPad windows. Phone navigation should put Downloads within one obvious action from the library. Give the TV larger targets and readable titles at living-room viewing distance. Respect Dynamic Type where available, VoiceOver reading order, Reduce Motion, and Reduce Transparency. Pair color with text or symbols for downloaded, unavailable, and failed states. Announce season download progress without reading every percentage change.

## The Apple TV app as built

`LobbyTV` in `apps/apple/project.yml`, tvOS 18 or later (Apple TV HD and every Apple TV 4K; Tailscale's own app asks for tvOS 17). Screens are in `apps/apple/tvOS`; models, state, networking and the small drawn parts are the ones in `Shared`. `tvOS/Logic` has no screens and is also built into the Mac app, where `TVTests` runs it. Nobody has seen it run yet.

- **Connect.** Servers on the home network are listed; looking ends in words after ten seconds. Away from home the address is typed, under the same rules as on iPhone. The code is shown large, and a manager approves it from wherever they are. A TV never claims a new server.
- **Nothing is kept for offline.** tvOS gives an app only a cache, so there are no downloads, a manager's list for the device is not followed, and the library stays whole while the server is out of reach (`AppEnvironment.keepsDownloads`). The server is looked for again every 15 seconds then.
- **A slow link.** The film is sent as it is: the server makes no smaller version, so a link slower than the film pauses it. The player says so: buffering, how much of what the film needs is arriving, or that nothing arrives, with Try Again. Addresses get 10 seconds to answer instead of 4, pictures are fetched one size smaller on their own few connections, and closing the player does not wait for the server.
- **The player** is `AVPlayerViewController`, with Play Next as its contextual button. While the server still writes the copy, and for waiting, failures and the end of an episode, the app's own controls stand on the picture instead, so a growing stream never looks live.
- **Statistics:** the viewer page links to a simple summary of the viewer's week, month or year: the big numbers and what was watched most (`TVStatsPage`). Not while a kids viewer is in front.
- **Not there:** downloads, manager tools, trailers. The top shelf pictures are placeholders.

## Statistics

`Shared/Views/Stats`, from `GET /v1/stats/…` (docs/api.md, Statistics; D-060), drawn with Swift Charts on the page in the colours of what was watched most, headings as the home's shelves have them. What a device offers follows D-066 (`StatsAccess`): a server admin every viewer of every household and the server's page, a household admin their household's viewers and its overview, anyone else only the viewer in front, and kids mode no statistics at all. The server refuses the rest too; a refused page says why. Before a viewer's own page is asked for, the app tells the server on the live channel who is in front, and it does so at every switch of viewer.

- **A viewer's own.** "Your Month in Lobby" in the viewer menu and under This Device in Settings: cards with the big numbers, time per day (per month for a year), when as weekdays by hours, the most watched, series and how far along, genres, studios and categories, devices and how much away from home, listening and the top albums, and the history. Week, month, year or all. A sitting can be taken out of the history; a household admin can forget a viewer's history at the bottom.
- **A grown-up's view of a child.** On the viewer's page for a manager, "What … Watches": the same page, with screen time per day (watching and listening) and how much is in the evening and at weekends.
- **The household's.** Settings → Household Statistics for a household admin: the server's page cut to their household, without households, preparing and converting, the library or storage. Its viewers open their pages.
- **The server's.** Settings → Statistics for a server admin, at home: watched per day, busiest hours, the most watched by how many viewers, viewers, devices, households (others as totals until opened), where and how it was sent, data sent home and away, preparing and converting, the library by month, Play On and storage. Its viewers open their pages, in any household.

## Search

D-061. One field: while the server answers, titles by name come from the device's copy at once; then the server's answer (`GET /v1/search`) in groups, Films, Series, Home Videos, Episodes, People and Collections, each title with why it is there ("With Tom Hanks", "As Woody") and its ratings by source. Below, "Not in Your Library" (`GET /v1/search/outside`, asked after a short pause): posters from TMDB through the server, that open a sheet with every rating and Open on IMDb / Open on TMDB; on the Apple TV QR codes of those pages instead. Chips under the field (Kind, Year with From… To…, Rating with its source, Person with a role, Genre, Exact Title) write the query language (`SearchFilters`), and filters typed into the field show as chips to take out. A person opens their page: their titles here, then elsewhere. Recent searches are kept per viewer, on the device only. Kids mode has no chips and searches the library alone, within its limits. Without the server only titles by name are found.

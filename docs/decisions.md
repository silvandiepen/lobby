# Decisions

Choices made where the guides in `docs/` leave something open, with the reasons and what was rejected. Newest last; numbers are never reused.

How to read an entry: the title is the decision. Most start with a **Context** line (the problem), then the decision and its consequences, often with **Rejected** alternatives. An entry is decided unless its title says **Open** (being worked out; the build uses the stated default) or **Superseded** (a later entry replaced it). Code comments and other docs refer to entries by number (`D-027`).

To add one: take the next free number, write it at the end in the same shape (context, decision, consequences, rejected), and put it in the same change as the code it explains. To change a decision, add a new entry that supersedes the old one and mark the old title; do not rewrite history.

## D-001 Monorepo layout

`apps/server`, `apps/apple` (one XcodeGen project with iOS, macOS and tvOS targets, as `docs/apple-apps.md` asks), `packages/LobbyKit`. The public site is developed apart from the server and the apps.

## D-002 Server runtime: Node 24 with no build step

Node 24 LTS runs TypeScript directly and ships SQLite (`node:sqlite`). The server therefore has two dependencies (Hono and its Node adapter), no native addon to compile on the Pi, and deploying is copying files. The Pi's Debian packages Node 20, so the deploy script installs a private Node in `~/lobby/runtime` instead of changing system packages.

## D-003 The apps keep their own copy of the catalogue

`GET /v1/library` is an incremental sync of flat items, not server-built shelves. Downloads must open with the Pi unreachable, so the apps need the catalogue locally anyway; building Continue Watching and Recently Added on the device from that copy means one code path online and offline. The whole catalogue is a few megabytes of JSON.

## D-004 Scan progress is stored on the rows, not in a job table

A file is `discovered`, then `probed` or `failed` (with a retry time). A restart continues with whatever is still `discovered`. The spec lists a job entity; a separate table is added when something needs phases (uploads have their own, D-050).

## D-005 A new file must hold still before it is indexed

A file is indexed once it kept the same size and date across two looks at least `stabilityMs` apart. One look at the date is not enough: Finder stamps the original date on a file while it is still copying. The first scan of a library therefore walks twice.

## D-006 Files are identified by a fingerprint

The drive is exFAT, which has no stable file ids. A file's identity is its size plus a hash of its first and last 64 KB. A file that disappears and turns up elsewhere with the same fingerprint keeps its asset id, its item and the viewers' progress. A file's `revision` (used to invalidate downloads) changes only when its size or date changes, not when it moves.

## D-007 Item identity comes from file names

An item's identity key is built from the parsed title, year, season and episode. A provider match never changes it. So a corrected match cannot split or merge items, and ids that devices hold stay valid. When a rename changes what a file is called, the old item is removed, a new one is created, and progress moves to it.

## D-008 A missing drive is told apart from an emptied folder by its volume

When a root holds no video files and the catalogue expects some, the root's volume id decides: on another volume than before, it is an unplugged drive (everything is kept and marked unavailable); on the same volume, someone emptied the folder (files are marked missing). Either way nothing is deleted for 30 days.

## D-009 Device role, not profile role

The manager or viewer role belongs to the paired device, as `docs/architecture.md` lists it under device management. Profiles are viewers only: a name, a colour and their progress. (Later, kids limits bind a device to a kids viewer: D-027.)

## D-010 Credentials: random token, stored hashed, sent as header or cookie

A device credential is 32 random bytes; the server stores its SHA-256. The apps send it as a bearer header. AVPlayer cannot set headers through public API but does send cookies (`AVURLAssetHTTPCookiesKey`), so the same token is accepted as the cookie `lobby_device`. It never goes in a URL.

## D-011 Progress conflicts: later viewer action wins

Each update carries an operation id and the revision it was based on. A matching base applies. A stale base applies only if the viewer did it later (`updatedAt`, clamped to the server's clock) than what the server holds; otherwise the device gets 409 with the current state. That is what keeps a mark-unwatched from being undone by an iPad returning with last week's positions.

## D-012 Library folders are also categories

Each root has a display name, and items list the roots their files came from (`categories`). A household has often sorted its drive already (Pixar, Kids Movies and so on); the apps show those as shelves without anyone tagging anything. Two roots may share a name ("Disney" and "Disney II" both show as Disney).

## D-013 Playback of files Apple devices cannot open

Context: many libraries hold MKV, old AVI (MPEG-4, DivX 3) and AV1 files that Apple devices do not open. Decided, as built: the server repackages MKV without re-encoding (D-015) and converts old AVI films to H.264 on demand, one at a time, at 3 to 14 times real time on a Pi 5 ([playback.md](playback.md)). AV1 files stay unplayable with the reason shown: a Pi 5 converts 1080p AV1 at 1.4 times real time. Converted files can replace their originals (D-026).

## D-014 Reaching the server — Superseded by D-023, D-028 and D-034

Context: devices need a way to the server at home and away. The first default was HTTPS on the tailnet name through `tailscale serve`, and plain HTTP on the home network (Apple's local-network exception), with the device credential required on both. What was built instead: plain HTTP at home and over Tailscale (which encrypts underneath), the credential always required, the server telling paired devices its addresses (D-023), and, for devices outside the home and the tailnet, the outside entrance (D-028) over a relay or the direct road (D-034). HTTPS in front of the tailnet name is not built.

## D-015 Repackaged files: one fragmented MP4 with a growing HLS playlist

For a file whose picture Apple devices play but whose container they do not (MKV), one ffmpeg pass copies the video into a single fragmented MP4 and writes an HLS playlist that grows while it runs. Streaming starts from the playlist within a second or two; the finished MP4 is what a device downloads. Surround sound that has to be converted becomes AC-3, stereo becomes AAC. Faststart MP4 and fragmented MP4 over plain ranges were measured and rejected. Measurements, pitfalls and what the apps must do are in [playback.md](playback.md).

Copies are kept in `playback.cacheDir` (default `cache/playback` in the data folder, 20 GB, oldest deleted first) and can always be rebuilt. Where that folder should live depends on the machine: when the system disk is slow (a USB stick on a Pi), a folder on the library drive is better ([playback.md](playback.md)).

## D-016 The first device sets a fresh server up without a secret

Context: typing a setup secret on the first device is a step nobody should need. A server with no manager now gives the manager role to the first device that asks (`claim: "open"`, the default). What this trades away: until someone has set the server up, anyone who can reach it on the home network or the tailnet could do so first. The window is the minutes between first start and first use, the server says in its log that it is waiting, and `claim: "secret"` restores the setup secret for a household that wants it. Every later device still needs a manager's approval.

## D-017 Servers announce themselves on the home network

The server publishes `_lobby._tcp` over Bonjour with its name, port and id (`advertise`, on by default, off when it only listens on localhost), so the apps list it instead of asking for an address. It does not work across Tailscale, where the address is typed once.

## D-018 A manager may approve a waiting device without typing its code

Context: approving a new device should take one click. Managers see each waiting device with its code and approve it from the list. The code is now something to compare rather than proof of holding the device, so a manager who does not compare can be fooled by a device with a familiar name. Codes stay hashed in the database; the plain one is kept in memory only while it is on show.

## D-019 Categories belong to groups, and come from the folders

Context: a household wants films for adults apart from those for kids, with studios such as Disney and Pixar inside Kids. Each library folder names its category and, optionally, its group in the config; the order there is the order shown. `GET /v1/categories` gives the apps that structure, and items keep only category names. A manager can move single titles between categories (D-020). Since D-024 the config only names a new folder's category.

## D-020 A manager's edits lie over the automatic values

Edits are stored in `item.override_json` and applied when an item is read. The columns keep the automatic values, so lookups and rescans go on underneath and putting a field back is only forgetting the edit. `edit_revision` counts edits per item: the library revision also moves when a scan or lookup touches an item, which is no reason to refuse someone's edit. A match a manager chose is `locked`: it is refreshed by its id and never replaced. "No match" is `locked` without an id. When a rename turns a film or show into another item, its edits, chosen pictures and chosen match move along with the progress.

## D-021 What counts as an unambiguous match

Title and year decide, checked against the running time. Between namesakes: a film wins when its running time fits and the others' clearly do not, or when it has at least a hundred ratings and twenty times those of the others. A show wins when its episode titles are the files' titles in any order, or, with at least five numbered episodes and no titles, when it is the only one of its name that has them all and is not obscure. Everything else is left to a manager. Changing these rules bumps `MATCHER_VERSION`, which gives everything waiting for review another try.

## D-022 A manager's wanted list per device; the device fetches by itself

Context: a manager should decide, from one device, what is downloaded on each device. The server keeps a wanted list per device: titles, and rules of the form "the next N unwatched episodes of this series for this viewer". It resolves the list into files each time it is read, so a rule follows progress without anything being stored twice. The device polls its own list (cheap: an ETag) and reports what it has; the server never pushes. What the person downloaded themselves is reported with a flag and never touched by the list. Files that need a copy are prepared ahead through the playback module, one at a time and standing still while anyone watches. Such a copy may not evict anything in use or waited for, so a full cache shows as "does not fit" instead of a loop of preparing and evicting. Rejected: storing the resolved files (they go stale with every watched episode and every rescan); letting a device ask for playback of everything on its list (that is the interactive queue, and a season would hold the Pi's four cores against whoever is watching).

## D-023 The server tells paired devices its addresses; it opens nothing itself

The config lists where the server can be reached from outside the home (`addresses.remote`, http or https origins). Paired devices get them, with the home address, from `GET /v1/me`; the open `GET /v1/server` does not carry them, so a stranger on the network learns nothing about the household's tailnet or tunnel. The list is information only: which road in exists (Tailscale on every device, or a public HTTPS address) is D-014.

## D-024 Categories are settings in the catalogue, known by id

Context: categories cannot be hard-coded in the app; they are settings. Groups and categories, their order, icon, colour, logo and folders are rows with ids; titles, overrides and later rules (kids mode) refer to the ids, so a rename or move is only that. The config is read once per folder, when the folder is new to the catalogue, not once per server: a folder added later gets its first category the same way, joining a category of that name if there is one. One revision counts changes to the whole setup, because a move touches two groups and an order touches all.

Removing something never decides by itself where the rest goes. A group with categories and a category with folders ask for a target: sent to the main part by default, films that were set apart for adults would turn up among everything else. Logos are kept in the catalogue as small PNGs, so a backup holds them; a separate folder would have been left behind by every restore. Names in `GET /v1/categories` stay for the apps that are installed.

## D-025 Music has its own tables, sync and scanner

Audio folders are in the same `roots` list of the config, but the server keeps them apart from the start: `music_source` beside `source`, tracks beside assets, `/v1/music/library` beside `/v1/library`. Twenty thousand songs as film items would slow every sync and show up in installed apps. One table (`music_change`) orders every change of every kind, so a sync page is one index walk and a removed thing is its own tombstone.

A track is its file: its id survives a move (fingerprint), a new tag, and both at once (same codec, length and title as exactly one missing file). An album is known by its MusicBrainz release id, else as a compilation by name, else by folder and title, so two albums of one name stay apart. An album whose every track gets another key keeps its id. Artist tags are split only at separators that are never part of a name (`;`, ` / `, "feat."). Books know authors and readers as text, apart from the artists.

Copies for mobile data and for formats Apple does not play are AAC at 256 or 128 kbit/s, one at a time at low priority, in a cache with its own limit. The index of the file gets its room in advance instead of `faststart`, which would write each file twice on the Pi's slow disk. Covers stay where they are; only scaled versions are kept. Scan results are written a hundred files at a time for the same reason. ffmpeg is only let loose on audio formats and local files, so a text file named `.mp3` cannot point at other files.

No service is asked anything in this version. Downloads a manager puts on a device stay films only: `device_wanted.item_id` refers to the films' `item` table, so audio needs a second list (a table with artist, album, book and playlist entries, and reports with a quality per file) rather than a fitted-in kind.

## D-026 Converted files replace their originals, which are kept until a person says otherwise

Context: Lobby may have a folder of its own on the media drive, and a converted file that is proven good should replace its original. This ends the rule that Lobby never changes a library file, in one narrow way. A converted file takes its original's place only after a proof in which every check is required (readable, same length, same sound tracks and languages, text subtitles and chapters kept, decodes without an error, the same pictures by SSIM on samples over the whole film, no drift, a sane size, the original unchanged since the job began). The replacement is two renames on the same drive, journalled, never overwriting; the original goes into `originals/` in Lobby's folder with a manifest. It can be undone per title. Nothing is deleted except by an explicit purge request for one replacement. Files that are hard to judge are skipped: picture subtitles, several parts, several episodes, hard links, download folders. The catalogue keeps the item and the file's id, so progress, edits, matches, artwork and wanted lists carry over. Off until `conversion.dir` is configured. Rejected: keeping converted copies beside the originals (two of everything in Plex and on the drive, for good); deleting originals after a time (a mistake in the proof would then be final); converting in place (no way back from a crash). Details and measurements: [conversion.md](conversion.md).

## D-027 Kids limits live on the server, and a route is closed until someone opens it

A device belongs to a kids viewer; the app on it is not trusted. One guard stands behind the credential and looks every route up in one table (`src/kids/guard.ts`). A route that is not in it is `404` for a kids device, and a test fails until it is: forgetting must close, not open. `404` and not `403`, so a known id tells nothing.

What may be seen is worked out as one set of titles and files per viewer and kept until something changes it. Triggers in the database count those changes, because not every one of them moves the library revision (a re-linked file, for one). A title keeps the category of its folder while its file is read again; otherwise it would for a moment be a title without a category, which is in the main part. Removals for an app come from a table per viewer of what was last told, in the order of library revisions. Rejected: `reset` on every change of the limits (a child would download the whole catalogue again for each tap of a parent), and only filtering answers (a title would stay on the device for good).

Turning off a viewer's kids limits, or deleting the viewer, is refused while a device belongs to it. Unbinding by itself would hand a child everything; leaving the device bound to nothing would look broken without saying why. If the database ends up that way regardless, the device gets nothing.

A block follows a renamed file and one that comes back under the same name, because an item's id does not. An allowed title that is removed and comes back has to be allowed again. Music has no limits model, so a kids device has no music.

## D-028 The outside entrance is a door of its own, and the road to it is separate

Devices outside the home and the tailnet come in through `src/outside/`, never through the listener at home. The entrance takes "a connection with perhaps an address, carrying HTTP/1.1" and knows nothing of the road. The requirement: film traffic goes directly between device and server (ICE/DTLS) or over the operator's own relay that only passes encrypted bytes on; it never goes through Cloudflare, which may at most carry the messages that introduce the two. Built first was the relay's end on the server; the direct road followed (D-034).

It serves a second app made from the same parts (`createApp(deps, "outside")`), so nothing on the app for home can be reached by forgetting a check. As with kids limits one table (`OUTSIDE_ROUTES`) holds a decision for every route, and what is not in it is not there. The credential is checked before the request reaches the app at all, so whoever is not let in gets one answer, written in one place: an empty `404`. An unknown credential, a removed device and one only for home are one query, and cannot be told apart.

**Let in per device, and no by default.** `allowOutside` is off for every device, also managers' and all that were paired before: a credential lost years ago must not become useful to a stranger because the house got a public address. The alternative, yes for existing devices, was rejected for that reason. A device paired from outside has it, because a manager just approved exactly that.

**The switch** is off until a manager turns it on, is stored as the word `on`, and anything else is off. The command line can only turn it off.

**Pairing** is in memory, the code and the poll secret only as hashes: a restart closes it, and no backup holds it. 80 bits in sixteen characters is the shortest that is out of reach without counting on the limits; it has to be typed with a remote. The comparison digits are sent back on approval, and waiting devices are kept apart from those at home, so no button an installed app has can approve one.

**Limits do not rest on addresses.** A road may not know the address, or many may share it, so it is only counted when the road vouches for it; beside it there is always a limit on everyone together. Bad tries never hold a good credential up, or a removed tablet would lock out the house it is in. The limit on everyone means a flood can keep a pairing window busy; that was preferred to guessing without limit.

**No dependency** for the PROXY protocol. The packages there are parse both versions, streams and UDP; what is needed is fixed offsets in one header, refused unless it is exactly that, in fifty lines with tests.

## D-029 The home side is careful where that costs the household nothing

Home stays as it was for whoever lives there: one tap claims a fresh server, pairing is one code, the credential may be a cookie. What is tightened is what a home never does. Requests are for a name the server has at home, and not from another site's page (DNS rebinding and forged requests are what a web page can do from inside a home). Names nobody can own on the internet are accepted without asking, so no household has to configure one that already works. The first claim is only for addresses nearby. A server in `secret` mode is not limited that way: the secret is its protection.

A removed device is still told `device_revoked`, unlike outside: only who holds that very credential sees it, the apps show the household why they have to pair again, and it helps nobody to guess.

Pairing requests are limited by address with a replacement instead of a refusal, so a person who opens the screen often never meets a limit, and a stranger only pushes out their own. Queues are bounded far above what a household asks for (a series of 200 episodes), and answer `429`, which the apps already treat as "later".

**The log** drops file paths in one place, when a line is written, and the rest of the line with them: a name can hold anything, so there is no telling where a path ends.

**Removed stays removed over a restore.** A backup cannot know what came after it, so the list of removed devices lives beside the backups as well. A list that cannot be read stops the restore rather than being skipped. If that leaves no manager, the server is not given to the first device that asks.

**A kids block is about the content, not the id** (extends D-027). Items made from files get new ids when a file comes back, and so does everything in a show. So what identifies a blocked file (its fingerprint, its path, its place in the library) is noted when it is forgotten, and compared when a new file is linked, in the same transaction, so it is never open for a moment. Any one of the three is enough. This blocks too much now and then (another home video with the same title); a manager sees that and takes it off, and the other way around nobody would see it. A file that becomes another title takes its block along, and a renamed show is blocked from its first file on. Rejected: matching only numbered episodes by name, which leaves extras and home videos open.

## D-030 The palette: solid aubergine surfaces, one accent, a sidebar of one colour

Context: the apps' backgrounds needed to be calmer, the sidebar's search field was too prominent, and the sidebar's many colours made it busy. Every surface is a solid role in `AppTheme`: window, sidebar (a step darker), panel, raised, hairline and a second text colour, in a deep aubergine in dark and a warm off-white of the same hue in light. The hue is Lobby's own: it sits across from the orange accent without turning it brown, and no poster blends into it. Nothing takes a tint from the desktop picture, which also makes Reduce Transparency the normal look. The unit test `ThemeTests` holds text and accent to WCAG AA on every one of them; the light accent was darkened for that (0xB8430A). The system's own second-level text inside its forms and lists keeps the system's colour.

This replaces the concept's coloured navigation symbols. In the sidebar every symbol is one quiet colour and the chosen row is a tinted fill with the accent on its symbol; the colours and logos a household chose stay on the category pages and cards. Genres are one heading that opens and stays as it was left. A category that only repeats Movies or Series is not listed again, judged by its titles (nine in ten, both ways), never by its name. Search is a magnifier that opens into a small field; ⌘F opens it.

A category's icon is found by everyday words in English and Dutch, or by a symbol's own name, and suggested from the category's name as it is typed and from the genres of its titles. Suggestions only suggest. The words describe the pictures and are no household's names.

## D-031 A page takes its colours from its artwork, within limits that keep text readable

Context: a page's background could come from its artwork, several colours of it, darkened: subtle in the normal screens and a little brighter in kids mode. A film or series page, the Library (its title on top) and the category and group pages lie on up to three hues of their pictures, as soft fields over a base. Only the hue and the saturation come from the picture; how light it is comes from the app. The sidebar takes half a step of it. Lists, Downloads, Settings and the household's pages stay aubergine (D-030), and so does a page whose picture has no colour. Kids film and series pages are bright; the kids sections keep their fixed colours.

White, the second text colour and the accent are at least 4.5:1 on every colour **and every mixture** of them, proven in `ArtworkPaletteTests` over all hues. Words straight on a kids page are large and heavy (never under 19 points bold), so those pages are held to 3:1 and can be brighter; smaller words there are on a chip.

A darkened yellow is olive. On dark and kids pages hues between 42° and 100° become gold (40°) or green (104°), whichever is nearer, warm hues keep more saturation, orange and gold turn towards red where the page is dark (there they can only be brown; kids pages by day keep them), and a glow whose mixtures with the others would be olive or grey is turned towards the base until they are not. Light pages are too pale for this to matter.

The hues are worked out on the device from the smallest picture, once per artwork id (which never changes its picture), and kept beside the downloads' pictures, so they are there offline. The fields are static gradients that do not scroll. Reduce Motion takes away the fade between two pages' colours; Reduce Transparency and Increase Contrast make the page one flat colour.

## D-032 Movement: one system in three forms

Context: scrolling lists (vertical and horizontal), opening pages and pressing buttons needed nicer movement. `Motion.swift` beside the palette names what moves (press, release, hover, open, arrive, section and so on) and holds every spring, duration and distance; views ask for a meaning. Each meaning has three forms: full; light, in Low Power Mode, without what moves while scrolling or covers the screen; and still, with Reduce Motion, where nothing changes place or size and what appears fades. The kids screens use the same system with `isPlayful`: larger, and with a bounce. `MotionTests` holds the still form to that. All buttons are one family (`ButtonStyles.swift`).

This departs on purpose from a stricter "no springs, no page transitions" rule. On iPhone and iPad a poster grows into its page with the system's zoom, and goes back into it; the Mac's navigation has no transition of its own, so there the page grows a little out of the place that was clicked and the page under it comes back with a fade. A tile tells where its page comes from when it is pressed, because the same film stands on several shelves; opened another way (a menu, VoiceOver) a page comes in the system's ordinary way. The player itself opens with the system's own movement on iPhone and iPad: with UIKit's zoom on `AVPlayerViewController` its Close button did nothing (iOS 26.2). Scrolling effects are drawn from the scroll position without state in a view. Animations on arrival are scoped to opacity and offset, so a layout that is found in the same moment does not move.

## D-033 Home pages are made on the device; the server adds what they need to each title

Extends D-003: no server-built home, so a page offline is the same page from fewer titles. Logo, tagline, `renown` and dates are in the item and come with the sync. Plays are not: watching would then move the library cursor of every device. `GET /v1/popular` is one small answer that can be kept.

**Plays** come from the progress the devices already send, as a row per viewer, title and day (`play`), because `progress` holds only the last place. It counts what moved forward, no faster than time allows. Rejected: counting positions past ten minutes (a jump or a resumed second would count) and letting the apps report plays (a second thing to keep in step, and nothing from apps that are installed). The first rows are made from the last known places; marking by hand has none and makes none. What the server cannot tell: jumping ahead in the very first report of a title, and the difference between leaving it playing and watching it.

**Privacy.** Only counts over the household leave the server. With two viewers one can work out the other's; a device without kids limits may already read every viewer's progress, so this gives away nothing new. What adults watch never shapes a kids list, not even its order: only kids viewers' plays count there. Kept for 180 days and deleted with the viewer.

**Renown** is one number, not TMDB's three, so the apps cannot mix them in different ways, and rounded so a monthly look rarely changes an item. Without ratings it is null: an invented middle would put an unknown film above a known one.

**Logos** are PNG only and must have transparency to be chosen automatically. An SVG is refused, not drawn: a renderer for them on the Pi is more risk than the few titles that have nothing else are worth. "No logo" is a choice of its own (a row without a picture), so a refresh does not bring one back.

**Banners** are kept at 1920 wide: TMDB's 1280 is soft on a Mac or TV, its original is two or three megabytes. The original is made smaller on arrival. What a manager chose stays.

**What was matched before** is done a few titles per scan, one at a time, and the moment is kept per title, so it goes on after a restart and is the same work as the monthly look afterwards.

**`addedAt`** was raised by any new file of a title, so a replaced episode or a second edition put it on top. Now only a new film or episode counts, and a rename inherits. The upgrade takes dates back to when the oldest file was seen.

Migration 11 makes the `artwork` table again to allow one more kind: SQLite cannot change a check. Every row keeps its id. 10 belongs to other branches and either order works; a migration that changes `artwork` and comes before this one would have to be repeated in it.

## D-034 The direct road: QUIC between device and Pi, introduced by a service that learns nothing

Context: a trial on a real iPhone on 5G. The requirements: film never through Cloudflare; direct, or over the operator's own relay; the introduction may run on Cloudflare and must be replaceable; off by default.

**The stack is the trial's**: libjuice for ICE, QUIC, Apple's own QUIC in the apps. WebRTC's SCTP was too slow on a lossy path. The Pi's half is a program of its own because Node has no QUIC that can be used for this; it knows nothing of Lobby but a socket to bring streams to.

**The device proves itself with a signature over the TLS exporter, on a stream**, not with a client certificate. Both bind the connection to the device. A client certificate needs a `SecIdentity`, which on iOS and tvOS means a certificate made in the app or a PKCS #12 file imported into the Keychain, for a key that CryptoKit already holds. The exporter is in Network.framework, and gives the same bytes as rustls (checked on macOS with this code). The proof may come on any of the first four streams, because Apple's QUIC opens an empty one by itself; taking only the first would have locked every Apple device out.

**A connection is one device's.** The entrance refuses any other credential on it, though it is valid, so a stolen credential alone opens nothing on this road, and a stolen ring key neither.

**The secret is agreed, not sent.** At home the API is HTTP, so whoever listens there would have had the key to the outside; with X25519 listening is not enough. Standing in the middle at that very moment is, as it is for the credential.

**No PAKE.** The introducer passes everything on, so a short code would need one: it could guess offline. The code from outside is 80 random bits already (D-028), and with that a PAKE adds nothing against guessing. Candidates were looked for as a pair, for Node and for Swift: OPAQUE and CPace/SPAKE2 packages exist for JavaScript, none both audited as a PAKE and kept up with a counterpart in Swift; CryptoKit has neither hash-to-curve nor point arithmetic, so the Swift half would have been our own elliptic curve code. What is built uses only primitives both platforms have: scrypt over the code, HKDF, ChaCha20-Poly1305, and a fresh X25519 agreement under it for what comes after. Scrypt is not in CryptoKit; it is 80 lines with the RFC's own vector to hold them to, and a mistake in it fails to pair rather than weakening anything. Should the code leak, the six digits remain, so the device commits to its half first: without that, who stands in the middle could try halves until the digits match.

**No ICE restart.** libjuice has none. A device that changes network makes a new connection beside the old one, through the introducer, which takes about two seconds; requests go on by `Range`. Three connections per device leave room for that.

**One introducer, one object.** A household has one box. One Durable Object holds all lines, so limits and the day's cap are counted in one place, and the same code runs on Node with a map for its storage. Only boxes on its list are served, so nobody else's use can cost the operator anything. It counts ahead in its storage, so that a nap loses no count.

**What is under way is at most 1 MB per device.** Trial: an abandoned range had already been given 10 to 20 MB. The limit is QUIC's send window; the sockets between Node and the program hold 16 KB steps. It costs speed only above about 80 Mbit/s at 100 ms.

**quinn with BBR, and a cap.** Measured again at small scale (docs/outside.md, Congestion): Cubic falls to 2 Mbit/s at 1% random loss, and noq's BBRv3, better on a capped path in the trial, stood still there with the smaller window. BBR fills a full queue; the cap on what is sent (`maxUploadMbit`) takes that away, and was preferred to a cleverer controller because the operator knows the line. All of it was on a loaded Mac; the Pi and 5G have yet to say the same.

## D-035 The apps' half of the direct road: one local server, one choice

**All requests over the direct road go through a server in the app**, also those of `URLSession`. A `URLProtocol` covers only the app's own sessions, so the player and downloads would need the server anyway; one way has one set of rules, and the player's address stays the same while what is under it changes. The credential is put on inside: the port is the device's, and another program can have it after a suspension.

**At home the player gets the server's own address**, not the local one, so that AirPlay and background downloads work as before. A film that leaves the house is opened again where it is, once; one that comes home goes on without that, because the local server then sends to the address at home.

**The connection is replaced, never repaired**, and what was under way is asked again from the missing byte. Nothing but `GET` and `HEAD` is asked twice once it was sent.

**Enrolling does not wait for being allowed.** A device gets ready whenever it is at home and the server offers the road, so that a manager can allow it later. The introducer refuses it until then, and after one refusal it stays quiet.

**Handing a code to a TV** goes over the local network, sealed with a key from the TV's screen, and not over iCloud, a service or a name lookup.

## D-036 Playing on another device: server-sent events and posts, all in memory, moved in two steps

Context: play on the Apple TV from the phone, see what it plays, and control it. Through the server and not between devices, so it works over any network, and kids limits, removal and outside rules are decided in one place.

**Server-sent events and plain posts, not a WebSocket.** The outside entrance ends every upgrade, and that stays. The channel is one long HTTP/1.1 answer, so it goes over the relay and the direct road's streams as they are, with the credential, the limits and the cutting that are there. `URLSession.bytes` reads it on all platforms. A command costs a request more than on a socket; at home that is milliseconds.

**Devices send a sign of life every five seconds.** A television that loses its power leaves a connection that looks open for minutes. Writing to it proves nothing. With 12 s of silence it is gone, inside the 15 s the card asks for.

**Nothing is stored but three settings.** No command waits for a device that is not there: a film that starts by itself an hour later is worse than an error, and the error lets the app offer AirPlay. A command that was under way when a connection broke for a moment still arrives, within its ten seconds. State kept for a device that comes back is replaced by the newest, and replaced at once when a title is no longer for it.

**No times of devices.** They send how long ago something was measured; the server's clock is in every message.

**Handing over is done by the server**, in two steps: the first device pauses and says where it was, the second starts from there, and only then the first ends. When the second cannot, the first goes on. If the second does not answer it is stopped too, so a film never plays twice; what cannot be excluded is the second stopping late when it is out of reach. Progress stays each device's own: the first writes before the second asks.

**Who may, where it was open:** everybody without kids limits controls the household's televisions and Macs, also a child's, because that is what a parent wants; a child's device sees and controls nothing but itself. Phones and iPads are no targets until somebody says so on them, and are then not seen either. A manager can take a device out altogether (`allowRemote`). Outside a device sees only itself until a manager says otherwise (`remoteOutside`, apart from `allowOutside`: watching far from home is not the same as running the television there), and neither setting survives a restore. Titles are hidden for a kids viewer on a shared device as far as the app tells who watches; only a bound device is a real limit, as everywhere. Reasons of failure are a fixed list: free text could hold a title.

**Music** shows as "Playing" to everyone. It has no limits yet, so it is not told.

Migration 13: 12 is on the branch of the direct connection, 10 on that of the avatars. Any order works.

## D-037 Avatars: ids on the server, pictures in the apps

Context: viewers should be able to pick an avatar: types of people (a Viking, a princess) and animals. The 32 approved pictures (`docs/design/avatars`) are in the apps, 400 px JPEG in one scale (HEIF was smaller in the repository, but a generic iOS build and tvOS unpack it to several megabytes) for every platform; the server keeps only an id. It takes any id of the right form rather than a list of its own, so a newer app's picture is not refused by the Pi, and an app without that picture shows the letter. Nothing of a person is uploaded.

The picture is the one thing of a viewer that is not for managers only: `PUT /v1/profiles/{id}/avatar` reads the picture and nothing else. Any device may watch as any viewer without asking, so it may do this for any; a device bound to a child only for that child. A route of its own rather than a wider `PATCH`: what a child's device may reach must not depend on which fields a handler looks at. Outside it is open too, unlike the edits of music lists. It is a word on a viewer whose progress the device may write already, and a child in the car should not be refused a panda.

The apps send a choice at once and do not queue it: out of reach the picture goes back to what it was and the app says so. A queue would need to settle two devices' choices about something nobody misses for an hour.

In kids mode the avatar opens the child's pictures without asking, since they change nothing else; the way out for grown-ups is a button on that page and still asks for Face ID or the passcode. The viewer picker offers pictures with a button instead of a question after the first choice, which would stand between a person and the film on every device of the house.

## D-038 Home and category pages in the apps

Context: a proper home page with a large banner of the newest titles, playable at once, also for each category; offline, the same layout with what is on the device. (D-033 is the server's part.) `BrowseBuilder` makes every page from the device's copy of the catalogue, so a page offline is the same code with fewer titles. A banner holds only what plays here and now and has a picture of 1280 pixels or more; of a title that is not matched the picture is a frame, so its file has to be that wide too. It mixes the newest with what the viewer is in and what is popular, and a page leaves out the titles of Home's banner while there are others.

Popular is the household's plays (`GET /v1/popular`, kept for offline; only kids viewers' for a kids viewer), filled up by renown with a word about it. Without the server's count it is worked out from where the viewers are in titles, as far as this device knows; with fewer than four titles there is no such row. No number is shown or made up. Rows with fewer than three titles are left out, except the ways in: Continue Watching, Movies, Series, groups.

The stored catalogue is format 2: an earlier app dropped logos, renown and dates, which are in no change the server still has to tell, so the library is fetched in full once and replaces the copy.

On a dark page the cool colours of a picture count more than its warm ones, because skin, wood and lamps are in nearly every picture, and reds and oranges become a wine: dark, they are a brown or a warning. The kids pages use the same hues, let up as far as white on them is 7:1 (9:1 with more contrast), by day and by night: the aim is nice, not too childish, simpler and a little more colourful, without white frames, one colour per section or bouncing. They follow the banner's slide, or the topmost row in sight. A child gets the household's categories as tiles: those the limits name, or with a title allowed by itself, never one that only shares a title with an allowed category.

## D-039 Apple TV: who is watching, one way around, and a code for grown-ups

Context: tried on a real Apple TV with the Remote app on a phone, there was no proper viewer chooser, and navigation got stuck before it worked.

**Who is watching** is a full screen with large round pictures, the last viewer on it, shown when the app starts and after it was away for ten minutes; a setting on the viewer's page makes that after 1, 4 or 12 hours, or never. It is never shown in kids mode, and not to a household of one. Back returns to whoever watched.

**One way around**: the system's sidebar (`sidebarAdaptable`), the viewer first, then Search, Home and the household's parts. Every row is a focus section as wide as the page, nothing on the TV changes its identity or goes away under the remote (the banner's buttons are the same views for every slide; Mark as Watched is one button that changes its words; nothing that has the remote is disabled), and nothing is transparent while focus is decided: on tvOS pages do not fade or grow in, tiles do not ease at the edges, a banner picture does not grow, its page keeps one colour and is flat, and panels are solid. The slideshow stands still while the remote is on it; Next goes on.

**Kids on the TV** are the same sidebar with Home, Movies and Series from `KidsLibrary`, and the child's own place, which offers their picture and "For Grown-ups". There is no Face ID, so a manager chooses a **four-digit code for the household**, on the server (`/v1/kids/code`): per household rather than per device, because a TV is reset and paired again, and a code that lives on the TV would be on the child's side of the door. It is kept as a salted scrypt hash; four digits are few, so what protects them is five wrong guesses per device per ten minutes, counted before they are checked. Only the server can say yes: offline nobody leaves. Without a code the TV says that a manager has to choose one, or change the TV from another device. A TV bound to a child has no code to type: the route is closed to it, and the screen says only a manager changes that. Approval on a manager's phone was left for later: it needs a request that waits on the server and a notice on the phone, much more than this.

## D-040 Categories inside a category: one level, titles keep their own

Context: categories need subcategories, the way streaming services group a studio's titles. A category may be inside one other category of the same group, one level deep; a parent can hold folders and titles too. Deeper trees were rejected: no page needs them, and every rule (limits, moves, deletes) would need a walk.

**A title names only its own categories.** The parent is not added to `categoryIds`: an app that edits a title sends back what it read, and a parent there would stay behind when the title moves to another sub. Apps work the parent out from `parentId`. Apps from before see one flat list with each parent followed by its subs; a parent without titles of its own is an empty category, which they leave out. That was preferred to sending only the parents to older apps, which would have hidden the subs' titles from their shelves.

**Kids limits cover what is inside.** An allowed or blocked parent covers its subs; a sub can be allowed by itself. Blocking by category is new (`blockedCategoryIds`), and blocked wins over everything, also over a single allowed title. An older app that saves limits without the list keeps the blocks.

**Rearranging never widens silently.** A change that touches nested or blocked categories and lets a kids viewer see more is refused until the manager confirms with a token that names exactly what would appear; a dry run tells it first. Flat changes of unblocked categories go on as before, so installed apps keep working. Rejected: blocking such changes outright (moving a studio into Kids is the point), and keeping a parent's old limits for a moved sub (the limits would no longer say what they show).

**One request for an arrangement, with an undo.** Several moves and renames are one transaction, checked only at the end, so names can swap. The state before is kept with the revision it produced; the undo works until anything else changes the categories. Migration 14 (10 to 13 were made on other branches at the same time).

## D-041 A category can follow studios; titles are in several categories, never moved out

Context: categories by studio, suggested from what the household has. TMDB's companies and networks are kept per film and show (`studio`, `item_studio`), and read for older titles by the monthly refresh, a few dozen a run, so the Pi and TMDB see no burst. A category may have a rule naming studios; its titles are in it besides their own categories (`ruleCategoryIds` beside `categoryIds`), so a rule never empties a folder's category or changes which group a title is in for installed apps.

**Kids: a rule never widens through a group.** A title that is in a category only by its rule is allowed by that category itself (or its parent), not by an allowed group: a studio's catalogue is not what a parent looked at when allowing the Kids part. Blocking a rule category blocks what it takes in. Setting or changing a rule asks first when a kids viewer would see more (D-040). Titles that arrive later through a rule of an allowed category come in like a new file in an allowed folder.

**Suggestions are only suggestions.** Studios with at least eight titles and no category, companies of one studio together by their name without words for the kind of company; nothing is created by itself and no studio is named in code. A dismissal is kept per studio, so regrouping does not bring it back. Rejected: matching by logo (TMDB gives one studio several logos and some none), and a fixed list of well-known studios.

## D-042 Server settings: a store beside the file, and a setup in the app

Context: managers should be able to change the server's settings in the app, set most of them in a first setup, and put in their own TMDB key there.

**Two places, not one rewritten file.** The server never writes `lobby.config.json`: it is the operator's, may hold comments of theirs in a later format, and must stay readable when the store is broken. What managers change is a store of its own in the data folder, a whole snapshot per version, written beside the old one and renamed over it, the old one first copied into the history. The store wins for its keys. It is made from the file on the first start, so an upgrade changes nothing, and the server logs which keys of the file it no longer reads rather than guessing which one is newer. Values are kept as the file writes them, and every change is checked by the same function that reads the file, so the app can never make a config the server would refuse at its next start.

**What stays in the file.** Where the server listens, its data folder, the programs it runs, how it is claimed, files with keys and certificates, the backups' and caches' folders and the outside entrance. A wrong one of those locks everyone out, or runs a program of someone's choosing, or writes where it should not; whoever has the machine in hand sets them. The upload limit of the direct connection is the one part of `outside` in the app.

**Live where it is cheap and safe, a restart otherwise.** Taken live: the name (announced again), film and series folders (sources synced, watchers renewed, a scan at once), converting's hours and choices, the remote addresses (also which names the server answers to), backups and the minutes between scans. Everything else restarts: a clean close, exit 75, systemd starts it again. Moving Lobby's folder once it holds originals is refused rather than done: the journal and the originals are there. A change is made in the running server first and kept after; if either fails, the server is put back and the store is untouched.

**Folders.** Browsing and new folders are limited to the mounted drives and the service user's home, by the folder's real path, so `..` and links lead nowhere else; hidden folders are not shown or accepted. A folder that is in the library already is not checked again, so a drive that is away does not block other changes.

**First setup.** A server that had no folders when it first started this version waits: nothing is looked through until a manager finished the setup, so the first look happens with the name, the folders and the key chosen. A server with folders is never asked. The one-click claim is unchanged; its answer and `GET /v1/me` say whether the setup is to do.

**The TMDB key** is checked with TMDB before it is kept, kept in `secrets.json` only, and answered as set or not set. A key in the environment wins and cannot be changed in the app.

Migration 15: 14 (categories inside a category) was made on another branch at the same time. Any order works.


## D-043 Playing on another device in the apps, and AirPlay with a pass

The apps' part of D-036. Context: a "Play on Apple TV" button in the iPhone, iPad and Mac apps that starts the Apple TV and plays there, with several Apple TVs to choose from.

**What an app cannot do.** No app on an iPhone, iPad or Mac can start or wake an app on an Apple TV: there is no API for it. So a TV with Lobby open gets the command through the server and plays itself; a TV where Lobby is closed or that sleeps is offered AirPlay, which wakes it, with the plain words that Lobby has to be opened there to control it fully.

**AirPlay needs a pass, not the cookie.** The receiver fetches the film by itself. What `AVURLAssetHTTPCookiesKey` and an `Authorization` header carry stays on the phone (Apple documents no forwarding, and developers report signed cookies failing over AirPlay), so a film from Lobby Server would be refused on the TV. A credential in the URL is not acceptable (D-010). The server hands out a pass instead (`POST /v1/assets/{id}/airplay`): a random path prefix for one file, `GET` and `HEAD` only, as the device that asked and with its kids limits, for eight hours, gone with the device, in memory only, at home only. The apps ask for it only on the home network (the receiver cannot reach a server on Tailscale or inside the app's direct road), and only once AirPlay is chosen: a film that plays here keeps the cookie.

**Where it is in the apps.** `LiveChannel` (LobbyKit) reads the channel byte by byte (`URLSession.bytes(for:).lines` drops the empty lines that end an event), with a session of its own, a watchdog on `silentMs` and waits of 0, 1, 2, 4, 8 and 15 s. `RemoteModel` (one per app) announces on every change it notices (pause and play, a jump of the player's own controls, a new item) and looks every second; a place is sent again only when it is more than a second from where the last one would have got by itself. Commands for this device are done one at a time, answered once and again with the same answer. The others' places are moved on by the server's clock, measured from the quickest answer to a post.

**What the screens do.** Play On is on a film's and a series' page (the next episode) and in the player, only while there is another device; it lists every other device the server shows, open ones first, then televisions, Macs, iPads and phones, named as they were paired and numbered when two have one name, and says what each does. A television that is off has AirPlay instead of Play: the system's AirPlay button (an app cannot choose the receiver), Play Here, and that Lobby must be opened there to control it fully. The now-playing bar sits at the foot of the library while another device plays and nothing plays here; it opens the remote (place, ±10 s, play and pause, next episode, sound, subtitles, stop, Watch Here). No volume: an app cannot set a television's. Phones and iPads become targets with a switch in Settings.

**Kids.** The kids screens and a bound device show no remote at all; a bound television plays only as its child, and only what the child may see, which both the server and the television check. A kids television can only be played on as its child; the channel does not say which child that is, so a manager's app looks it up in the device list, and another app lets the person choose among the kids viewers and the server refuses the wrong one.

**Not built.** A Live Activity with buttons: it would need a widget extension, and without push updates it is stale as soon as the app is in the background, which is when it would be looked at. Left for when the server can push.

**Trailers.** On iPhone, iPad and Mac YouTube's own embedded player plays in a sheet (`youtube-nocookie.com`, the page at `https://mt.sil.lobby` so that the referrer names the app as YouTube asks, links out to the browser, no Picture in Picture, closed when the app goes to the background). The Apple TV has no web view: Trailer opens the YouTube app when `canOpenURL` says it is there, and is left out otherwise. A trailer file of the household plays in Lobby's player; several make a menu. Offline there is no YouTube trailer. A kids viewer sees trailers only of titles they may watch, and a switch in Settings turns them off for kids mode on that device (on by default: a trailer of an allowed title is no more than the title).

## D-044 Music in the apps: its own place, its own player, downloads by collection

Context: a household's own audio library, with background play and all, without depending on the big platforms.

**Its own place in the same app.** Music is a tab on iPhone, a sidebar section on iPad and Mac, and a tab on the Apple TV: home (recently played, recently added, albums, playlists, books), artists, albums, songs, audiobooks, playlists, favourites; search and the Downloads screen show it beside the films. Rejected: a second app (the pairing, the server's address and the viewers would have to be done twice). Covers go through the films' artwork loader as `Artwork.musicCover`, so they are cached, kept for downloads and give pages their colours like posters.

**Its own player.** One `AVQueuePlayer` with what plays and the next song behind it: an album runs on without the gap a second player would leave, as far as the files allow (AAC and ALAC carry their padding, which AVPlayer honours; MP3 and FLAC can leave a few milliseconds). Not with repeat one, a sleep timer at the end of the song, or the round of a shuffled queue. The queue's rules are a value in LobbyKit (`MusicQueue`) with tests; the film player is untouched and pauses the music when a film starts. A long-form `playback` audio session on iPhone, iPad and Apple TV; lock screen, Control Center, headphones and the Mac's media keys through `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter`; interruptions resume when the system says so, and unplugged headphones pause. Volume matching only ever lowers (ReplayGain, peak-limited), because a player's volume cannot go above the file. CarPlay waits for Apple's permission.

**Listens.** A listen is sent when a song ended, was skipped after half of it, or after four minutes; less than half a minute of a song is not sent at all. Sent with an id of its own, queued on the device when the server is away. Recently Played is made from them.

**Books** keep their place in music's own progress (the same rules as a film's, `ProgressStore` with music's routes), every fifteen seconds while playing and at every pause; next and previous go by chapter, the skip buttons by 15 and 30 seconds, speed from 0.75× to 2×, kept for the next book.

**Downloads by album, playlist or book**, file by file, the server's 256 kbit/s copy for formats Apple does not play and the file itself otherwise. They follow the films' mobile-data switch. A transfer runs while the app runs, in an ordinary session: songs are small, and a background session's relaunch handling is the films'. A file that changed on the server is fetched again while the old copy keeps playing. Offline the same screens show what is on the device. The Apple TV keeps nothing.

**Kids.** The server has no limits model for music, so a kids device gets `404` for all of it (D-027). The apps show no music in kids mode or for a kids viewer, and stop what plays when kids mode begins. A model of allowed music per kids viewer is separate work (D-062 later made music for kids possible).

**Playlists change at the server only**: the device makes the id, sends the whole new order with the revision it saw, and shows the server's version after a conflict. Offline they can be played, not changed.

## D-045 Lobby Server for any computer that stays on: archives with their own Node, an installer, an image

Context: the server is not always on a Pi; it can be on any Unix machine.

**What is Pi-specific is only how it was put there.** The server is Node 24 with ffmpeg; the scripts were the Pi part. A release is an archive per platform (Linux and macOS, arm64 and x86_64) with the server, its production dependencies exactly as the lock file has them, and the official Node.js, pinned by version and SHA-256, so the computer's own Node, if any, does not matter and nothing system-wide changes. Rejected: npm packages (they need a Node of the right version first, and `npm install -g` writes system-wide), distribution packages (one per distribution and release, and root to install), a single executable (Node's SEA does not take a module graph of TypeScript files without a build step, which the server deliberately has none of).

**The installer installs nothing of the system's.** It runs as the user, refuses root, writes its folder and one service file, and asks for sudo only for a system service. ffmpeg is checked and the command to get it printed, not run: a package manager is the operator's to drive. The config it makes has no folders, so the app's first setup applies, and the default claim, which the server allows from the home network and the tailnet only.

**Data is never the installer's.** Install, update and uninstall do not write into the data folder or over the config; an update backs the catalogue up with the version that wrote it first, and refuses an older version, which may not read a newer catalogue. Uninstalling keeps the data unless asked twice.

**Docker for the rest** (NAS boxes, musl systems, root-run machines): host networking, because Bonjour and the nearby check need the real network. lobby-direct is built per platform where it can be; an archive without it works apart from the direct road, and the program can be added later.

**Restarting under launchd and Docker.** They set no `INVOCATION_ID`, so `LOBBY_SUPERVISED=1` tells the server to exit with 75 for a restart rather than start again in its own process.

## D-046 Waking the Apple TV for Play On: pyatv over the Companion protocol, from the server

Context: Play On should wake the Apple TV and open Lobby. Tried on a real network first: the Pi paired with the Apple TV with pyatv 0.18.0, and `turn_on` then `launch_app=mt.sil.lobby` woke it and opened Lobby in about 4 s.

**An unofficial protocol, and said so.** Apple offers no way for one device to turn an Apple TV on and open an app on it, short of AirPlay, which plays a stream and does not open Lobby. pyatv speaks the Companion protocol the Remote app uses, as worked out by its authors. It can break with any tvOS update. So it is optional, off without `remote.wake` in the file, and every failure has a reason the app shows before it offers AirPlay as it did before.

**The server does it, not the phone.** The server is always on, on the TV's network, and already the one place everything goes through. A Swift app cannot speak Companion without reimplementing pyatv's work, and every device would need its own pairing. The server needs one.

**A helper in Python, kept running.** pyatv is a Python library; Lobby's server stays Node with two dependencies. `apps/server/tools/wake.py` uses pyatv's library, not its command line, so answers are data, not text that changes with a version. Node keeps one process and speaks JSON lines with it, and starts it again with a growing wait, as with lobby-direct. A pairing needs its connection held open while the code is typed, which a command per step could not do. Rejected: running `atvremote` per request (parses output, cannot hold a pairing open), pyatv in the Docker image by default (most households have no Apple TV, and it is a second runtime).

**Where pyatv is, is only in the file.** A setting in the app must not choose a program the server runs (as with `ffmpegPath`). Whether TVs are woken is a setting (`remote.wake.enabled`), live, with the others' history and audit.

**Credentials stay pyatv's.** In its own file (`~/.pyatv.conf` by default, so a TV paired by hand counts), mode 600, read by the helper only, never in a log, an answer, the catalogue or a backup. The catalogue keeps which TV is which Lobby device.

**Which Lobby device a TV is: the manager confirms.** tvOS gives an app no identifier the Companion protocol knows (not its MAC, not its Companion or AirPlay id). The app suggests the Apple TV device of the same name, and a manager confirms; one Lobby device is at most one TV.

**Who may wake.** Any grown-up's device that may control others (`allowRemote`), at home only: a TV turned on from away is someone else's evening, and the outside entrance does not have the route. Not a kids device, which sends no commands at all. Connecting and disconnecting TVs is for managers, at home or in the tailnet. A few wakes a minute per device and per TV; one wake under way for a TV is joined, not repeated.

**The app waits for the TV, then plays.** The server answers once the TV took the request; the app waits up to 15 s for it to announce itself on the live channel, then sends `play` as always, so the resume point, the viewer and the tracks are the app's as before. The server sending `play` itself was rejected: it would need to queue a command for a device that is not there yet, and the person would see nothing of how it goes.

## D-047 The apps say when there is a new version, and managers when app and server do not match

Context: every app should say when there is a new version in the App Store, so it is easy to update.

**Apple's public lookup, nothing of the household's.** The app asks `https://itunes.apple.com/lookup?bundleId=…&country=…` (on the Mac with `entity=macSoftware`): the bundle id and the device's storefront, no account, no device id. At most once a day, at launch or when the app comes to the front, with a 10-second timeout; "Check for Updates" in Settings asks at once. A newer version (compared by its numbers, `1.10` after `1.9`) is offered only when this device's system is at least the answer's `minimumOsVersion`. No third-party SDK.

**Only copies from the App Store ask.** Debug builds, TestFlight (StoreKit's `AppTransaction` says sandbox) and a Mac copy without an App Store receipt never ask by themselves: their version is not the store's. `-lobby-updates-always YES` lets one ask anyway, and `-lobby-updates-version 0.0.1` makes it pretend to be older, to see the notice in a test build.

**A calm notice, once per version.** "A new version of Lobby is ready", with the first lines of what is new, Update and Later. Update opens the App Store page (the URL, on every platform: one way, and on the Apple TV the only one). Later asks again after three days for the same version. Skip This Version never offers that version again on this device, not even in Settings until someone presses Check for Updates there; a newer version is offered as usual. Update, or closing the notice, is the last word for that version too. "Suggest Updates" in Settings (on by default, per device) turns the daily check and the notice off; Check for Updates still asks. Never while a film or music plays, never in kids mode or on the kids screens: it waits for a grown-up.

**App and server tell each other what they need.** `GET /v1/server` carries `minAppVersion`; the app knows the oldest server it works with. When either is behind, a manager is told once per pair of versions what to update, and Settings says it for as long as it is so. Viewers are not told: they cannot update the server, and the App Store notice tells them about the app.

## D-048 Several servers in one app: an account per server, each with its own places

Context: one app should hold several servers: one's own household's, and a family's server one was invited to (households, D-052).

**An account per server, apart in every store.** `servers.json` in Lobby's folder lists the servers in the person's order, with the one in use. Each account has its own folder (`Servers/<id>/`: catalogue, categories, popular, progress queue, downloads, kept artwork, music; and `Caches/Servers/<id>/Artwork`), its own defaults suite (connection, viewer, kids mode, settings, roads, update notices), its own Keychain service (the device credential, the direct identity, a pending outside pairing) and its own background download session. Where each is is written down in the list, so a later build that lays new accounts out otherwise still finds the old ones. Rejected: one store with a server key in every record (every store and every test would change, and one forgotten key leaks); keeping only the inactive servers apart (the first would be special forever).

**The one-server device becomes the first account without copying.** On the first launch of this build the files of Lobby's folder move into `Servers/first/` (a rename on the same volume); the preferences, the Keychain service and the background session stay the ones of before, so nothing is copied and a transfer the system is running is found again. The list is written before anything moves and marks what is still to move, so a launch that stops halfway goes on. A list that cannot be read is rebuilt from the folders.

**One server in use; switching makes the other anew.** The app model is per server and made from that server's stored state. Switching closes the player (its place written down), stops the music, ends the live channel and the direct connection, and the screens of the old server go with it. Downloads keep their server: at home or over Tailscale they go on in the background; those the app carries over the direct road wait for their server to be in use again.

**Kids mode stays on its server.** On a device bound to a kids viewer nothing about servers can be changed. In kids mode, switching or adding needs the grown-up gate (Face ID, Touch ID or the passcode), unless a grown-up just passed it to leave the kids screens. On the Apple TV the kids mode is left with the household's code first.

**Adding is the Connect screen of a new account.** Found at home, typed, or paired from outside with a code or a QR code. `lobby://join?c=<code>&i=<introducer>` is the hook for a household's invitation: for now it opens pairing from outside with what it says filled in. The same server twice is refused before a code is asked for (from outside only after: the second credential is then forgotten, and the server keeps a device entry a manager can remove). Removing asks first and deletes the server's credential, settings, copy of the library and downloads on this device, nothing of another; the last one removed leaves an empty account to pair again.

**Offline, every server's downloads.** On This Device lists the other servers' downloads under their names. Playing one switches to its server (with the kids rules above) and plays it there, by that server's rules and progress.

**Two steps at the start: which library, then who.** A device can be on several servers; it asks which server first, then which viewer. A viewer never lives on several servers. With more than one paired server the start asks "Which library?" first: each server's name, symbol and colour, whether it answers now (asked at its addresses without the credential; one reached only over the direct road shows as offline until chosen) or how many downloads play offline, the one used last first and chosen by default. Then that server's viewers, as before. "Remember my choice" (per device, undone in Settings → Servers) opens the last library without asking. Switch Library in the viewer menu and on Who is watching goes back to the first step. Viewers are never shown together across servers, never linked or merged: there is no "same person" on two servers. A device bound to a kids viewer has no library step. In kids mode, choosing another library at the start or from the menu needs the grown-up gate. On the Apple TV the step is large cards for the remote.

## D-049 Categories stay tidy: top-level in lists, suggestions ask where, arranging by dragging

Context: after accepting the studio suggestions one by one, every studio was a top-level category of Kids and the sidebar listed them all. Categories should also be draggable.

**Lists show top-level categories.** The sidebar (Mac, iPad), the group pages and the Apple TV list only top-level categories; those inside one are its sections (All first, then each). A sidebar group with more than six shows six and "More…", and each group's heading folds it away; both are remembered per device.

**A suggestion is never put anywhere by itself.** Accepting asks where: inside a category there is, joined to one (its studios join that one's rule) or as a new category in a group, and for several suggestions at once one category for all of them or one each. The server gained `POST /v1/categories/suggestions/accept` for several at once, so one question about kids viewers covers them; accepting into a category there is now joins the rule instead of replacing it.

**Dragging is an arrangement, asked about first.** In the Categories screen (and the Mac sidebar) a drop on the upper or lower part of a row places it before or after that one, among the same parent; a drop on the middle puts it inside that category. Into another group is the same. What the server would refuse (two levels deep, a parent into a category, a category onto itself) shows the not-allowed cursor while dragging and is never sent. Every drop is a dry run of `POST /v1/categories/arrange` first: when a kids viewer would see more the manager sees who and what, and only Allow sends it with that token; otherwise it is sent at once with the dry run's token, so a change meanwhile is asked about too. Undo is the arrangement's undo (⌘Z on the Mac, a toolbar button on iPhone and iPad; no shake, which is easy to set off by accident).

**Merging is the server's.** Several categories into one moves folders, chosen titles, rules and those inside on the server in one change (`POST /v1/categories/merge`), always asked about for kids viewers; an app could not do it atomically with the routes there were.

## D-050 Import folders and uploads: one pipeline, moves only when sure, never over anything

Context: uploading media from the apps, and watching the download folder a server often already has. Details: [imports.md](imports.md).

**One pipeline for both.** An upload, once whole and proven, is a file like one in an import folder: the same rules for what is a feature, the same matching (D-021, with the running time from ffprobe), the same Inbox, the same journalled move. Two ways of judging files would drift apart.

**The first writes into library folders, and only so.** Library folders stayed read-only to Lobby until now. An import writes only below a library folder of the right kind (films, series, or the category a manager chose), only by a rename on the same drive, never over an existing file, and through the journal converting already proved against crashes. Copying between drives is a setting, off by default, and then the copy is read back and compared before the original goes.

**Never guessed.** Only a strong TMDB match with nothing else like it is moved by itself. No key, nothing found, several candidates, a taken name: the Inbox, with the reason and the candidates, for a manager to confirm kind, title, year and destination.

**A folder a download program uses is indexed, not emptied.** Such a program may still serve, check or rename a file after it looks finished, and loses it when it moves. Waiting for a file to go unread for hours and keeping copies until confirmed were both considered and dropped as more machinery than the problem needs: instead such a folder (known by the names converting already avoids) starts in `index` mode, its files listed in the library where they are, and a file moves only on a manager's choice (per file, or the folder switched to `move`). Lobby itself downloads nothing and names no program: a finished file is one with a plain video extension, no control file beside it, unchanged for the wait, and not open elsewhere where that can be seen.

**Deleting is a sentence.** The only files Lobby ever deletes in an import folder are the leftovers of a folder whose film it moved, when everything left there is a leftover, and only when the request says `"delete leftovers"`.

**Uploads: tus-like, into Lobby's folder, at home only.** Pieces at offsets with a SHA-256 each, `HEAD` to resume, the whole file's SHA-256 to finish, as converting's uploads from a Mac already do. iOS background `URLSession` tasks upload from a file, one per piece, so a piece is a request of its own, up to 256 MB. Bytes go to Lobby's folder on the media drive so the move into the library is a rename. Managers only, at home and over Tailscale: the outside entrance keeps every manager's route closed (D-028), the relay is not a road for tens of gigabytes, and opening the direct road for uploads alone would need the entrance to tell its roads apart, a change to the connection layer that waits for its own card.

**Index folders are library sources with a filter.** The scanner lists only the files of an index folder that passed the rules and their wait, so a sample or a file still being written never shows up, and a folder name becomes a category like any library folder (D-012).

## D-051 Plugins only on the server, in their own process, and none from Lobby that fetches media

Context: plugins were considered, for example one that adds a magnet link to a download program on the server, and judged premature. A design, not built: [plugins.md](plugins.md). Plugins would run on the server only, each as its own process with a manifest of permissions a manager approves; the App Store apps never load or show plugin code. Lobby ships and points to no plugin that fetches media from the internet: apps that facilitate that are refused by Apple (guideline 5.2.3), and downloading films without permission is unlawful in many countries. What a household runs beside Lobby stays outside it; the import folders (D-050) take in what lands in a folder.

## D-052 Households: one server, several families, one library

Context: sharing a server with people who have their own household: invited, with their own viewers and kids, using the same library, and perhaps waking their own Apple TVs.

**Sharing outside one's own household may be restricted by law.** Copyright law in many places allows a private copy for one's own household and not for others. Whether and with whom a library is shared is the server owner's decision and responsibility; Lobby makes it possible and says nothing about it on the public site.

**The owner's household is the one that was there.** Migration 20 adds `household`, with one row for the owner (id `owner`), and a `household_id` on devices and viewers that is `owner` for everything so far. Nothing of the history there moves. Progress, plays, kids limits, downloads and the access log belong to a household through its viewers and devices, so they needed no column of their own. The code for grown-ups is per household in `meta` (`kids_code` stays the owner's).

**Shared: the library and what serves it. Per household: people, devices and what they do.** The library, its categories, edits, settings, folders, conversion and the outside switch are the server's, and only the owner's managers change them. A guest household's managers manage their own viewers, kids, devices, downloads, code and outside window, and nothing else. Rejected: a role per route for each household (too many ways to get it wrong), and guests as kids viewers of the owner's household (they need their own managers and kids).

**A decision for every route, as for kids and outside.** `HOUSEHOLD_ROUTES` names, for each route, whether it is the owner's, about the device's own household, about a viewer or device that must be its household's, the shared library, or the music. A guard right behind the credential applies it, before the kids guard; a route without a decision does not exist for a guest, and the tests fail until it has one. Another household's viewer or device is `404`, as one that does not exist; an id nobody has goes on to the route, so a viewer still gets `403` from a manager's route as before.

**A part of the library, said as kids limits are.** The owner can give a guest household all of the library or some groups and categories, in the same lists and with the same rules as kids limits, and it is computed by the same code into the same kind of view. A kids viewer of that household sees what both allow; nothing allowed is nothing (fail closed). Such a household gets no music, which no part of the library describes. The view of a household is kept under `household:<id>` beside the kids viewers' (so `kids_item` loses its reference to `profile`). Kids viewers of guests are not among those the owner's managers are warned about when categories change: they are another household's children.

**Invitation: the outside pairing, once more.** An invitation is the same 80-bit code as a window, for one device, valid for up to 14 days (3 by default), and goes the same two roads with the same six digits. Its first device becomes the guest household's manager, after an owner's manager approved it with the digits the guest reads out, so a link that was passed on lets nobody in unseen. Only the code's hash is kept, with the direct road's room and stretched key, so an invitation outlives a restart. Further devices come in through the guest manager's own window, from outside: pairing at home is the owner's home. That is why a guest manager's routes are open from outside, where the owner's managers act from home only. The introducer keeps one room per server, so the room is that of a device that is pairing, else the newest code; rejected for now: several rooms per server, which changes the introducer.

**What the owner decides per guest.** A bandwidth cap (one pace per household for everything its devices are sent, at home and outside), outside yes or no (yes by default: guests live elsewhere), a number of devices, pause (everything refused, nothing removed) and remove (devices revoked at once, viewers and what they watched gone, never the library). The owner sees which devices a household has and its access log, not what it watches: the owner answers for the server, not for the guests' evenings.

**Popular, Play On and waking stay inside the household.** Plays count per household. On the live channel a device sees and controls only its own household's devices.

**Waking another household's Apple TV is not built.** Waking an Apple TV needs a device on that TV's own network (D-046): the owner's server cannot reach a guest's TVs. Wake stays as it was, for TVs on the owner's network, which only the owner's household can link and wake. A possible later design: a small Lobby helper on an always-on machine in the guest's home (the server package's installer in a helper mode, with `wake.py` and pyatv and no library), paired once to the owner's server as a device of type helper in that household over the outside entrance or the direct road, keeping a live connection, and receiving wake commands for its household's TVs only, with the TV's PIN typed in that household manager's app and relayed. Not built for now.

## D-053 Server admins, household admins and viewers

Context: a device was an admin, who can do everything, or not, who can do nothing. A level in between is needed, a household admin who sets up their own household's viewers; an invitation goes into the current household or a new one; and a server admin creating a household can require their own approval for each new device of it.

**Three levels, in every household.** `access` is `admin` (server admin: everything, only in the owner's household, from home), `householdAdmin` (their own household's viewers, kids, devices, invitations and window, from anywhere) or `viewer`. The owner's managers became server admins and a guest's managers household admins (migration 21). Each route says which level it needs (`HOUSEHOLD_LEVELS`, beside where it is in `HOUSEHOLD_ROUTES`), checked by the tests to be there for every route; the routes check it again themselves. Up to one's own level: a household admin makes household admins and viewers, never a server admin, and cannot touch a server admin's device. The last server admin and a guest's last household admin stay.

**Older apps and servers fail closed.** `role` stays for apps from before: `manager` only for a server admin. A household admin is `viewer` there, not `manager`: an older app would show the server's screens, which would all be refused, and an older server (after a step back) would make them a server manager. The catalogue's `role` column says the same for that reason. Rejected: `manager` for household admins of guest households only, which still leaves an older app with screens that only fail.

**Invitations: this household or a new one.** A household admin invites into their own household, as a viewer or household admin; a server admin also makes a new household, whose first device becomes its household admin, or invites into any household, the owner's too. All of them go the outside road with the code and six digits, so a member of the owner's household who lives elsewhere comes in the same way.

**A server admin's yes, per household.** `requiresAdminApproval`: on, a new device of that household needs a server admin's yes after its household admin's (with no digits: the household admin compared them). On by default for a new guest household and for those already there (fail closed), off for the owner's household until turned on. The request waits, with its usual expiry, as `awaitingAdmin`; a no leaves it as `refused` for its household admin until then. Only a server admin changes it. A server admin approving is final.

## D-054 Kids mode plays on the TV, as the child, and controls only that

Context: kids mode on iPhone and iPad should have a Play On button when there is somewhere to play.

**A child may play on a TV now; before, a kids device controlled nothing.** The rule moved from "a kids device sends no commands" to what the server checks for every command: a child (a bound kids device, or the kids screens of a grown-up's device, by the `profileId` it announces) starts only titles its viewer may see, as that viewer, on any TV it is shown, a grown-up's included. The TV then plays as the child: the app on the TV switches to that viewer, which on the TV is kids mode, left only with the household's code. The child's limits are checked for the title on the target too, and the queue is cut to what the child may see.

**It controls only what plays as itself.** Anything else on a TV, a title the child may see included, is `redacted` for it and refused: a grown-up's evening film is not the child's to pause, stop or play over. Of its own playback it can pause, seek, skip, stop, change tracks, go to an allowed next title and move it to or from its own device. There is no command that browses a TV's library, so none is opened.

**It sees only where it can play.** Targets with Lobby open, not one that belongs to another child; with `allowRemote` off, itself only, as before. The app's kids screens then show one large "Play on TV" button: one TV is one tap, several are large cards with the TV's name. No AirPlay picker of the app's own: the system player's AirPlay stays, for when that is the only way.

**Turning a TV on is the household's choice.** "Kids can turn on the TV" (`remote.wake.kids`, off by default, in the settings with the others and on the Apple TVs page). Off: the child sees only TVs that are on with Lobby open, and `POST /v1/remote/wake` is `404 not_wakeable` for it. The kids screens of a grown-up's device name their channel session in the wake request, so they are refused the same; a request without one counts the device only.

## D-055 A direct path that breaks is made again by the device within seconds

Context: on an iPhone away from home, jumping further in a film's timeline took a long time. The server's log showed direct connections ending with `no path` after two minutes and after half a minute.

**What it was.** Measured on a test road of 70 ms, 1% lost and 20 Mbit/s: with a working path a jump of the player lands in 0.6 to 3 s, but when the path breaks under a playing film (the road goes silent, or the mobile network's NAT gives the phone another port, after which the box hears it from an address ICE does not know and sends to one that is gone), the next jump waited **15.8 s**. The device noticed only when a request had heard nothing for 10 s, then asked a question for up to 4 s, then rang. A player with a full buffer asks nothing, so a path could be dead for half a minute before anyone looked; both ends' ICE then gave up together, which is the `no path` on the Pi. A device that left a connection did not say goodbye either (its ICE agent was gone before the QUIC close went out), so the Pi kept every connection the device moved away from for half a minute and logged it as `no path` too.

**What it does now.** While anything is carried, Apple's QUIC asks the box every second (a PING, answered by an ACK); the ICE bridge on the device notes when the box was last heard. Nothing for 3 s means the path is gone: that connection ends and a new one is rung at once, with the usual waits between failed tries, and what was under way goes on from the missing byte. A jump right after a break now takes about 4 s (3 s to notice, the ring, the restart); a break under a full buffer is mended before the player needs it (a jump 7 s later: 0.2 to 0.7 s). The connection ends with a goodbye that gets out: the Pi logs `left` within a second.

**Rejected.** Following the device to its new port inside ICE (libjuice) on the Pi: ICE's answer to a changed address is a restart, which is what ringing again is, at about a second on the Pi's own log; changing the agent's pair selection in vendored C for both ends is more risk than that second. QUIC keep-alives from the box every second: they would keep an idle phone's radio awake for as long as the app is open; the device asks only while it carries something. Sending what a player gave up last on the box (`set_priority`): no measurable difference (4 to 5 MB wasted per drag over the bar either way, the jump in 0.5 to 1 s); a reset would cut that, but Apple's QUIC takes the connection down with it (see `apps/direct`).

## D-056 Wake and Play: the server keeps the play, and gets past "who is watching"

Context: a real try of Play On → Living Room → Wake and Play. The server woke the TV twice without an error (pyatv `turn_on` and `launch_app` went through), but the TV stopped on tvOS's profile picker, where tvOS opens no app. A profile was picked by hand; Lobby then opened on what it showed before (another film), and the film never came: the phone had given up after its 15 s wait for the TV on the live channel.

**The server keeps the play, not the phone.** `POST /v1/remote/wake` takes the play along, and the server sends it the moment the TV's Lobby announces itself and can play, for three minutes by default (`remote.wake.holdPlaySeconds`, in the file). The phone can be closed meanwhile. The phone still shows each step, and can cancel. Rejected: a longer wait on the phone (the person puts the phone down or closes the app to go and find the remote; the film must still start), and the TV fetching "what should I play" at launch (a second way in for commands, with its own rules; the live channel already says who asks and is checked).

**Only the latest per TV.** Two people waking one TV for two films is a race either way; the last one asked is what the TV shows, and the other learns it was `superseded`, as with commands.

**Checked twice, the second time with what is true then.** Before waking, so that a TV is not woken for a film that would be refused. When it is sent, again from the start, failing closed: the sender may have been removed, lost `allowRemote`, gone to kids mode, or the child's limits or "Kids can turn on the TV" may have changed in those minutes. The viewer the sender had when it asked and the one its session has now must both be allowed. The play is sent as from the sender's device, which is still a device that may.

**Past the picker with one press of select.** The picker comes with focus on a profile, usually the last one used; select takes it. Lobby Server waits about six seconds for Lobby on the live channel, then presses select once and opens Lobby again (`remote.wake.pickProfile`, on by default, a setting in the app). It picks whichever profile is focused, which the setting's help says; a household that wants another profile, or none chosen for it, turns it off or turns off profiles on wake on the TV. At most once per wake: a second wake for the same TV while one is under way joins it.

**How it knows Lobby is not there: its own channel, not pyatv.** pyatv 0.18 over Companion alone cannot say which app is in front: `metadata.app` needs MRP, which on tvOS 15 and later goes over AirPlay with AirPlay credentials Lobby does not pair. `wake.py` looks when pyatv can tell (`FeatureName.App` available) and then presses select itself; over Companion it says it cannot tell (`front: null`) and the server decides by whether Lobby announced itself. That is also the more truthful signal: Lobby open and able to play is what the play needs. Rejected: pressing select always (it would press a button inside Lobby when it was quick to open), and `switch_account` (it chooses an account by id, which Lobby cannot know is the right one).

**The TV replaces what it shows, and skips who is watching.** A play that comes at launch or over another title closes that player, opens the new title's page behind its player, and plays as the viewer it names. The channel's `hello` says `pendingPlay`, and the TV then shows "Starting…" instead of its own "who is watching" until the play comes (at most 20 s; 3 s at launch until the channel answers). This needs the TV app of this change; an older one plays the film too, but over what it showed and after its own viewer question.

**Play On lists Lobby TVs first.** The household's Apple TVs with Lobby come first, with what each does: "Lobby open", "Will wake", or "Asleep — can't be woken (link it in Apple TVs)"; other devices and AirPlay below under "Other Devices". AirPlay is never on its own above a Lobby TV.

**Letting a device in says as what.** On a waiting device's request the role is chosen first (Viewer, Household Admin, and Server Admin for a server admin), Viewer until changed, and the button says "Let In as …". The quick "Approve" made a device a viewer when an admin was meant.

## D-057 Subtitles per viewer, and picture subtitles drawn by the app

Context: subtitles were not handled, and many viewers need them.

**Each viewer chooses, the player follows.** A viewer has subtitle languages in order (none: off), forced subtitles (on by default, kids too), a size and a background. A film starts with the first of those languages it has; else, with forced subtitles on, forced ones in the sound's language. Full subtitles are never taken for forced ones, nor the other way round. What the viewer picks while watching goes before the preferences for that title, also when the film is opened again. Kids screens choose by the preferences and offer no menu.

**Timing per title.** Subtitles move in half seconds, kept per viewer and title on the server. The player's own subtitles cannot be moved, so a moved subtitle is drawn by the app from the server's copy of the same track.

**Picture subtitles become placed pictures, not text.** AVPlayer shows no PGS, DVD or DVB subtitles in a stream, and text would need OCR, which guesses. The server lets ffmpeg draw the track onto a canvas of the video's size and keeps each change as a PNG cut to what it shows, with its place and times (`GET …/subtitles/{id}.json`); the app draws it over the picture, fitted as the film is. One pass over the file, kept like converted text subtitles. Rejected: OCR to WebVTT (wrong letters in every other line of a Blu-ray), burning them into the copy (one copy per subtitle, and no off), and a picture track in the HLS stream (not shown by AVPlayer). Downloads keep only text subtitles for now.

## D-058 What happens when something ends is the viewer's, not the device's

Context: when a film ends it may suggest others but should not start the next by itself; a series goes on to the next episode, and asks after the third whether someone is still watching. These are settings per viewer, not per device.

**Kept on the server, with the viewer.** `Profile.playback`, changed with `PUT /v1/profiles/{id}/playback` like the subtitles. Only what the viewer chose is stored (migration 25), so the rest follows the defaults of their kind. A TV that plays as a viewer, from Play On too, goes by that viewer's; the phone that controls it sees the same Up Next and answers it.

**Defaults.** A film ends on suggestions and starts nothing by itself. A series goes on to the next episode after 10 seconds, over a season's end, and asks "Still watching?" after the third episode in a row without a touch; a kids viewer after the second. Any touch, on the device or from a remote, starts the count again. Asking only before something would start by itself: a film without autoplay never asks.

**A kids viewer's are the grown-ups'.** Only a manager changes them; the child's device gets 404. Rejected: letting the child turn autoplay on, the way it may choose its subtitles.

**Credits markers are not guessed.** "Start next at the credits" is kept, and Up Next comes at the end until the server knows where credits begin. Rejected: a fixed share of the length, which cuts off films with a scene after the credits.

## D-059 Skip Intro: found by comparing a season's sound, on the server, at night

Context: a Skip Intro button was wanted, and Lobby did not know where intros are. Migration 27.

**Three sources, the first that says something wins.** A server admin by hand; the file's chapters ("Intro", "Opening", "Opening Credits", "OP" for the intro; "Credits", "End Credits", "Ending", "ED" for the credits), when they make sense (an intro of 5 s to 5 min in the first half, credits in the second half); then what Lobby found. Chapters are cheap (headers only) and read first, for films too. A manual "there is none" hides what was found. Chapters and findings hold for the file version they were read from; manual ones also after converting.

**Found the way Jellyfin's intro skipper and Plex do: the episodes of a season share the theme.** For each episode, ffmpeg decodes the first 10 minutes (or a quarter of it, whichever is less) and the last 8 minutes (also at most a quarter) to mono 5 kHz samples down a pipe; nothing is written but the fingerprint and nothing is played. Every 100 ms, 33 bands between 300 and 2000 Hz of a 0.41 s window give 32 bits: whether the difference between neighbouring bands grew since 300 ms before (after the Philips fingerprint; it compares with the frame just before at a 12 ms step, which Lobby cannot afford; at 100 ms steps with a 100 ms lag, two copies of the music half a step apart matched in only 30% of frames, with 300 ms in 60 to 97%). Two episodes are laid over each other at every shift; frames that differ in at most 10 bits match, silence never does, gaps of up to 1.2 s are bridged, and the longest run wins: an intro of 15 s to 3 min, credits of at least 20 s. Each episode is compared with up to four others, nearest first (other seasons of the show only to make up for a season of one), and the stretch most comparisons agree on is taken, its edges the middle ones. Confidence is how many agree times how well they matched; below 0.5 it is kept but not shown.

**A season's theme, once known, makes the rest cheap.** When two or more comparisons agree with confidence 0.7 or more, that stretch of that episode is the season's theme (an intro its chapters name is one too). A new episode is then compared with the theme alone; only when that is unsure are its neighbours asked as well.

**Why not Chromaprint.** It is the better-tested fingerprint (intro skipper uses it), but Homebrew's ffmpeg on the Mac it was built on has no `chromaprint` muxer and there is no `fpcalc`, the Docker image and other installs would differ again, and a Pi was not checked (Debian's ffmpeg is usually built with it, and `libchromaprint-tools` has `fpcalc`). The in-process fingerprint is the same on every machine and tested with generated episodes: a theme at 3, 12.5, 21 and 34 s in four different backgrounds is found within a second in each, against its neighbours and against the theme, and nothing in another show's episode.

**At night, slowly, never in the way.** A background job, one file at a time: chapters of everything first, then per season the fingerprints, then the comparisons. It works only when converting may (`conversion.hours`, nobody watching or downloading for 5 minutes), in a process of its own at niceness 19 (and `ionice -c 3` on Linux), stopped with SIGSTOP while it should not run. Every step is kept as it is done (`marker_scan`, fingerprints in `markers.cacheDir`, by default `<dataDir>/cache/markers`, about 55 KB an episode), so a restart goes on where it stopped; a file that fails three times is left until it changes or a server admin asks. A server admin can have a season looked at again: then at any hour, still at the lowest priority. Playing never waits for it.

Measured on an M3 Pro Mac: fingerprinting 10 minutes of a 720p H.264 MKV with 5.1 AC3 takes 3.1 s of CPU (ffmpeg's demuxing and decoding most of it, 0.2 s the fingerprint itself), and one comparison of two 10-minute prints 0.22 s. An episode of 45 minutes (18 minutes fingerprinted, eight comparisons) is about 7.5 s of CPU. A Pi 5 is three to four times slower per core for this: about 25 to 30 s of CPU per episode, plus reading roughly 40% of the file from the USB drive. A library of 1,000 episodes is then some ten hours, a few nights. Not measured on the Pi.

**In the apps.** Skip Intro shows from the intro's start until 2 s before its end; Next Episode shows from where the credits start, and that is where an up-next countdown starts (`PlayerModel.creditsStartMs`). Per viewer, kept on the server with the viewer: intro "Show Skip Intro" (default), "Skip Automatically" (once per film: going back into the intro shows the button), "Off"; credits "Show Next Episode" (default), "Off". Kids viewers have the same, set by a grown-up: a child's device cannot change it. On the Apple TV Skip Intro is the system player's contextual button, which the remote's focus goes to. A phone that controls another device's player shows Skip Intro too, and leaves automatic skipping to the player.

**Not now.** Films get credits only from their chapters. Finding credits in the picture (black frames, rolling text) is a later idea, as is finding a recap ("Previously on").

## D-060 Statistics: sittings from places, kept two years, each household its own

Context: statistics pages for viewers and for the server: what is watched, when, and so on. Migration 24.

**Sittings, worked out from the places the apps already report.** No new report from the apps: a `PUT …/progress` moves a viewer's place, and how far it moved (as the popular titles count it, no faster than twice the speed) is time watched. The same viewer, title and device without a pause of 30 minutes is one sitting (`watch_session`). The request says the device and the road (home, the tailnet's `100.64.0.0/10`, the relay, the direct road); a `POST …/playback` from that device in the last 12 hours says whether it was sent as it is or prepared, and a downloaded copy on the device says download. A Play On to that device in the last 15 minutes names the device that sent it. These two are remembered in memory only: after a restart a sitting may be `unknown`, which is honest. Marking a title watched without watching is no sitting. What was watched before comes from the daily plays (half a year), as one untimed sitting a day: it counts for days and months, never for hours. Rejected: a new report of sittings from the apps (older apps, offline devices and the Apple TV would each need it, and the places are already there); counting the bytes of a stream as watching (a download is not watching).

**Listening is the music history.** It is already one row a play with its length; the statistics read it. Bytes sent are counted per hour, household and road as they go out (a stopped film counts what went); prepared copies and conversions note what they took when they finish.

**Kept for two years, then gone.** `statistics.keepDays` (30 to 3650, 730 by default) is a setting with the others. Everything older is deleted once an hour at most, the music play history included, and nothing older is taken in. Forgetting a viewer's history (household admin) deletes their sittings, daily plays and music history; their places in titles stay, since those are what Continue Watching is, not history. One sitting can be removed from a viewer's history by anyone who may be that viewer.

**Who sees what** (superseded by D-066). There is no sign-in per viewer: whoever may be a viewer on a device of the household already reads their places, so they read their statistics too, a child's included (the grown-ups' view of a kid). A child's own device sees its own child only, and simply: no history, devices or roads, and only titles it may see now. A guest household sees only its own viewers, and of a household with part of the library only that part. The server page is for server admins, at home: other households are totals there (time, viewers, devices, bytes) unless the admin opens one. Every route has its decision in the three guards; outside, a viewer's page is read like their places and everything else waits for home.

**Worked out when asked, by the index.** Sittings are read by `(profile_id, started_at)` or `started_at` and summed in the server, in the viewer's time zone (each quarter hour's offset worked out once). 50,000 sittings take well under a second in the tests. Rejected: tables of sums per day, which could not change time zone and would need keeping in step with removals.

## D-061 Search: the whole library by words and filters, and TMDB beyond it, never IMDb itself

Context: search should be extensive: by name, actors, year (from, to, exact) and rating (Rotten Tomatoes among them), and IMDb's titles beyond the library, which of course cannot be played. Migration 26.

**IMDb is linked to, never asked.** IMDb has no open public API, and its pages are not Lobby's to read (scraping is against its terms, and breaks). TMDB, which the server already asks with the operator's key, has the people, the cast and crew, the titles that are not in the library, and the IMDb id of each, so "Open on IMDb" is a link made from that id. What is found there is shown under "Not in your library": it cannot be played, it never becomes a library item, and TMDB's answers are kept in memory only (an hour for a search, a week for an IMDb id or a picture), so typing the same again asks TMDB nothing. TMDB allows about 40 requests a second and asks for its notice where its data is shown; the apps show it under those results. Each device may ask beyond the library 30 times a minute (40 at once), the same polite client as the matching otherwise.

**Rotten Tomatoes, IMDb's own rating and Metacritic come from OMDb, only with the operator's key.** Rotten Tomatoes has no open API either. OMDb answers per IMDb id with IMDb's rating, the Tomatometer (critics) and the Metascore, but it needs a key of its own (free: 1,000 requests a day), and its data is CC BY-NC 4.0, non-commercial: fine for a household's own server, and why it is the operator's choice and off by default. Without a key OMDb is never asked anything. With one, the server reads the library's titles a hundred a run, at most 900 a day, keeps each answer per IMDb id and asks again after 30 days; "not found" is kept too. OMDb's terms say nothing of caching; keeping a month is what makes it fit the daily allowance at all. Rotten Tomatoes' audience score is not in OMDb's answer any more, so there is no such filter. Every rating says its source; TMDB's average stays the one that is always there.

**One index, in the catalogue.** SQLite FTS5 (in node:sqlite's own SQLite): titles, other titles (TMDB's alternative titles and translations), people with the characters they played (the first 30 of the cast in billing order, directors, writers, a show's creators), studios, genres, the collection and the summary; an episode by its title and its show's. Words match from their start and without accents (unicode61, remove_diacritics). With few results, a word a letter or two off a known word (Damerau edit distance, none for words under four letters) and parts of words (a trigram index of titles and names) count too. The index follows the library revision, plus the titles whose people changed, so it is kept up to date in small steps. The people come with a title's details when it is matched; what was matched before gets them in the refreshes, 40 titles a run, the way the studios did.

**A small query language, and the chips write it.** `actor:"Tom Hanks" year:1990..1999 rt>80`: what someone types and what the filter chips make are the same words, read by one parser; what is not a filter it knows stays a word. Filters of `/v1/library/query` are taken too. A title without the rating asked for is in no range, as a title without a year is in no years.

**Kids and households first, failing closed.** The library part is filtered by the kids limits and the household's part of the library before anything else. A kids device, and any device searching as a kids viewer, gets no results from beyond the library and no person beyond the titles the child may see; those routes are `404` for it. A guest household sees beyond the library like anyone: TMDB's data is nobody's, and a title of the library it may not see shows there as not in its library, which tells it nothing.

**On the TV, a QR code.** tvOS has no browser, so a title that is not in the library shows QR codes of its IMDb and TMDB pages, for a phone.

Rejected: scraping IMDb or Rotten Tomatoes (their terms, and pages that change), the IMDb datasets (non-commercial too, gigabytes, updated daily: too much for a Pi), searching TMDB on every key press (the field waits for a pause, and the library answers first), and keeping outside results as items (they would sync to every device and could never be played).

## D-062 Kids control: when and what, from the server, failing closed

Context: grown-ups should set, from an admin's device, when a child may watch and what (only audio, video too, or nothing at all), then rules by location, then a request mode in which a grown-up accepts on their own device, mostly as "Ask to open". The whole model is [kids-control.md](kids-control.md); this is what was decided in it.

**Four modes, in the order of strictness:** Everything, Ask first, Only listening, Nothing. Ask first is Ask to open (the main one: the app only asks, a grown-up answers Watch, Listen or No for a while) or Ask per title (browsing and listening free, video per title). Kids limits (D-027) stay which titles; this is when and what kind, and never lets a child see a title its limits do not.

**Sources and precedence.** A weekly schedule (blocks per weekday with a mode, a default), the away rule (not on the home network: the outside entrance, the direct road and the tailnet), named places (geofences watched only on the child's device), screen time (video minutes per weekday and weekend day) and a grown-up's override. The override wins while it runs; otherwise the strictest source; an answer to Ask first lifts only Ask first, never a stricter mode, so "Watch for 2 hours" at 19:00 ends at bedtime. Only listening is stricter than Ask first, and needs no asking. Overlapping blocks: the strictest. Local wall time in the household's time zone (`household.time_zone`, the server's when unset): a block starting in the hour that does not exist starts when it ends, and in the hour that is there twice the wall clock decides.

**Enforced on the server, failing closed.** A second table beside `KIDS_ROUTES`, `KIDS_MODE_ROUTES`, names for every route a kids device can use what the mode must allow: always (what keeps the app going and tells it its mode), app, browse, watch, listen. A route without one is refused, and a test fails until it has one. A refusal is `403 kids_mode` with the current mode, because the device knows its own mode: it is not a secret like a title's id, and the app needs it to show the resting screen instead of an error, and to keep its downloads. What is being sent is cut within a second of a switch; the live channel tells the child's device and a TV playing as the child (`kidsMode`), and the app ends the film itself. Play On and waking a TV for a child need Everything (or an answer that gives it), checked by the hub on the target and on the child's own device.

**Music for kids.** Until now a kids device had none (D-027, D-044). Now music is on for every child unless a grown-up turns it off, wherever the mode allows listening, and limited to the music libraries chosen for the child (`musicSourceIds`, all by default; checked when a song is played, the listing itself is the household's); off, music is `404` as before. Per-album music limits stay a card of their own. A guest household with a part of the library still has no music (D-052).

**Places never send where the child is.** The device tells the server only "inside place X", "inside none" or "cannot tell"; `PUT /v1/me/kids/place` refuses any other field. The server keeps only the last state per device, in memory, for six hours. Cannot tell, permission off or nothing said yet: the "location unknown" mode, by default the strictest place's.

**Who decides.** The child's household's admins and the server's admins, also for a guest household's child; never another guest household, never a viewer's device, never the child's own (the routes are `404` there). Optionally only chosen grown-ups (viewers with their devices) are asked, and the child's screen names them. Answering, overriding and ending are open from outside for them (`kids` in `OUTSIDE_ROUTES`); changing the plan is not.

**Asking.** One open question per child, ten minutes, at most six an hour (`429`). The first answer counts; later answers are `409`. Answers run until the plan's next switch when that is today, else an hour, or as chosen (up to a day), and can be switched Watch ↔ Listen or ended from a grown-up's device. Every other grown-up sees at once who answered what (`kidsRequestClosed` with `answeredByName` and `grant`). In-app over the live channel, and as a push through APNs with Watch, Listen and No on the lock screen.

**Screen time** counts the time between close progress reports of a kids viewer (at most the wall time between them: a seek forward is not watching), per child across devices, per local day; a device that was offline sends its own count and the larger holds.

**Offline: a signed copy of the plan.** `GET /v1/me/kids` gives the plan, override, answers, screen time and time zone signed with an Ed25519 key of the server (made once, kept in `meta`), valid for seven days. The device pins the key the first time. Offline, now is the last server time plus the device's monotonic clock since; after a restart the device clock, never earlier than the latest trusted time; when the two disagree by more than two minutes the stricter mode of both holds. An expired copy holds the strictest mode it names anywhere; no copy at all is Nothing. Offline is not away: the copy holds as it is.

**Rejected:** Ask first stricter than Only listening (a child would have to ask to listen under a "listen only" rule: stricter than either rule said); enforcing in the app only (the app on a child's device is not trusted, D-027); sending coordinates and comparing on the server (the server has no business knowing where a child is); an HMAC instead of a signature (the device would hold the secret that makes a plan).

Migration 23 adds `kids_plan`, `kids_override`, `kids_request`, `kids_grant`, `kids_screen_time` and `household.time_zone`; migration 28 adds `push_token`.

**Push.** Through APNs over HTTP/2 with the team's token-based key: one key serves all of a team's apps, so an existing one can be used. The config names its file (`push.apns.keyFile`, `keyId`, `teamId`, `topic`), owner-only and outside the code; the server signs an ES256 provider token with it, says only whether push is configured, and never copies, logs or returns the key. Each device sends its token with `development` (a development build, APNs sandbox) or `production` (TestFlight, App Store). A token Apple calls gone is forgotten. Migration 24 adds `push_token`.

## D-063 A pairing room for every open code, at one introducer

Context: found while trying the App Review demo through the public introducer: six invitations were open, and only the newest paired; the others got "Nothing waits for this code". The introducer kept one room per box, and the server said only the room of the code a device was pairing with, else the newest. App Review needs a code per platform, an owner may invite two households at once, and a manager's window may be open beside them.

**Every open code has its own room**, made from the code as before, so nothing changes in the apps or in `direct-vectors.json`. The box says the introducer all its rooms in one message (`rooms`), and the introducer says by which room a device's message came (`room`), so the box opens it with that code's key. At most 64 rooms per box: the ones a device is pairing in first, then the newest; beyond that the oldest wait, and the log says so. Each room keeps its three devices at a time, a box 24 in all its rooms, and every message still counts against the daily cap. Rooms still end with their code, and 45 minutes after they were last said.

**Both ways round still work.** The introducer says in `ready` how many rooms it keeps; a server from before never asks and keeps saying one room with `pairing`, which still replaces all of the box's rooms. A server talking to an introducer from before says one room with `pairing`, as before, and takes a message without `room` to be for that one. So the introducer and the servers can be updated in either order; only both together let every code pair.

**Rejected:** one shared room per box, with every code's key tried on each message (the room is made from the code, so a device would have to know the box instead, and the apps would change); a new protocol version (what was added is ignored by what came before, both ways); making the room from the box as well as the code (the apps would change, and an invitation would no longer be just a code).

## D-064 Push through a relay, so every server reaches the App Store apps

Context: Apple takes pushes for the App Store apps only when they are signed with the APNs key of the team that publishes them, so a server with that key could reach them and no other could. The key is the publisher's and is not given out, so a Lobby Server someone runs at home cannot have it. The answer is a small relay run by the publisher, like the public introducer.

**A Cloudflare Worker, `lobby-push` (`apps/push-relay`), holds the key** as a secret and sends to Apple with `fetch` (HTTP/2), with an ES256 provider token it keeps for 50 minutes, over a restart too. Any Lobby Server may use it, under these rules:

- **A server proves it is a box**: it signs each send with the Ed25519 key it also uses with the introducer, and its box id is the hash of that key. No list of boxes: any household may use it.
- **The app registers its token, not the server.** The server gives the app a ticket its box signed (ten minutes); the app sends ticket and token to the relay and gets a handle back, which is all the server learns. The relay sends a box's notifications only to handles registered under that box's ticket. A server never sees a token, so it has none of anyone else's to push to, and a stranger cannot fill a box's list without its signature.
- **The text is sealed** with a key the app makes for each server and gives it with the handle (ChaCha20-Poly1305, `docs/push-vectors.json`). The relay puts a generic alert around it ("Lobby: A request is waiting."); the iPhone and iPad app's notification service extension opens it with the key from a Keychain group it shares with the app, and shows "Robin wants to watch …" with Watch, Listen and No. Answers go from the app to the server directly, as before.
- **Limits**: 2,800 characters sealed, 32 devices a send, 64 devices a box (the oldest goes), 30 sends a minute and 1,000 notifications a day per box, 30 an hour per device, 20 registrations a minute per address and 200 a day per box, `DAILY_CAP` in all. Each send carries a growing time, so one that is said again is refused. Handles not registered again in 60 days are forgotten, as are those Apple calls gone. The apps register at every start.
- **What the relay sees**: box ids, handles, device tokens and their environment, when and how much, the addresses of servers and apps, and ciphertext. Not the text, not who or which title, not the server's address at home. It keeps the handle list and counts, no log.

**`push.mode`**: `relay` (the default once the relay's address is in the code, `DEFAULT_RELAY`, or named in `push.relay`), `direct` (a key of one's own, for apps built under one's own bundle id: what every server did before the relay, and still does while its config has `push.apns` and no mode), or `off`. Direct mode is unchanged.

**Not yet**: the Mac app has no notification service, so on a Mac a relayed notification shows the generic alert without actions; opening the app shows the question. tvOS gets no pushes. The relay cannot tell an app's registration from a stranger's who holds the same box's ticket and somebody's token; App Attest would, at a cost.

**Rejected:** giving servers the key (it is the publisher's, for all its apps); the relay keeping a list of allowed boxes (every server's owner would have to ask); the server registering tokens (it would learn them, and could register any it learned); a silent push to prove a token (background pushes are throttled and need another mode); one sealed text for all devices (a key per device and server lets one be removed alone); text in clear for the Mac (the relay would read it).

## D-065 Why a file is repackaged is said to server admins, on the title's page

Context: under Play, a film's page said what Lobby Server does with an MKV or an old AVI before it plays ("The file is MKV, which has to be repackaged as MP4…"). For a family watching on a phone that is noise between Play and the summary, and nothing they can act on.

**Only a server admin's device shows it**, as one short line under Play: they are the ones who can replace the file or convert it (D-026). Everyone else just presses Play; the player says why the first start takes a moment, while it waits ("Files in a format Apple devices cannot open are repackaged once"). Notes that are about the device itself, such as an older copy on this device being played, are shown to everyone.

**Rejected:** dropping the line for everybody (the admin then learns it only by playing); moving it into Details (still a format explanation, now hidden from the one person it helps).

## D-066 Who sees which statistics: admins their households, everyone else themselves, children none

Context: D-060 let any device of a household read any of its viewers' statistics, a child's own device its child's in a simple form. The owner's rule is narrower: a server admin sees everyone, a household admin their own household, a regular user only themselves, and kids no statistics. Supersedes the part of D-060 called "Who sees what".

**By level.** A server admin sees every viewer of every household and the server's page. A household admin sees every viewer of their own household and its overview (`GET /v1/stats/household`): the server's page cut to that household's sittings, listening and bytes, without anything of the server (preparing, converting, the library, storage) or of other households. Anyone else sees only their own viewer. A child sees nothing: a kids device gets `404` for every statistics route, and the kids screens have no statistics. Admins still see a child's statistics, since they are the parents. Taking a sitting out of a history follows seeing it; forgetting a viewer's history stays with the household's admins and the server admins.

**"Themselves" is the viewer in front on the device.** There is no sign-in per viewer: a device may be any grown-up of its household, and switching viewer is how a shared Apple TV or iPad is used. So the server cannot tell the person, only the viewer the device is being. It takes that from the live channel, where the app already says who is in front (`profileId` in `POST /v1/live/{session}`, which kids control already trusts, D-054), and keeps it per device while it runs, past a closed channel. A device that is not an admin reads only that viewer's page. Until its app has said, after a start of the server for instance, it reads none (`403`), and the app says so. A viewer of another household named there counts for nothing. A device whose viewer in front is a child sees no statistics at all, an admin's too: the kids screens of a grown-up's device are the child's.

**What it does and does not keep out.** It keeps one grown-up's page from another's device and screens: seeing someone else's means switching the device to them, as their Continue Watching and places already need, and that is visible to whoever uses the device next. It does not stop someone who switches to another grown-up, or who writes their own client and says another viewer is in front. That needs a lock per viewer, which Lobby does not have. Rejected: the viewer named in the request or a header (the same as the path, so no check at all); the viewer whose place the device moved last (nothing for a device that has not played yet, and wrong after a switch); binding each grown-up's device to one viewer, as kids devices are (it does not fit a shared TV or iPad, and needs a new setting on every device). Relying on the apps alone to hide the other pages was rejected too: the server refuses them.

**Older apps.** `simple` stays in a viewer's page, always `false`, since older apps read it. An older app on a kids device gets `404` and shows that the server has no statistics. An older app on a regular user's device still shows a household's viewers' pages, which the server now refuses with `403`.

## D-067 Stories: audiobooks for a child who listens, and beside their films

Context: read-along stories (one file each, the cover inside, the reader in every name tag) in an `audiobooks` folder, for children who may only listen as much as for anyone else; and the films they were made from, in the same library.

**One word: Stories.** The apps call the audiobooks Stories everywhere: the kids' place, the grown-ups' Music section, Home's row, the Apple TV. The server, the API and the folder hint keep "audiobooks". Rejected: Audiobooks for grown-ups and Stories for children, two words for one shelf.

**A child's place.** While the plan lets the child listen, the kids bar has Stories after Home; in Only listening that page is the whole kids screens ("Time to listen"), with the way out for grown-ups at its foot, so a child who may not watch never lands on an empty page. Big covers with names to choose by, Keep listening (also on kids Home) that goes on at once, then Music, whose albums play at once. A story's page has the cover, the title, who reads it, its length and what is left, one Play, Resume or Play again, and Say it. The Apple TV has the same place and pages; in Only listening only the child's own page and Stories.

**A player a small child can use alone.** Over the whole screen: the cover, the title, a bar of how far without a scrubber, back 15 seconds, a big play and pause, forward 30 seconds (previous and next for music), and a sleep timer of four choices in words: when the story ends, in 15 minutes, in 30 minutes, keep playing. No speed, queue or AirPlay: those are the grown-ups' player. A bar over the kids tabs shows what plays. It is the same `MusicPlayer`; only the screens differ.

**The child's own place in each story.** Music's progress, favourites and listens are kept for the kids viewer as for anyone (the server allowed a kids device its own viewer's music already, `music_viewer`). The app used to keep none for a child, from when children had no music (D-044). Choosing a viewer now fetches their music at once, so a story resumes where it was left on another device.

**A story and its film meet by title, in the apps** (`StoryFilms` in LobbyKit). Case, accents, punctuation, "&" against "and" and a leading article do not count; only films, never a series; of a film and its remake, the latest that came out by the story's year, else the first. Only from what the viewer has: a child's own films, so Watch the film never leads to one it may not see, and only while the kids screens show films. A film's page has Story (Listen to the story for a child) while the viewer may listen. Rejected: matching on the server (it would apply each child's limits a second time, and the apps hold both lists already); TMDB ids (audiobooks have none).

**A reader is not the writer.** When the only names on a story are its reader's (artist, album artist and composer alike), the apps show "Read by …" and no author. The server still says what the files say.

**Grown-ups.** Continue Listening under Continue Watching on Home and at the top of Music; a Stories row on Home; Stories in the Music section.

**Not built.** Limits per story or album for a child (as for music, a card of its own); searching stories on the kids screens; Watch the Film on the Apple TV's grown-up story page.

## D-068 Play on a speaker: the server streams music and stories to HomePods over AirPlay

Context: "Can the Lobby app on iPad and iPhone also say Play on HomePod?" Play On listed Apple TVs and other Lobby devices, which play titles themselves (D-036, D-043). A HomePod runs no Lobby; the system's AirPlay sends what the phone plays, and stops when the phone goes. The phone should be only the remote, and be able to leave.

**The server plays, through the helper of the Apple TVs.** pyatv speaks AirPlay's audio protocol (RAOP) too, to HomePods, AirPort Expresses and other AirPlay speakers, including the transient pairing HomePods ask for. `tools/wake.py` gets `speakers`, `stream`, `stream_stop`, `volume` and `speaker_password`; Lobby Server keeps the one helper it has. It needs `remote.wake` in the file (where pyatv is) and the setting `remote.wake.speakers` ("Play on HomePods and speakers", on). Rejected: AirPlay from the phone (it stops with the phone, and the app cannot choose the receiver, D-043); a second runtime or library for AirPlay in Node; the server playing through a Lobby device.

**The server's own files, decoded by ffmpeg into FLAC, straight to the speaker.** The helper runs the server's ffmpeg on the file in the library folder, from the place asked, as 44.1 kHz 16-bit stereo FLAC, and hands that stream to pyatv's `stream_file`. Every file of the library plays that way, also those AVPlayer does not (Opus, Ogg), whatever pyatv's own decoder knows, and nothing goes through Cloudflare, a relay or anything outside the house. Rejected: the compact AAC copies (pyatv cannot decode AAC, and a copy may not be there yet), a URL of the server for pyatv to fetch (it would need a pass, and the server need not listen on loopback).

**Paused by stopping, gone on by streaming again.** pyatv's RAOP client has no pause of its own; its pause stops. So the server keeps the place: pause stops the stream, resume, back 15 s, forward 30 s, previous, next and a jump stream again from the new place, a second or two of silence. The server keeps the queue (the tracks of an album, or the files of a story) and goes on to the next track when one ends. Back and forward cross from one file of a story to the next.

**In memory, with the viewer's place written as the apps write it.** What plays on a speaker is in memory and gone when the server stops, like everything of Play On (D-036). It plays for a viewer: the place in a story is written for that viewer every 15 s and at pause, stop and the end (`music_progress`, the 5-second rule of the apps for finished), and every track that was heard is a listen (`music_play`, judged as `MusicPlay.judge`). So a story goes on at the place it stopped on the speaker, on any device, and the statistics count it.

**Who may: the owner's household, at home, as on a TV.** The speakers are on the owner's network: only devices of the owner's household see them, like the Apple TVs that can be woken (D-046, D-052). Starting needs an address at home or in the tailnet; the outside entrance has no speaker routes and its sessions see none. A device needs `allowRemote`. A manager can rename and hide a speaker, and keep a password for one in pyatv's file, beside the Apple TVs' credentials and as unreadable to Lobby. PIN pairing is not built: a HomePod has no screen to show one, and its access is a setting of the Home app ("Allow Speaker & TV Access"). A speaker that lets only its Home play says so, before trying (the `acl` flag pyatv reads) and when it refuses ("speaker_refused" with the way out in words).

**Children: as local playback.** A child (a bound kids device, or the kids screens of a grown-up's device, by its channel session) plays only as itself, only while its plan allows listening, and only from the music libraries it was given; music off for it is "not there" (`404`), as for its songs (D-062). The kids guard checks the start (`listen`) on a bound device; the service checks the same for every child, for the start and for going on. What plays as a child stops when its plan stops allowing listening (looked at every 5 s). A child sees speakers only while it may listen, sees another's music as "Playing", cannot control it, and cannot play over it (`409 speaker_busy`). The kids screens have one big "Play on Kitchen" on a story's page and a remote of big buttons: play and pause, back 15 and forward 30 (previous and next for music), quieter and louder, stop.

**On the channel, not as devices.** The live channel gets a `speakers` event with the speakers a session may play on and what plays there, sent again when that changes, as with devices. Speakers are not `ShownDevice`s: they run no Lobby, have no session, and are not told commands; their routes answer at once with what plays now. An app that does not know the event ignores it.

**Apple TVs and Macs are not speakers here.** They advertise AirPlay audio too, but are in Play On as themselves; as speakers they would be there twice.

**Not built.** Several speakers at once (a group); shuffle and repeat on a speaker (the queue goes in order, as sent); a story's chapters and the sleep timer on the speaker's remote; PIN pairing for speakers with a screen; speakers of a guest household's network; Play On to a speaker from the Apple TV.

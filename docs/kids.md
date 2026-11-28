# Kids in Lobby

Everything Lobby does for children, in one place: who is a kid, which titles they see, when and
what they may do, what they see, and how a grown-up gets out. For whoever runs a server and for
whoever works on it. It describes what the code does on this branch. Where something was specified and not
made, it says **not built**.

Two other documents go deeper. [kids-control.md](kids-control.md) is the design of *when and
what* (modes, schedule, places, Ask first, offline). [api.md](api.md) is the contract. This page
does not repeat them; it says how the parts fit and what a person sees.

The rule under all of it (D-027): **the app on a child's device is not trusted**. The server
decides what a child gets, and anything it was not told about is closed.

## 1. Kids viewers and kids devices

A **viewer** is one person's place in Lobby: their progress, Continue Watching, picture and
preferences ([api.md, Profiles](api.md#profiles)). A **kids viewer** is a viewer with kids limits
(`kids` is not null). Only a manager makes one: on the viewer's page, **Kids Viewer**.

There are two ways a child uses Lobby.

| | A device bound to a kids viewer | Kids mode on a grown-up's device |
| --- | --- | --- |
| How | A manager sets **This Device Is For** on the device's page (Devices and Viewers) | Someone chooses a kids viewer on Who is watching |
| `kidsProfileId` | Set on the server | Not set |
| Who enforces the limits | The server, on every request | The app; the server checks only Play On, waking, questions and screen time by the `profileId` the app names |
| Way out | None on the device. Only a manager, from another device | The grown-up gate (below) |
| Servers | Cannot be changed or added | Switching needs the grown-up gate (D-048) |

A bound device is the real limit. Kids mode on a shared device is a convenience: the device
can watch as anyone, so the limits there are kept by the app (D-027).

Details that hold for both:

- **Kids mode is remembered.** The app keeps the kids viewer's id
  (`LocalSettings.kidsModeProfileID`). Opening the app again is kids mode again, and Who is
  watching is never shown in kids mode (D-039).
- **A kids viewer that disappears** (deleted, or no longer a kids viewer) stays a kids viewer with
  nothing to watch on that device: never the picker, never someone else's library
  (`AppModel.restoreViewer`, `kidsProfile`). The server refuses to delete a viewer, or to make it
  an ordinary one, while a device is bound to it (`409`); if the catalogue ends up that way anyway,
  the device gets nothing ([api.md, Kids limits](api.md#kids-limits)).
- **A manager's device cannot be bound to a child** (`409` on `PATCH /v1/devices/{id}`).
- **Binding takes over at once.** The device closes what plays, switches to the child and starts at
  the top. A bound device also deletes downloads the child may no longer see; a shared device keeps
  them, since they may be someone else's (`stopWhatIsNotAllowed`).

### Leaving kids mode: the grown-up gate

On **iPhone, iPad and Mac** the way out is **For Grown-ups**: on the child's picture page (tap the
picture on Home), on the resting, listening and asking pages, and as the picture itself with a
server that knows no avatars. It asks for Face ID, Touch ID or the device passcode
(`GrownUpGate.swift`, `.deviceOwnerAuthentication`: not biometrics alone, so a grown-up whose
face is not on the device can type the passcode).

- **Passed:** Who is watching opens. The child is still the viewer until somebody else is chosen.
  Closing the picker without a choice returns to the kids screens.
- **Cancelled or not recognised:** nothing happens.
- **No passcode on the device:** nobody passes. A sheet says "This device has no passcode" ("This
  Mac has no password") and asks to set one first.
- **Bound device:** after the check a sheet says "This device is for *name*" and that a manager
  changes it from their own device.

On the Mac, the Settings window shows "Settings are for grown-ups" while the kids screens are up.

### The Apple TV and the grown-ups' code

The TV has no Face ID or passcode. A manager chooses a **four-digit code for the household**, on
iPhone, iPad or Mac: Devices and Viewers, **Code for Grown-ups** (`KidsCodeSection.swift`). Each
household has its own; a guest household's manager chooses theirs (D-039, D-052).

On the TV the child's own page has **For Grown-ups**, which opens a keypad (`TVGrownUpGate` in
`tvOS/Views/TVKidsViews.swift`).

- Four digits are checked by the server (`POST /v1/kids/code/check`). Only the server can say yes:
  **offline nobody leaves** ("Lobby Server cannot be reached. Without it nobody can leave the kids
  pages.").
- **Lockout:** five wrong codes from one device in ten minutes lock it out for the rest of the ten
  minutes, also for the right code. The TV says "Too many wrong codes. Try again in *n* min." A
  guess counts before it is checked, so guesses sent at once count too. The count is in memory.
- **No code chosen:** the TV says that a manager chooses one on an iPhone, iPad or Mac.
- **A TV bound to a child** has nothing to type: it says only a manager changes that.
- The server keeps a salted scrypt hash, never the digits.

Contract: [api.md, The code for grown-ups](api.md#the-code-for-grown-ups). Approval on a manager's
phone instead of a code is **not built** (D-039).

## 2. Kids limits: which titles

Kids limits say *which* titles a kids viewer may see (D-027, D-040, D-041). Contract:
[api.md, Kids limits](api.md#kids-limits). The manager sets them on the viewer's page.

| Choice | What it does |
| --- | --- |
| A group, **All of It** (`allowedGroupIds`) | Everything put in that group's categories by hand, also later. Not what a category takes in only by a studio rule. |
| A category (`allowedCategoryIds`) | Everything in it, its categories inside it too, and what its studio rule takes in. |
| A blocked category (`blockedCategoryIds`) | Nothing in it, whatever allows it. Offered once categories have categories inside them. |
| A title, Allow (`allowedItemIds`) | That title; for a series, all of it. |
| A title, Block (`blockedItemIds`) | Never shown. |

Rules:

- **Nothing allowed is nothing shown.**
- **Blocked wins**, over everything, also over a single allowed title.
- A studio rule never widens through a group (D-041): a studio makes films of every kind.
- A title without categories is in the main part, so it comes with that group.
- A file that holds several episodes is there only when all of them may be seen.
- **A block follows the file**: renamed, removed and back, copied. Known again by content, path or
  place in the series. When the server is not sure, it blocks, and the new id is put in
  `blockedItemIds` where a manager can take it out (D-029).
- Popular, search, categories, pictures, subtitles and progress are all cut to the allowed titles
  for a kids device. Search has nothing from beyond the library for a child (D-061). Popular counts
  kids viewers' plays only (D-038). The table in api.md lists each route.

### Chosen at setup

Turning on **Kids Viewer** starts the viewer with every group whose name contains "kid" allowed,
when there is one, and nothing else (`KidsSetup.defaultLimits` in
`Shared/State/KidsPlanEditor.swift`). Music starts with all music libraries (`musicSourceIds` is
null) and music on. A manager narrows both from there.

### Fail closed when categories change

Rearranging categories can quietly widen what a child sees: move a studio into Kids, take a
category out of a blocked parent. So the server refuses such a change until a manager confirms it
(D-040; [api.md, Kids viewers](api.md#kids-viewers)).

- It applies to changes that touch categories inside others or blocked categories, and that would
  let any kids viewer see something new. Taking something away never asks.
- The apps always send a **dry run** first (`CategoriesModel.askingFirst`). When it says
  `needsConfirmation`, a sheet **Children Would See More** lists, per child, how many titles would
  appear (the first five by name) and how many would go. **Allow** sends the change again with the
  `kidsToken`; Cancel sends nothing.
- The token names exactly what would appear. If something else would appear by then (a title
  arrived, limits changed), the server refuses again with a new token and the sheet comes back.
- Merging categories always asks (D-049).
- A title's own categories and the limits themselves are explicit choices and do not ask.
- Kids viewers of guest households are not among those the owner's managers are asked about
  (D-052).

## 3. Kids control: when and what

Kids control says *when* a kids viewer may watch and *what kind*: films, only listening, or
nothing. It never lets a child see a title its limits do not allow. The design is
[kids-control.md](kids-control.md), the decision D-062, the contract
[api.md, Kids control](api.md#kids-control). What follows is the short version, with what the apps
do.

A viewer without a plan is **Everything**, with music.

### Modes

In the order of strictness, strictest first: **Nothing**, **Only listening**, **Ask first**,
**Everything** ([kids-control.md §1](kids-control.md#1-modes)).

| Mode | iPhone, iPad, Mac | Apple TV |
| --- | --- | --- |
| Everything | The kids screens | The kids screens |
| Ask per title | The kids screens; a film's Play is **Ask to Watch** | The kids screens with Play; the server refuses the film (`403 kids_mode`). Ask to watch on the TV is **not built** |
| Only listening | "Time to listen": Stories and Music, nothing to watch | The child's page and Stories: "Time to listen", stories and music. Without music for the child: "Films and series come back later." |
| Ask to open | Only the asking page: "Asking Mum and Dad…", with Try again after No or no answer | The same words, without Try again: after No or no answer the TV keeps saying so until the mode changes (`TVKidsControlPage`). Try again on the TV is **not built** |
| Nothing | "Lobby is resting" and when it opens again | The same |

On the TV the child's own page (picture, Change Picture, For Grown-ups) stays in every mode.

### Where the mode comes from

The **schedule** (weekly blocks and a default), the **away rule**, **places**, **screen time**,
a grown-up's **override**, and **answers** to Ask first. How they combine is in
[kids-control.md §2](kids-control.md#2-where-the-current-mode-comes-from); the precedence:

| Order | Source | Wins when |
| --- | --- | --- |
| 1 | Override | Always, while it runs. It can itself be any mode, Ask first too |
| 2 | The strictest of: schedule block (strictest of overlapping ones) or default, away rule when away, the place's mode or the "location unknown" mode, screen time when used up | No override runs |
| 3 | Answer | Only where step 2 says Ask first. Never past a stricter mode: "Watch for 2 hours" at 19:00 ends when Bedtime begins |

Only listening plus Ask first is Only listening, without asking.

### What grown-ups set

On iPhone, iPad and Mac, the viewer's page → **When and What** (`KidsPlanPage.swift`):

- **Now:** the mode and until when ("Now: Only listening until 19:30"), override menus for
  Nothing, Only listening, Everything and Ask first, each until the next switch, 30 minutes, 1 hour
  or 2 hours; **End It Now** while an override runs; **Switch to Watch**, **Switch to Listen** and
  **End the Answer** while an answer runs. "Until a time" is in the API (`until`) but not offered
  in the apps: **not built**.
- **The Week:** a default mode and blocks per weekday. Presets **School Days** (Monday to Friday
  08:00–15:00, Nothing, label "School") and **Bedtime** (every day 19:30–07:00, Only listening).
  Blocks that overlap: the stricter holds. Times are the household's time zone
  (`household.time_zone`, the server's when unset). The apps have no screen for the household's
  time zone (`PUT /v1/household/time-zone` is built on the server): **not built** in the apps.
- **Ask First:** Ask to open or Ask per title, and who is asked (below).
- **Screen Time:** off, or minutes on school days and at weekends (in steps of 15 up to 600 in the
  app; the server takes 0 to 1440), and Only listening or Nothing afterwards. Counts only films and
  series.
- **Away from home:** "As the week says", or Ask first, Only listening or Nothing. Away is
  anywhere but the home network: the outside entrance, the direct road and the tailnet. It needs
  no location.
- **Music:** on or off, and which music libraries (section 4).
- **Places:** up to ten, each a name, a mode and a circle of 100 m to 10 km drawn on a map or found
  by address, and the mode for "where it cannot tell" (by default the strictest place's).

On Devices and Viewers each kids viewer has a glance under its name: "Now: Nothing until 15:00"
(`GET /v1/kids/now`, the strictest of the child's own devices).

### Ask to open, Ask per title, and answers

- **Ask to open:** when the screens are asking, the app sends the question by itself
  (`askIfNeeded`). The page shows the child's picture, "Asking Dad…" or "Asking Mum and Dad…"
  (the names of who is asked; "Asking a grown-up…" without names), and a spinner. Then: it opens;
  "Not now — Maybe later!"; "No answer yet" after ten minutes; each with **Try again**, which waits
  while the server says too many were asked. Offline: "Lobby needs the internet to ask".
- **Ask per title:** **Ask to Watch** on the title page, then "Asked — waiting…". When a grown-up
  says yes, the film starts by itself while the child is still on that page.
- **One question at a time** per child, ten minutes, at most six an hour (`429`).
- **The grown-ups' side:** on iPhone, iPad and Mac a sheet with the child's picture, "*Name* wants
  to open Lobby" or "*Name* wants to watch *title*", and **Watch**, **Listen** (Ask to open only)
  and **No** / **Not now**. One tap is the usual length: until the plan's next switch when that is
  today, else an hour. **For…** offers until the next switch, 30 minutes, 1 hour, 2 hours
  (`KidsAskSheet.swift`). The Apple TV is never asked.
- **The first answer counts.** On every other grown-up's device the sheet closes and a line says
  "Answered by Mum — Watch for 1 h" for six seconds. Switching or ending an answer is on When and
  What, not on the sheet.
- **Who is asked:** by default every admin device of the child's household, named by all its
  grown-up viewers; or chosen grown-ups with chosen devices (`askers`).

### Push

A question reaches the grown-ups' iPhones, iPads and Macs as a notification with **Watch**,
**Listen** and **No**, which answer without opening the app, with the usual length. The server
sends it through APNs when the config names the team's key
([operations.md, Push notifications](operations.md#push-notifications);
[api.md, Push notifications](api.md#push-notifications--built)). Without a key nothing is pushed;
an app in the background still shows a notice of its own for a question its live channel brings.
A lock-screen answer is sent only when the server the question came from is the one in use on that
device (`PushCenter.swift`). A kids device gets no pushes (`PUT /v1/me/push` is not there for it).

### Offline

A child's device keeps a **signed copy of the plan** (Ed25519, key pinned the first time), valid
for seven days, fetched each time the app reaches the server ([kids-control.md
§6](kids-control.md#6-offline), `KidsPlanCache` in LobbyKit). In kids mode the app looks again
about once a minute. Offline:

- The time is the server's time at the last sync plus the device's monotonic clock; after a
  restart the device clock, never earlier than the latest trusted time; if the two disagree by more
  than two minutes, the stricter mode of both holds.
- An expired copy holds the strictest mode it names anywhere. **No copy is Nothing**, also for
  kids mode on a grown-up's device.
- Offline is not away: the away rule does not apply.
- Ask to open offline shows "Lobby needs the internet to ask"; an answer that still runs holds.
- **Screen time counted on the device while offline is not built in the apps.** The server takes
  `POST /v1/me/kids/screen-time` and keeps the larger count, and LobbyKit has the call and a
  counter (`reportKidsScreenTime`, `KidsPlanCache.addVideo`), but nothing in the app calls them.
  Offline, the copy's screen time stays what it was at the last sync.

### Enforcement and switches

- On the server every route a bound kids device can use has a need in `KIDS_MODE_ROUTES`
  (`src/kids/guard.ts`); a route without one is refused, and a test fails until it has one. A
  refusal is `403 kids_mode` with the current mode, so the app shows the right page and keeps its
  downloads. What is being sent stops within a second of a switch.
- The live channel tells the child's devices, and a TV playing as the child, at once
  (`kidsMode`). The app ends a film the new mode does not allow. On iPhone, iPad and Mac the kids
  screens then say "Time for something else. The film waits for you, right where you stopped." The
  place is kept. On the TV the film ends without that message.
- Music that plays stops when the mode allows no listening.
- In the last five minutes before a stricter mode, the kids screens on iPhone, iPad and Mac show a
  small line at the top: "Listening time in 4 minutes" or "Lobby rests in 4 minutes". On the TV:
  **not built**.
- "Today's plan" in kid words on the child's own page ([kids-control.md
  §3](kids-control.md#3-what-the-child-sees)): **not built**.

## 4. Kids music and stories

Music for a kids viewer is **on unless a grown-up turns it off** (D-062, which replaced D-027 and
D-044's "no music for kids"). It plays wherever the mode allows listening, from the music libraries
chosen for the child (all by default). Off, music is `404` for a kids device as before. The
household's audiobooks are **Stories** in the apps (D-067).

- **Where a child finds them.** While the mode allows listening, the kids bar has **Stories**
  (headphones) after Home, on iPhone, iPad and Mac, and a **Stories** place in the TV's sidebar. In
  **Only listening** that page is all the kids screens are: "Time to listen", with the way out for
  grown-ups at its foot; on the TV the child's own page and Stories. Kids Home shows **Keep
  listening** too. "There is nothing to listen to yet." when there is nothing.
- **The page:** Keep listening (the stories begun, a tap goes on at once), the stories as big
  covers with their names and how far the child is, then Music, whose albums play at once
  (`KidsStoriesViews.swift`, `tvOS/Views/TVStoriesViews.swift`).
- **A story's page:** the cover large, the title, who reads it and how long it is, how much is
  left, one **Play**, **Resume** or **Play again**, **Say it**, and **Watch the film** when the
  library has a film of the same name that the child may see and the screens show films now. A
  film's page has **Listen to the story** the other way, while the child may listen.
- **The player** opens over everything when something starts: the cover, the title, "Read by …", a
  thick bar of how far, back 15 seconds, a big play and pause, forward 30 seconds (previous and
  next for music), and the moon: stop **when the story ends**, **in 15 minutes**, **in 30 minutes**,
  or **keep playing**. No scrubber, speed or queue to touch by mistake. While something plays, a
  bar over the kids tabs shows it, with play and pause.
- **The child's own place in each story** is kept, as a grown-up's is (`/v1/music/profiles/{id}/
  progress` of the child's own viewer), so it resumes on every device.
- `musicSourceIds` is checked when a song plays; the listing itself is the household's.
- A guest household with a part of the library has no music at all, kids included (D-052): no part
  of the library says what music is in it.
- Limits per album, story or artist: **not built** (a card of its own).

## 5. Play On and waking a TV

A child may play on an Apple TV, as itself (D-054; [api.md, Who may](api.md#who-may)).

- On a kids title page on iPhone, iPad or Mac, **Play on TV** is there while an Apple TV can play
  it and the mode allows video. One TV is one tap; several are large cards with each TV's name
  ("Which TV?"). The kids player has a button to send what plays to the TV.
- Only **Apple TVs** with Lobby open are offered, not one that belongs to another child. With
  `allowRemote` off, none. A TV the server can wake is offered **at home only** (`RemoteTargets`,
  tested in `KidsPlayOnTests.swift`).
- The TV then plays as the child: it switches to that viewer, which on the TV is kids mode, left
  only with the code.
- The child controls only what plays as itself: pause, back a little, stop. A grown-up's film on
  the same TV is not the child's to touch.
- **Waking a TV:** only when the household turned on **Kids can turn on the TV**
  (`remote.wake.kids`, off by default, on the Apple TVs page). Otherwise `404 not_wakeable`. When
  the TV shows tvOS's profile picker, the child reads "If *TV* asks who is watching, ask a grown-up
  to choose." ([api.md, Waking an Apple TV](api.md#waking-an-apple-tv), D-046, D-056.)
- Play On and waking need **Everything** (or an answer that gives it), checked by the server on the
  target and on the child's own device. At a switch the TV is told as the child's device is.
- Waking another household's Apple TV: **not built** (D-052).

## 6. Up next, still watching, subtitles and skipping

A kids viewer's preferences are **the grown-ups'** (D-058, D-059;
[playback.md, When something ends](playback.md#when-something-ends)).

- **Defaults** (`PlaybackPreferences.kidsDefaults`): as everyone's (a film ends on suggestions and
  starts nothing; the next episode starts after 10 seconds), but **"Still watching?" after the
  second title in a row** without a touch instead of the third.
- A manager changes them on the viewer's page (Playback). The child's device gets `404` for
  `PUT /v1/profiles/{id}/playback`.
- **Kids control goes first.** A next episode or suggestion the mode does not allow now is not
  offered and never starts by itself, also when the mode changes during the countdown
  (`PlayerModel.kidsAllow`).
- **Skip Intro and Next Episode:** the same choices as everyone's, set by a grown-up on the
  viewer's page; a kids device gets `404` for `PUT /v1/profiles/{id}/skipping`.
- **Subtitles** (D-057): kids viewers start with everyone's default, off with forced subtitles on.
  The kids player has no subtitle menu; the preferences choose. The server lets a child's own device
  set its own subtitles, and a manager set them when making or changing the viewer, but **no screen
  in the apps changes a kids viewer's subtitles: not built**.

## 7. Statistics for kids

From D-060 and D-066 ([api.md, Statistics](api.md#statistics)):

- Children see no statistics, their own included. The kids screens have no statistics entry, and
  the server answers `404` to every statistics route from a child's own device and `403` to a
  grown-up's device while a child is in front on it.
- The household's admins (and the server admins) see a child on the viewer's page: **What *name*
  Watches**, with screen time per day (watching and listening) and how much is in the evening and
  at weekends. Other grown-ups of the household do not see a child's statistics.
- One sitting can be taken out of a child's history by whoever may see it. Forgetting a viewer's
  history is a household admin's.

## 8. Households and who decides

From D-052 and D-053 ([api.md, Households](api.md#households)):

- Every kids viewer is of one household. A guest household's admins make and manage their own kids
  viewers, limits, plans and code.
- A guest household that sees only part of the library: its child sees what both the household's
  part and the child's limits allow. Nothing allowed is nothing.
- **Who decides** a child's plan, overrides and answers: the household admins of the child's
  household, and the server admins, also for a guest household's child. Never another guest
  household, never a viewer's device (it may read the plan only: `403`), never the child's own
  device (`404`).
- From outside, answering, overriding and ending are open to those who may decide. Changing the
  plan is done at home or on the tailnet for the owner's household, anywhere for a guest household.
- Play On and waking stay inside the household.

## 9. The kids icon and the kids look

### The kids icon

While the device is in kids mode, Lobby shows a second icon: the **sparkle door**, the same door
with sparkles in a yellow doorway. Its source is `apps/apple/Brand/portal-kids.png` (all rights reserved, see `assets/LICENSE-ART`).
`apps/apple/Scripts/make-icons.py` draws every form of it (it needs `rsvg-convert` and Pillow):

| Where | Asset | What it is |
| --- | --- | --- |
| iPhone, iPad | `iOS/Assets.xcassets/AppIcon-Kids.appiconset` | An alternate app icon, with the light, dark (the door lifted off the dark sky) and tinted looks |
| Apple TV | `tvOS/Assets.xcassets/AppIcon-Kids-TV.imagestack` | An alternate app icon of two layers, the sky behind and the door in front, so it moves under the remote. tvOS finds an alternate as an image stack of the home screen's size, not as a brand asset; the top shelf picture stays the primary's |
| Mac | `macOS/KidsIcon.xcassets/KidsDockIcon` | A Dock picture in the Mac icon's shape |
| Inside the app | `Shared/Brand.xcassets/KidsDoor` | The door mark on the kids screens (below) |

`project.yml` names the alternates (`ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`). The tvOS one
has a name of its own because the tvOS app carries the iPhone catalog too.

How it changes (`apps/apple/Shared/Services/KidsIcon.swift`):

- **Wanted:** the kids icon when the device is in kids mode (bound to a kids viewer, or a kids
  viewer chosen) and the setting is on; the primary otherwise. It follows the server in use
  (`ServersRoot.swift`).
- **Only when it differs.** Nothing is asked of the system when the icon shown is already the one
  wanted.
- **It waits for 20 seconds** of settled kids mode, or settled grown-up mode, **with the app in
  front and no film playing**. iPhone, iPad and Apple TV show a system alert each time the icon
  changes. So a grown-up who looks at something for a moment and hands the device back sees no
  alert, and neither does a launch that passes through "nobody chosen yet". Going to the
  background, or a film starting, stops the wait; the next change starts it again. The same wish
  keeps its place in the wait.
- **The Mac has no alternate icons.** It sets the Dock picture while the app runs, at once (no
  wait, whether the app is in front or not), but not while a film plays. When kids mode ends the
  bundle's own icon comes back. The icon in Finder never changes.
- A device that cannot show alternate icons changes nothing. A failed change is logged and tried
  again at the next change of kids mode.
- Tested in `apps/apple/Tests/KidsIconTests.swift` (the rules of the switcher, with a fake
  surface). The builds list the alternates in `CFBundleAlternateIcons`; the system's alert and the
  icons on the Home Screen can only be seen on a device.

The setting is **Kids Icon in Kids Mode**, on by default, one per device whatever the server
(`lobby.kidsIconInKidsMode` in the app's own defaults). On iPhone, iPad and Mac it is under
**Settings → This Device**; the kids screens do not reach Settings. On the Apple TV it is on the
viewer page, and hidden in kids mode. Turned off, the primary icon stays, or comes back after the
same wait.

There is no decision record for the kids icon yet.

### The door mark

`KidsDoorMark` (`Shared/Views/Components/KidsDoorMark.swift`) is the sparkle door as a small
rounded picture. It is decoration only: VoiceOver passes over it. It stands where a page says
"this is the kids' side":

- the kids **Home**, at the right of the child's name (40 pt);
- the **resting, asking and listening pages**: over the corner of the child's picture on resting
  and asking (iPhone, iPad, Mac and Apple TV), beside "Time to listen" on the listening page;
- the kids pages' **empty** ("Nothing here right now", "Nothing is on here yet") and **loading**
  states on iPhone, iPad and Mac, in place of the place's symbol; on the Apple TV the loading state
  only;
- **kids viewers on Who is watching**, on the corner of their picture (iPhone, iPad, Mac and Apple
  TV);
- the **Kids Mode** section header in Settings (the Trailers in Kids Mode switch).

### The kids look

The kids screens are the regular app, simpler, larger and richer in colour (`KidsRootView.swift`,
`TVKidsRootView`):

- **The places** on iPhone, iPad and Mac: **Home**, **Movies**, **Series** and **On here** (what is
  on the device), in a large bar of dark glass at the bottom, and **Stories** after Home while the
  child may listen (section 4). On the Apple TV the same sidebar as the regular app with the
  child's page, Home, Stories, Movies and Series. No search, no settings, no way to other screens.
- Always **dark**. Pages take their colours from the pictures on them (`ArtworkColors.Style.kids`),
  brighter than the regular app's (D-031). Where there is no picture: a purple gradient,
  `KidsTheme.page`, deeper with Increase Contrast.
- `KidsTheme` (`Shared/Support/AppTheme.swift`) holds the rest: each place's colour on the bar
  (Home orange, Stories yellow, Movies lilac, Series blue, On here green), white words, rounder corners (posters 16,
  cards 20, the bar 30), and a soft shadow on every picture. Words straight on a kids page are large
  and heavy, never under 19 points bold, so those pages are held to 3:1 contrast (D-031).
- A title page: the picture from edge to edge, one **Play** (or **Resume**), a **Say it** button that
  reads the title out loud for a child who does not read yet (`TitleSpeaker.swift`, heard with the
  silent switch on too), Play on TV, episodes as large pictures, and Related.
- The child may change its own picture: tapping it on Home opens the pictures, with For Grown-ups
  on that page (D-037).
- **Trailers in Kids Mode** (Settings, per server on this device, on by default) controls trailers
  for a kids viewer. The kids title pages have no trailer button, so in the kids screens it changes
  nothing yet: **not built** on the kids pages.

## 10. Privacy for kids

- **Away from home needs no location.** The server knows the road a request came by. Home is the
  home network.
- **Places are watched only on the child's device** (`KidsPlaceWatcher.swift`), with the system's
  region monitoring (`CLMonitor`), no continuous tracking. iPhone and iPad need "While Using"; on
  the Mac the app counts only `authorizedAlways` as allowed. The permission text says: "Lobby checks only whether this device is at a
  place a grown-up chose, such as school. It never sends where it is."
- **What is sent:** only "inside place X" (the strictest place it is in), "inside no place" or
  "cannot tell". `PUT /v1/me/kids/place` refuses any other field, coordinates above all (`400`).
  Until every place has answered, "inside none" is not said: it is "cannot tell".
- **What the server keeps:** the last state per device, in memory, counted as fresh for six hours.
  Nothing of where the child was. After a restart every device is "cannot tell" until it reports
  again.
- **What is stored:** each place's centre and radius as a grown-up chose them, on the server and
  sent to the child's device to watch. That is a place the grown-ups named, not the child's location.
  Finding a place by address asks Apple Maps from the grown-up's device.
- **Fail closed:** permission denied, off, restricted or not answered yet, Location off, or nothing
  heard for six hours: "cannot tell", and the "location unknown" mode applies (by default the
  strictest place's).
- **The Apple TV** stays in the house: it always reports "inside no place".
- The When and What page says: "Lobby on *name*'s device checks only whether it is inside these
  places. It never sends where it is, and keeps no history."
- Everything else about a child (what it watched, its questions, its screen time) is the
  household's, as for any viewer. The server owner sees a guest household's devices and access log,
  not what it watches (D-052).

## 11. Troubleshooting

| What happens | Why, and what to do |
| --- | --- |
| A child's device shows nothing | Nothing is allowed, or the device is bound to a viewer that is gone or no longer a kids viewer. Open the viewer's page and allow something, or bind the device to the right viewer. |
| A title is missing for the child | It is not allowed, it is blocked (a block wins), it came back as a new file the server was not sure about (look in the blocked titles), or it is in a category only by a studio rule and only the group is allowed. |
| "Lobby is resting" when it should not be | Read the first line of When and What: it says the mode and why. A place rule with Location off, or a device that said nothing for six hours, is "cannot tell" and takes the strictest place's mode. After a server restart, places are "cannot tell" until the app reports again. |
| Resting offline | No signed copy yet, or it is more than seven days old: open the app once where it reaches the server. |
| Grown-ups get no question | The child must be in Ask first (Only listening beats it, without asking). Push needs the team's key in the config (`GET /v1/settings/push` says whether it is there). Check who is asked under Ask First. The TV is never asked. |
| "No answer yet" and Try again does nothing | Six questions an hour at most; Try again waits until the server allows the next. |
| A lock-screen answer did nothing | It is sent only to the server in use on that device. Answer in the app, or switch to that server. |
| A grown-up cannot leave kids mode on iPhone, iPad or Mac | The device needs a passcode. A bound device cannot be left at all: change it from a manager's device. |
| The TV does not take the code | No code is chosen yet (Code for Grown-ups), five wrong codes locked it for ten minutes, or the server is out of reach. A TV bound to a child has no way out. |
| A category change keeps asking | Something else would now appear for a child; the sheet shows what. Allow again. |
| No Play on TV | The mode must allow video, the device needs `allowRemote`, and an Apple TV must have Lobby open. A sleeping TV is offered only at home and only with Kids can turn on the TV. |
| No music or stories for the child | Music is off in the plan, its libraries are not chosen, the household sees only a part of the library, or the mode allows no listening now (Nothing, Ask to open). |
| No Watch the film on a story | The film's title is not the story's, the child may not see that film, or the mode shows no films now (Only listening). |
| The kids icon did not change | The setting is off; or it waits for 20 seconds with the app in front and no film playing. The system's alert when it changes is expected. On a Mac only the Dock changes, while the app runs. |

## Where it lives

- Server: `apps/server/src/kids/` (`limits.ts` kids limits, `guard.ts` both route tables,
  `plan.ts` and `blocks.ts` the plan, `control.ts` questions, answers, screen time, places and the
  signed copy, `code.ts` the grown-ups' code, `routes.ts`), with `kids.test.ts`,
  `kids-plan.test.ts` and `kids-control.test.ts`.
- LobbyKit: `Kids/KidsPlanCache.swift` and `Kids/KidsPlanResolver.swift` (offline),
  `Client/KidsControlClient.swift`.
- Apps: `Shared/State/AppModel.swift` (MARK: Kids mode), `AppModel+Stories.swift`, `Shared/State/Kids*.swift`,
  `Shared/Views/Kids/`, `Shared/Views/Manage/KidsPlanPage.swift`,
  `Shared/Views/KidsQuestions/KidsAskSheet.swift`, `Shared/Services/GrownUpGate.swift`,
  `KidsPlaceWatcher.swift`, `KidsIcon.swift`, `PushCenter.swift`,
  `tvOS/Views/TVKidsViews.swift`, tests `Tests/Kids*Tests.swift`.

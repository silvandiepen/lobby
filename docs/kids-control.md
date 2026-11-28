# Kids control: when and what

A grown-up wants to decide not only *which* titles a child may see, but *when* and *what kind*:
nothing at all during school hours even though the iPad went along, only music and stories at
bedtime, different rules away from home or at a named place, and a mode where the child asks and a
grown-up answers "Watch" or "Listen" from their own phone.

This is one model for all of it. Kids limits (D-027: *which* titles) stay as they are; this adds
*when* and *what kind*. Nothing here ever lets a child see a title its limits do not allow. The
decision record is D-062 in [decisions.md](decisions.md); the contract is in [api.md](api.md),
"Kids control".

## 1. Modes

A kids viewer is always in exactly one of these. Order matters: it is the order of strictness.

| Mode | The child can | Kid words |
| --- | --- | --- |
| **Everything** | Films, series, trailers, music and audiobooks, downloads, Play On | "Watch and listen" |
| **Ask first** | Nothing until a grown-up answers (see the two kinds below) | "Ask Mum or Dad" |
| **Only listening** | Music and audiobooks (soundtracks are music). No video of any kind: no films, no episodes, no trailers, no Play On, no waking a TV | "Time to listen" |
| **Nothing** | Nothing. The app shows "Lobby is resting" and when it opens again | "Lobby is resting" |

**Ask first** has two kinds, chosen per kids viewer:

- **Ask to open** (the main one). When the app opens or comes to the front, nothing of the library
  is shown: straight to "Asking Mum and Dad…" with the child's picture, and the question goes out
  by itself. A grown-up answers **Watch** (Everything), **Listen** (Only listening) or **No**, each
  for a while. That answer is the mode of the whole app until it ends.
- **Ask per title**. The child browses and listens freely; video needs a yes per title. They pick a
  film and tap a big "Ask to watch". A grown-up answers "Yes, this one", "Yes, for an hour" or
  "Not now".

Music needs one more thing: **music and audiobooks on** for this viewer (a switch on the same
page). Until now a kids device had no music at all (D-027, D-044); the switch is what opens it.
With it off, Everything means films and series only, and Only listening means nothing to listen
to (the page says so). A guest household that sees only a part of the library still gets no music
(D-052): no part of the library says what music is in it.

## 2. Where the current mode comes from

Six sources. Each one either says nothing right now or names a mode.

| Source | Says something when | It says |
| --- | --- | --- |
| **Schedule** | always | the mode of the time block the moment is in, or the viewer's default mode when none |
| **Away rule** | the device is not on the home network | the away mode (e.g. Only listening) |
| **Place rule** | the kid's device says it is inside a named place that has a mode (not "As schedule"), or cannot say and a grown-up chose what holds then | the place's mode; when it cannot say, the chosen mode or the strictest place's (D-069) |
| **Screen time** | today's video minutes are used up | Only listening or Nothing (chosen) |
| **Override** | a grown-up set one and it has not ended | its mode, and it beats everything else |
| **Answer** (grant) | a grown-up answered Ask first, and it has not ended | what was answered, but only where Ask first is the mode |

### How they combine

1. **An override wins.** While a grown-up's "Nothing until 15:00" or "Everything until bedtime"
   runs, it is the mode, whatever the schedule, place, away rule or screen time say. It is the
   explicit choice of a grown-up who is there; everything else is a rule set in advance. An
   override can itself be Ask first.
2. **Otherwise the strictest source wins**, in the order of the table in §1:
   Nothing > Only listening > Ask first > Everything.
3. **Ask first is only lifted by an answer, and an answer never goes past the others.** When the
   result of step 2 is Ask first, the latest answer decides. When it is stricter (Only listening,
   Nothing), an answer does not lift it: "Watch for an hour" given at 19:30 ends at 20:00 when the
   Bedtime block makes it Only listening.
4. **Only listening and Ask first together is Only listening, without asking.** Step 2 already says
   so. Listening needs no question: a child under a "listen only" rule who would have to ask to
   listen is a stricter rule than either one alone, and nobody set that.

A schedule's own blocks can overlap; the strictest block wins there too.

### Examples

Robin: default Everything; Mon–Fri 08:30–15:30 Nothing ("School days"); every day 20:00–07:00 Only
listening ("Bedtime"); away from home: Ask to open; place "School": Nothing; screen time 60 minutes
on weekdays, then Only listening; music on.

| Moment | Sources that speak | Mode |
| --- | --- | --- |
| Tue 10:00 at school | schedule Nothing, place Nothing, away Ask | **Nothing**, "At school — Lobby is resting until 15:30" |
| Tue 16:00 home, 20 min watched | schedule Everything | **Everything** |
| Tue 17:30 home, 60 min watched | screen time Only listening | **Only listening** until tomorrow 07:00 (then the schedule says Everything; screen time starts again at midnight but bedtime is on until 07:00) |
| Tue 16:00 at Grandma's (not a place) | away Ask | **Ask to open**: "Asking Mum and Dad…" |
| … Mum answers Watch for 1 hour at 16:05 | away Ask, answer Watch until 17:05 | **Everything** until 17:05, then asks again |
| … Mum answers Watch at 19:30 for 2 hours | schedule Only listening from 20:00 | **Everything** until 20:00, then **Only listening** |
| Sat 10:00, Dad sets "Nothing until 12:00" | override | **Nothing** until 12:00 |
| Tue 10:00, Mum sets "Everything for 1 hour" (sick day) | override beats school | **Everything** until 11:00 |
| Tue 10:00 at school, Location off | place unknown, nothing chosen → schedule School Nothing | **Nothing** |
| Sat 10:00, Location off, places School (Nothing) and Home (As schedule) | place unknown, nothing chosen → schedule Everything | **Everything** |
| Sat 10:00, Location off, "Where it cannot tell": The strictest place | place unknown → strictest place School Nothing | **Nothing** |

## 3. What the child sees

- **Everything**: the kids screens as today. In the last five minutes before a switch a small,
  calm countdown sits on top: "Listening time in 4 minutes". No flashing, no sound.
- **Only listening**: the kids home shows music and audiobooks only (Albums, Stories, the child's
  favourites), in the same kids look. A film that was playing ends (see §8). No Play On button.
- **Nothing**: a full screen "Lobby is resting" with the child's picture and when it opens again
  in kid words ("Back at 3 o'clock", "Back tomorrow morning"). With a place rule: "At school —
  Lobby is resting". With a screen-time end: "That was all the watching for today". Nothing else
  is on the screen; no browsing, no playback, no Play On. Music that plays stops.
- **Ask to open**: no library at all: "Asking Mum and Dad…" with the child's picture, sent at
  once. Then one of: it opens (answer Watch or Listen, with "Watch until 5 o'clock" said once);
  "Not now" with a gentle line ("Mum says not now. Maybe later!"); after ten minutes without an
  answer "No answer yet — try again later" with a Try again button, which is rate-limited.
  When an answer ends, it asks again by itself.
- **Ask per title**: browsing and listening as usual; a film's Play is "Ask to watch". Then
  "Asked Mum and Dad — waiting…", and it plays by itself when the answer is yes.
- **Today's plan**, on the child's own page, in kid words: "Now: watch and listen. At 7:30
  listening time. Tomorrow school, Lobby rests until 3."

## 4. What grown-ups see and do

On iPhone, iPad and Mac, per kids viewer, a page **When and what** (beside the kids limits):

- **Now**: the current mode in one line and why ("Only listening until 19:30 — Bedtime"), with
  override buttons: "Nothing until…", "Only listening for…", "Everything until…" (30 min, 1 h,
  2 h, until the next switch, until a time), and "End" while one runs.
- **Week**: a grid of the seven days with coloured blocks per mode; tap to add or change one.
  Presets: **School days** (Mon–Fri 08:00–15:00 Nothing) and **Bedtime** (every day 19:30–07:00
  Only listening). A default mode for the rest.
- **Ask first**: Ask to open or Ask per title; who is asked (everyone who may decide, or chosen
  grown-ups' devices).
- **Screen time**: off, or minutes on weekdays and on weekends, and what happens after (Only
  listening or Nothing). Today's minutes so far.
- **Away from home**: off, or a mode.
- **Places**: a list; add one on a map (centre and radius, 100 m to 10 km) with a name and a mode
  (or As schedule, which changes nothing), and "Where it cannot tell": As schedule (the default),
  The strictest place, or a mode. With the privacy line from §7.
- **Music and audiobooks**: on or off.

On the viewer list, a glance per kids viewer: "Now: Only listening until 19:30".

**Answering a question.** In the app, at once, over the live channel: a sheet with the title's
picture (Ask per title) or the child's (Ask to open), "Robin wants to open Lobby", and three big
buttons **Watch**, **Listen**, **No**. Each Watch/Listen uses its default length with one tap (1
hour); a small "for…" next to it offers 30 min, 1 h, 2 h, until the next switch, until a time.
Per title: "Yes, this one", "Yes, for 1 hour", "Not now". When the app is in the background, a
local notification with the same three actions on the lock screen (an `UNNotificationCategory`).
While an answer runs, the grown-up can end it or switch Watch ↔ Listen from the same sheet or the
viewer's page. The first answer counts; the others' sheets close with "Mum answered: Watch".

**Push.** Through Apple's push service with the publisher's key (one key serves all of a team's
apps): a question reaches the grown-ups' phones, iPads and Macs as a notification with Watch,
Listen and No on the lock screen, which answer without opening the app (until the next switch, as
one tap in the app does). A pairing request tells the household's admins too. Every Lobby
Server sends through the push relay, which holds the key (D-064, outside.md "The push relay"):
what it says is sealed for each device, the relay passes on "A request is waiting", and the
iPhone and iPad app shows the real text. A server with a key of its own sends directly (the config
names the file, operations.md); with neither, only the app tells. Answers always go from the app to
the server, never through the relay.

## 5. Who decides

Who may set the plan, override and answer: the **household admins of the child's household**,
and for a child of the owner's household also the **server admins** (who are only in the owner's
household, D-053). A server admin may also decide for a guest household's child.

"Who gets asked" is optional per child: grown-up viewers with their devices (`askers`); empty means
every admin device of the household, named by all its grown-up viewers. The child's screen names
them ("Asking Mum and Dad…"). Answering and stepping in work from outside too; changing the plan
is done at home, or anywhere for a guest household, as its other managing (D-052).

## 6. Offline

Downloaded films on a child's iPad follow the same plan without the server:

- The device keeps a **copy of the plan signed by the server** (Ed25519; the key is pinned on the
  device the first time it is seen, beside the credential). It holds the plan, an override and
  answers that run, today's screen time, the household's time zone, and the server time at issue.
  It is valid for **7 days**; the device fetches a new one whenever it is online (every 15 minutes
  while the app runs, and on every change, which the live channel announces).
- **The clock comes from the server**, not the device: at each sync the device notes the server's
  time and its own monotonic clock (which a person cannot set). Offline, now = that server time +
  the monotonic time since. After a restart the monotonic clock is gone: then now is the device
  clock, but never earlier than the latest time it trusted. If the device clock and the monotonic
  estimate disagree by more than two minutes, the mode is worked out for both and the **stricter**
  one holds. Turning the clock back or forward never opens anything.
- **When the copy has expired**, or no copy is there: the strictest mode the copy names anywhere
  (its default, blocks, rules, screen-time end). Without any copy, a bound device is **Nothing**
  offline. Kids mode on a grown-up's device without a copy is Nothing as well.
- **Away rule offline**: it does not apply. Offline the copy holds as it is: the last setting, or whatever
  the schedule says for that time.
- **Ask first offline** cannot be answered: Ask to open is Nothing until the server is back
  ("Lobby needs the internet to ask Mum and Dad"); an answer that is still running holds until
  it ends.
- **Screen time offline** is counted on the device and sent when it is back; the server keeps the
  larger of its own count and the device's.

## 7. Places and privacy

- **At home or away** needs no location: the server knows the road. Home is the home network.
  Away is the outside entrance, the direct road, and the tailnet (a child on Tailscale can be
  anywhere).
- **Named places** are geofences that a grown-up draws on a map for one kids viewer. Only the
  child's device watches them, with the system's location permission ("While Using" is enough;
  region monitoring through `CLMonitor`, no continuous tracking). It tells the server **only**
  "inside place X", "inside no place" or "cannot tell" — never coordinates. The server keeps only
  the current state per device, in memory, and nothing of where the child was. The page says so:
  "Lobby on Robin's iPad checks only whether it is inside these places. It never sends where it
  is, and keeps no history." The App Store privacy text says the same.
- **Cannot tell**: with place rules and location permission denied, off, restricted or not
  answered yet, the device says "cannot tell". By default the places then do not count and the
  schedule decides; a grown-up can choose a mode or "The strictest place" instead (D-069). A
  device that said nothing for six hours counts as "cannot tell" too.
- The place's own centre and radius are what a grown-up chose; they are stored on the server and
  sent to the child's device to watch. That is a place the grown-ups named, not the child's location.

## 8. Failure and edge cases

| Case | What happens |
| --- | --- |
| No server (offline) | §6: the signed copy, else Nothing. |
| No answer to Ask first | After 10 minutes the question expires: "No answer yet — try again later". One open question per child; at most 6 in an hour; Try again waits until then. |
| Two grown-ups answer differently | The first answer counts; the second is told "Mum answered first: Watch" and can still change it with Switch or End, which is the same as any later change. |
| Kid on two devices | The plan is per child, not per device: an override, answer and screen time are shared. Place and road are per device: each device is judged with its own place and road, the glance shows the stricter. |
| App killed or in the background | Nothing to enforce while it is not running. The server cuts what it sends within a second when the mode no longer allows it (also a film being streamed). A downloaded film plays only in the app, which checks the plan on every start and once a minute while playing. |
| A film is running when a block starts | At the boundary the server tells the device over the live channel, and also cuts the stream; the device ends the film with a gentle message ("Time to listen now — the film waits for you") and keeps its place. Music that plays goes on when the new mode allows listening, and stops otherwise. Five minutes before, the countdown shows. |
| A grant crosses bedtime | It ends at bedtime (§2, rule 3). The answer sheet says so: "Watch until 19:30 (bedtime)". |
| A TV plays as the child | Play On is allowed under Everything only; at a switch the TV is told the same as the child's device and ends the film. Waking a TV for a child: Everything only. |
| Clock changes on the device | §6. |
| Time zone and summer time | The household's time zone (a setting; the server's when not set). A block 19:30–07:00 is local time on both sides of a change; a block that starts in the hour that does not exist starts when that hour ends. |
| Server restarts | Plans, overrides, answers and screen time are in the catalogue. Place states are in memory: until a device reports again, it is "cannot tell" (fail closed); the app reports on every start and every change. |
| Location permission revoked while inside | The device says "cannot tell"; the schedule decides, or the mode chosen for that. |
| A grown-up changes the plan | Every device of the child is told at once; the copy is fetched again. |
| Kids mode on a grown-up's device | The same plan for that child, from the same copy, with that device's road and place. The server enforces what passes through it (Play On, waking, answers, screen time); the rest is the app, as for kids limits on a shared device. A bound device is the real limit, as everywhere (D-027). |

## 9. Questions, answered

These questions are answered; what is built follows the answers.

1. **Ask first and Only listening together.** Only one grown-up answers; once a question is
   answered it shows as answered on the other devices. Built: Only listening wins and needs no asking; the first answer counts, and every
   other grown-up's device shows at once "Answered by Mum — Watch until 19:30".
2. **An override beats a place rule:** yes. "Intervention always overrules set rules."
3. **Offline is not "away".** "It will take the last setting or whatever is set for a specific
   time/schedule": offline the signed copy holds as it is (its schedule, an override or answer
   that still runs); the away rule does not apply.
4. **A guest household's child:** its household's admins **and** the server's admins may answer
   and step in.
5. **Ask to open shows nothing while it waits**, and names who it asks: "Asking Dad…", "Asking Mum
   and Dad…", the viewer names of the grown-ups chosen for that child (by default all grown-up
   viewers of the household).
6. **Length of an answer:** until the next switch of the plan when that is today, else an hour.
   Also 30 minutes, 1 hour, 2 hours, or until a time.
7. **Asking:** one open question at a time, ten minutes, at most six an hour.
8. **Screen time:** video only.
9. **Music is on** for a child unless a grown-up turns it off (on unless turned
   off). Setting up a child includes choosing which libraries it sees (the Kids group chosen
   at first), stored as its kids limits, and which music libraries (all at first).
10. **No signed copy offline:** Nothing.
11. **Push now**, through Apple's push service (§4,
    [operations.md](operations.md#push-notifications)), for questions and for pairing: for every
    server through the push relay (D-064), or directly with a key of one's own.
12. **Places** up to 10 km.
13. **Answering, stepping in and ending from outside:** yes, for the child's household admins and
    the server's admins, through the outside entrance and the direct road. Changing the plan stays
    at home (or the tailnet) for the owner's household, as the rest of its managing.

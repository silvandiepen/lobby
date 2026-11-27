# The App Review demo server

Lobby shows a household's own films from its own Lobby Server, so App Review needs a server to
connect to (App Review Guideline 2.1: a reviewer must be able to use every feature; a demo mode is
not a substitute where the app's content comes from the user's own server). This folder makes one:
a real Lobby Server with a small library of open movies, reachable from anywhere over the direct
connection, with invitations a reviewer types in. Not shipped.

## What is in it

| Film | Year | Category | Licence | Attribution |
| --- | --- | --- | --- | --- |
| Big Buck Bunny | 2008 | Funny Animals (part **Kids**) | CC BY 3.0 | Blender Foundation, www.bigbuckbunny.org |
| Sintel | 2010 | Adventure | CC BY 3.0 | Blender Foundation, durian.blender.org |
| Tears of Steel | 2012 | Science Fiction | CC BY 3.0 | Blender Foundation, mango.blender.org |
| Elephants Dream | 2006 | Strange Worlds | CC BY 2.5 | Orange Open Movie Project, Blender Foundation |

`films.json` has each film's download, poster and licence source. The licences were read on the
projects' own sharing pages (peach, durian, mango.blender.org) and, for Elephants Dream, on
Wikimedia Commons, on 2026-11-27. Films come unchanged from download.blender.org; posters from
Wikimedia Commons under the same licences (Elephants Dream's is a still cut to 2:3). Every film
folder has a `CREDITS.txt`, the library an `ATTRIBUTION.md`. Categories are invented. Matching is
off (no TMDB key): titles, summaries and posters come from `films.json`.

Viewers: **Alex** and **Sam**, and **Mia**, a kids viewer who sees only the Kids part (Big Buck
Bunny). The code for grown-ups, with which the Apple TV leaves kids mode, is **2468**.

## The doorman, and why

Every device that pairs from outside waits for a manager, who compares six digits on both screens
before saying yes (`docs/outside.md`). A reviewer has nobody at the other end, so the demo runs
`doorman.ts`: it holds the demo's only admin credential and approves, within two seconds, any
device that came with one of the invitations `invites.ts` made, as a viewer. It never approves a
request at a manager's window. This turns off the comparison, which is the protection against a
leaked code: right for a server of open movies, wrong for any household's.

Invitations work once each and for at most 336 hours (14 days, `inviteHours` in `api.md`).
`invites.ts` makes six (iPhone, iPad, Mac, Apple TV, two spare), takes back the set before, and
writes the block for the review notes. **Run it before every submission.** A code valid for 30
days would need the server's cap raised (`MAX_INVITE_HOURS` in `apps/server/src/households/invites.ts`); that
is a decision for the owner, not made here.

## Where it runs

On the owner's VPS, as the user `hermes`, in `~/lobby-demo`:

```
~/lobby-demo/
  server/        Lobby Server 0.1.0 (release archive, linux-x64, with lobby-direct)
  media/         the four films, CREDITS.txt, ATTRIBUTION.md
  state/         doorman.token (0600), posters/, invites.json, notes-block.txt
  tools/         this folder
  doorman.log
```

Services (systemd, user): `lobby-demo.service` (the server, `127.0.0.1:8674` only; Bonjour off)
and `lobby-demo-doorman.service`. No port is opened: the direct connection goes out to the
introducer and finds a path with ICE; films never pass through Cloudflare.

The introducer is the household's own, `wss://lobby-introducer.vandipyan.workers.dev`. It lets in
only the boxes in its `BOXES`, so the demo's box id has to be added there (below).

## Setting it up on a Linux computer

Needs systemd with lingering for the user, ffmpeg, unzip, and about 2 GB.

```bash
# On a Mac with the repo: the server archive, with lobby-direct built for linux-x64
tools/release/build-direct.sh linux-x64 direct/linux-x64/lobby-direct   # Docker, or build on the box
node tools/release/build.ts linux-x64 --direct-dir direct --out dist/demo
scp -r dist/demo tools/demo <box>:

# On the box
sh demo/install.sh ~/demo <its public IPv4 address>
~/lobby-demo/server/runtime/bin/node ~/lobby-demo/tools/invites.ts      # then copy state/notes-block.txt
```

Then add the printed box id to the introducer: from `apps/introducer`, copy `wrangler.jsonc` to
`wrangler.local.jsonc`, set `BOXES` to the household's id **and** the demo's, comma-separated,
and `npx wrangler deploy -c wrangler.local.jsonc`. Keep the household's id: without it the
household's own direct connection stops. `GET /v1/outside` on the demo (with the doorman's
credential) says `"introducer": true` once it is signed in.

## Checking it

```bash
ssh <box> 'systemctl --user status lobby-demo lobby-demo-doorman; tail ~/lobby-demo/doorman.log'
ssh <box> 'T=$(cat ~/lobby-demo/state/doorman.token); curl -s -H "Authorization: Bearer $T" http://127.0.0.1:8674/v1/outside'
```

From a device: Pair From Outside, the address without `wss://`, one of the spare codes. The
doorman's log says `let in a <platform> as viewer`. Remove a test device afterwards (Devices and
Viewers in the app on a manager's device, or `~/lobby-demo/server/bin/lobby revoke <id>` on the box).

## Taking it down

```bash
systemctl --user disable --now lobby-demo-doorman lobby-demo
rm ~/.config/systemd/user/lobby-demo.service ~/.config/systemd/user/lobby-demo-doorman.service
systemctl --user daemon-reload
rm -rf ~/lobby-demo
```

And take the demo's id out of the introducer's `BOXES` again (deploy as above, with only the
household's).

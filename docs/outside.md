# Reaching Lobby from outside

For devices that are neither at home nor in the tailnet. Off by default. Built: the entrance on the server, the Pi's end of a relay, and the direct road with its introducer, on the server and in the apps. **The relay has not yet been verified on a Raspberry Pi or against a real relay**; a trial of the direct road has run on one. No port is opened at home in any of it.

## How it fits together

```
device ── a road ──▶ entrance on the Pi ──▶ the app for outside ──▶ library
          direct: QUIC between device and Pi, over a path ICE found
          relay: TLS from device to Pi, through an own VPS that passes bytes on
```

- **The entrance** (`src/outside/entrance.ts`) gets connections, already decrypted on the Pi, with an address that may be missing or somebody else's. It decides who is let in, limits, logs, and hands the rest to an app of its own. It does not know the road.
- **A road** implements `OutsideTransport`: open, close, and hand over connections that carry HTTP/1.1. It says itself whether the address it gives is proven (`addressIsReliable`). The direct road must not say so for a relayed or self-reported candidate.
- **No film traffic goes through Cloudflare, ever.** A service there may carry the messages with which device and Pi find each other, and nothing else. What it carries must be treated as readable and changeable by it: the device verifies the Pi's certificate with something it has from pairing, and the Pi lets nobody in without the device's own key and credential.

The rules for the API are in [api.md](api.md#outside), the choices in [decisions.md](decisions.md) (D-028).

## What it protects against

| Threat | Answer |
| --- | --- |
| Scanning and probing | One empty `404` for everything without a credential. The relay road shows its certificate only to who asks for the right name. The name itself is not a secret: it is in DNS and in certificate transparency logs (a wildcard certificate keeps it out of the latter). |
| A lost or stolen device | Remove it, or take `allowOutside` away: its connections are cut at once, and every second the server checks again. |
| An old credential | Not let in until a manager says so, per device. |
| Guessing | Credentials are 256 random bits, kept as SHA-256. Pairing codes are 80 bits, live ten minutes, work once. Tries are limited per address and in all. |
| Being tricked into approving | Comparison digits, address and name are shown; the digits go back with the approval. A window is for one device. The result is a viewer; only an invitation's device becomes a manager, of the guest household it was for, never of the server (D-052). |
| A manager's device in wrong hands | No action of the server's managers works from outside. A guest household's manager manages that household from outside (it has no home here), and nothing of anyone else's. |
| A device outside that looks at or runs the devices at home | It sees only itself until a manager turns `remoteOutside` on for it, and itself is seen at home no sooner (see [api.md](api.md#playing-on-another-device)). |
| A device that asks for too much | Limits on streams, copies, subtitles, pictures, requests and connections, per device and in all. |
| Slow or silent connections | Deadlines for handshake, head and body; a full door drops the oldest unknown connection for a new one. |
| Web pages | Any request with `Origin` or `Sec-Fetch-Site` is refused; there is no CORS, no cookie is ever set, and the cookie does not work for writing. |
| DNS rebinding, confused hosts | `Host` must be the configured name, once, in an origin-form request. |
| A compromised relay | See below: it can cut, count and lie about addresses. It cannot read, and it cannot get past the Pi's firewall to anything else. |

**Not protected against:** a flood large enough to fill the uplink; who holds a device that is let in watching what it may see (and writing progress for any viewer of its household, as at home); traffic analysis; a flood that makes pairing wait. The relay's owner, and whoever runs DNS for the name, could get a certificate of their own for it: limit issuing with a `CAA` record and watch certificate transparency.

## Setting it up

With the relay road (for the direct road see below):

```json
{
  "outside": {
    "enabled": true,
    "name": "lobby.example.com",
    "tls": {
      "host": "10.9.0.2",
      "port": 8675,
      "relays": ["10.9.0.1"],
      "certFile": "/path/to/fullchain.pem",
      "keyFile": "/path/to/privkey.pem"
    }
  }
}
```

`host` must be one private address of the Pi, that of the tunnel. Every-address, public and link-local addresses stop the server from starting, with the reason. Without `tls` there is no road and nothing listens. The key may not be readable by everybody. The server reads the files again every thirty seconds: a bad renewal keeps the old certificate, an expired one closes the road, and the reason is in the log and in `GET /v1/outside`. While the tunnel's address is not there it tries again every thirty seconds.

Then a manager turns it on (`PATCH /v1/outside`), and lets devices in one by one (`allowOutside`).

## The relay

A VPS with a public address. The Pi opens the WireGuard tunnel; the VPS cannot.

On the Pi:

```ini
[Interface]
Address = 10.9.0.2/32
PrivateKey = <the Pi's key>

[Peer]
PublicKey = <the VPS's key>
Endpoint = <VPS>:51820
AllowedIPs = 10.9.0.1/32
PersistentKeepalive = 25
```

On the VPS the peer is `AllowedIPs = 10.9.0.2/32`, without an `Endpoint`, and forwarding stays off.

**The firewall on the Pi is required, not a precaution.** A server at home that listens on every address (`"host": "0.0.0.0"`) listens on the tunnel too, as do SSH, Plex and Samba. Lobby itself refuses its `relays` there; nothing else does. Only this lets the VPS reach the one port:

```
table inet lobby_outside {
  chain input {
    type filter hook input priority -10; policy accept;
    iifname "wg-lobby" ip saddr 10.9.0.1 ip daddr 10.9.0.2 tcp dport 8675 accept
    iifname "wg-lobby" ct state established,related accept
    iifname "wg-lobby" drop
  }
  chain forward {
    type filter hook forward priority -10; policy accept;
    iifname "wg-lobby" drop
    oifname "wg-lobby" drop
  }
}
```

Docker's published ports go through `forward`, which is why it is there. Check it from the VPS before turning anything on: every port of `10.9.0.2` but 8675 must be silent, and `curl http://10.9.0.2:8674/v1/server` must get nothing.

On the VPS, TCP is passed on by the name in the handshake, next to the sites that are there. With HAProxy on 443:

```
frontend tls
  mode tcp
  bind :443
  tcp-request inspect-delay 5s
  tcp-request content accept if { req.ssl_hello_type 1 }
  use_backend lobby if { req.ssl_sni -i lobby.example.com }
  default_backend sites

backend lobby
  mode tcp
  timeout server 5m
  server pi 10.9.0.2:8675 send-proxy-v2

backend sites
  mode tcp
  server local 127.0.0.1:8443
```

The existing web server moves to `127.0.0.1:8443`. Do not add `check`: a health check is not a visitor's connection, and is dropped. With nginx `ssl_preread on` does the same; its `proxy_protocol on` sends version 1, which Lobby drops, and `proxy_protocol v2` is in the documentation of the stream module from 1.31.4. An older nginx needs HAProxy between the two. Neither configuration has been tried yet. Keep the relay's own logs short: they hold the family's addresses.

**Certificate.** Get it on the Pi, so that the key never leaves it. ACME DNS-01 needs nothing to be reachable; use a DNS token that can only write that one record. TLS-ALPN-01 can also pass through the relay (by its `acme-tls/1` protocol, to an ACME client on another port of the Pi), but needs a second port in the firewall. Let the client write the key with mode `0600` for Lobby's user.

## The direct road

```
                 introducer (Worker or own machine): passes sealed messages on
                    ▲ WebSocket, out            ▲ WebSocket, out
                    │                           │
 Lobby Server ──────┘                           └────── device
   │ stdin/stdout, unix socket (0600, secret)             │
 lobby-direct ◀═══ QUIC over the path ICE found ═════════▶
```

Both ends only open connections outwards: no port is opened at home. `lobby-direct` (`apps/direct`, Rust) finds the path (libjuice) and speaks QUIC (quinn). Each stream is one HTTP/1.1 connection, which it brings to Lobby Server over a unix socket; the entrance then treats it as any other, and knows which device it is. Film goes from the Pi to the device, or over the owner's own relay when the networks let nothing through, and never through the introducer: that closes every line after two minutes and passes at most 16 KB at a time.

The messages, exactly: [api.md](api.md#direct). Why it is like this: D-034.

### What it protects against

| Threat | Answer |
| --- | --- |
| The introducer reads along | Everything is sealed with a secret that only device and box have. It learns public keys, sizes, times, the addresses people connect from, and whether the box is there. It keeps none of that in a log. |
| The introducer, or who takes it over, pretends to be the box | The device opens only what the secret sealed, and takes only the certificate it knows. It can withhold, delay and count. |
| It pretends to be the device | Without the secret no hello opens, without the device's key no connection is proven, without the credential the entrance answers `404`. |
| It says old messages again, or another's | Every envelope is bound to box, device, conversation, direction and place; both ends put a fresh number into the session's keys. |
| It guesses the pairing code | 80 bits through scrypt (32 MB): not guessable, not even by a machine that has the whole conversation. Single use, ten minutes. |
| It stands in the middle with a code that leaked | The device commits to its half before it sees the box's, so the six digits on the two screens differ but for one chance in a million a try, five tries a code; wrong digits turn the device away. |
| A removed device, or one only for home | Its key leaves the introducer within a second or so, the box does not answer it, its live connections are closed by the next check (each second, and at once when a manager acts). Removing it deletes its identity. |
| A device that is let in uses another's credential | Refused: the connection is this device's. |
| A device makes the Pi knock on the home's network | Only addresses of the internet at large are taken from its description, no names; the Pi's own private addresses are not given either. |
| Other programs on the Pi | The socket is in a folder of mode 0700, itself 0600, and every connection starts with a secret that is new for each run and goes over stdin, never over the command line. QUIC listens on loopback and hears only its own bridges. |
| A lost backup | It holds no key of the direct road. Secrets in the catalogue are locked with one that is not in it; a restore forgets them all. |
| Too much | Limits on rings per device and in all, connections per device (3) and in all (16), streams (28), bytes under way (1 MB), buffers, and time for everything. The introducer knows only boxes on its list, and stops for the day at its cap. |

**Not protected against:** the introducer refusing to introduce, or telling a third party when the household watches from where; a device in wrong hands until it is removed; who reads the Pi's data folder has everything; the Pi's public address is known to who is let in, and to the STUN server; who knows the box id can keep the introducer's lines for it busy. On the home network the API is HTTP: who can change traffic there while a device enrols can stand in the middle of that, as with its credential.

### Pairing rooms

Every code that leads in has its own room at the introducer: a manager's window, each household's invitations, the demo's (D-063). The room's name is made from the code (api.md, Pairing with a code), so the introducer learns which room a device asks for and never the code. Between box and introducer, on the box's own line:

- ← `{ "t": "ready", "rooms": 64 }` after signing in: this introducer keeps up to 64 rooms for the box. An introducer from before says `{ "t": "ready" }`.
- → `{ "t": "rooms", "rooms": [{ "room", "until" }, …] }`: all of the box's rooms. What is not in it is closed, and devices in it are told `1000`. At most as many as `ready` said; more, or one that is no room, closes the line with `4003`. The box puts the rooms where a device is pairing first, then the newest; with more codes open than that, the oldest wait, and the server says so in its log.
- → `{ "t": "pairing", "room", "until" }` (or `"room": null`): what a box from before says, and what a new box says to an introducer from before. The room takes the place of all the box had.
- ← `{ "t": "msg", "session", "room", "p" }` from a device in a room: `room` says whose code it came with. An introducer from before leaves it out; then it is the one room it has.

Each room ends at its `until`, and 45 minutes after it was said at the latest: the box says them all again every 30 minutes, after the line was down and after a restart, when invitations' rooms open again. Three devices may be in one room at a time, 24 in all the box's rooms together; the daily cap counts each message, as any other. Rooms of another box are not taken over. `ROOMS_PER_BOX=1` on an introducer of one's own makes it as before, to try an old server against.

### Setting it up

Nothing of this is on by itself, and each step is the owner's.

1. **The program.** A release archive brings it as `bin/lobby-direct` where it was built for the platform, and the Docker image as `/opt/lobby/bin/lobby-direct` ([release.md](release.md#lobby-direct-per-platform)). Otherwise `tools/build-direct-pi.sh` builds it on the Pi, in a container with the Pi's Docker, into `~/lobby/bin/lobby-direct`. It must not be writable by others.
2. **The config**, then restart:

```json
{
  "outside": {
    "enabled": true,
    "name": "lobby.example.com",
    "direct": {
      "introducer": "wss://introducer.example.com",
      "stun": [{ "host": "stun.example.com", "port": 3478 }],
      "turn": { "host": "relay.example.com", "port": 3478, "secretFile": "turn.secret" },
      "bind": "192.168.1.10",
      "maxUploadMbit": 30,
      "binary": "bin/lobby-direct"
    }
  }
}
```

`introducer` is required. `stun`: one to four servers, used in turns; without one only a Pi with a public address is reachable. A STUN server sees addresses and nothing else; your own relay is one too. `turn`: left out means direct or nothing. Its secret is in a file of mode 600 (a `"secret"` in the config works, but the config is copied into every backup). Cloudflare's is refused. `bind`: the Pi's address at home, so that no other network of the Pi (a tailnet, Docker) is tried; it has to be a fixed one. `maxUploadMbit`: everything sent together stays under it; about 80% of the measured upload keeps the rest of the house usable. `name` need not exist in DNS for this road; it is what requests are for. The relay road (`tls`) can be there beside it.

3. **The introducer.** `lobby direct id` on the server prints the box id. On Cloudflare: copy `apps/introducer/wrangler.jsonc` to `wrangler.local.jsonc` (git-ignored), put the id in `BOXES`, and `npx wrangler deploy -c wrangler.local.jsonc` from `apps/introducer`. Free plan: `DAILY_CAP` counts lines and messages together and refuses the rest of the day (UTC), an evening's use is some tens, pairing up to a few hundred. Workers' own request limit comes on top. Turn its logs off (the config does) and add a rate limiting rule on the route if strangers find it. When it is updated, update the introducer before the servers: a server says all its rooms only to an introducer that says it keeps them, and one room otherwise, so either order works, but only both together let every open code pair.

   On a machine of one's own instead: `BOXES=<id> PORT=8676 TRUST_PROXY=1 node apps/introducer/src/node.ts` (Node 24, `npm install --omit=dev`), as a service under its own user, behind a web server with a certificate that passes WebSockets on and sets `X-Forwarded-For`. `TRUST_PROXY` only with such a server in front. Changing from one to the other is changing `introducer` in the config: devices learn the new address the next time they are at home.
4. **A manager** turns the entrance on (`PATCH /v1/outside`) and allows devices one by one. `GET /v1/outside` says under `direct` whether all is up.

### The owner's own relay (coturn)

Only for networks that let nothing through directly (both ends behind the strictest kind of NAT, or UDP blocked: the latter still fails, the relay is UDP too). It passes on encrypted QUIC. On the VPS, not built or run by Lobby:

```yaml
services:
  coturn:
    image: coturn/coturn:4.19.2
    network_mode: host
    restart: unless-stopped
    read_only: true
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    tmpfs: ["/var/lib/coturn", "/var/tmp"]
    mem_limit: 256m
    pids_limit: 100
    volumes: ["./turnserver.conf:/etc/coturn/turnserver.conf:ro"]
```

```
# turnserver.conf: mode 0640, readable by the container's user. The secret is also in turn.secret on the Pi.
listening-port=3478
listening-ip=<the VPS's public address>
relay-ip=<the VPS's public address>
min-port=49160
max-port=49200
realm=relay.example.com
use-auth-secret
static-auth-secret=<openssl rand -hex 32>
fingerprint
no-tcp
no-tls
no-dtls
no-tcp-relay
no-cli
no-multicast-peers
no-software-attribute
simple-log
log-file=stdout
# Each relayed stream, in bytes a second, and all together.
max-bps=4000000
bps-capacity=10000000
total-quota=16
user-quota=4
stale-nonce=600
max-allocate-lifetime=3600
# Nobody reaches anything through it that is not the internet, and nothing on the VPS itself.
denied-peer-ip=0.0.0.0-0.255.255.255
denied-peer-ip=10.0.0.0-10.255.255.255
denied-peer-ip=100.64.0.0-100.127.255.255
denied-peer-ip=127.0.0.0-127.255.255.255
denied-peer-ip=169.254.0.0-169.254.255.255
denied-peer-ip=172.16.0.0-172.31.255.255
denied-peer-ip=192.0.0.0-192.0.0.255
denied-peer-ip=192.0.2.0-192.0.2.255
denied-peer-ip=192.88.99.0-192.88.99.255
denied-peer-ip=192.168.0.0-192.168.255.255
denied-peer-ip=198.18.0.0-198.19.255.255
denied-peer-ip=198.51.100.0-198.51.100.255
denied-peer-ip=203.0.113.0-203.0.113.255
denied-peer-ip=224.0.0.0-255.255.255.255
denied-peer-ip=::1
denied-peer-ip=::ffff:0:0-::ffff:ffff:ffff
denied-peer-ip=64:ff9b::-64:ff9b::ffff:ffff
denied-peer-ip=100::-100::ffff:ffff:ffff:ffff
denied-peer-ip=2001::-2001:1ff:ffff:ffff:ffff:ffff:ffff:ffff
denied-peer-ip=2002::-2002:ffff:ffff:ffff:ffff:ffff:ffff:ffff
denied-peer-ip=fc00::-fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff
denied-peer-ip=fe80::-febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff
denied-peer-ip=<the VPS's public address>
# Both ends relayed meet here, at this address: allowed over the one above, only on relay ports.
allowed-peer-ip=<the VPS's public address>
```

coturn's `allowed-peer-ip` wins over `denied-peer-ip` and knows no ports, so with that last line a device with a relay password can also send UDP to other services at the VPS's own address. Leave the line out unless both ends need the relay at once, or close those services' UDP ports to the VPS itself in its firewall. The firewall lets in UDP 3478 and 49160–49200 and nothing else for this. Passwords are made by Lobby for twelve hours and travel sealed. If the VPS is also in a tailnet, the denied ranges above are what keeps that closed: check it with a TURN client before letting anyone use it.

### Congestion

Measured with `apps/server/test/direct-measure.ts` on 25 November 2026: the server, the real `lobby-direct` and the stand-in device on one Mac, through a made-up road in Node, while other work kept the machine at a load of 60 to 450. Speeds are low because of that and only compare with each other; what was dropped, waited and wasted is counted on the road itself. 48 MB, then eight times: read 4 MB, leave, ask for 200 kB elsewhere.

| | 40 Mbit/s, 60 ms, queue 100 ms | the same, 1% lost | 20 Mbit/s, 60 ms, queue 400 ms |
| --- | --- | --- | --- |
| quinn BBR | 24–30 Mbit/s, 13–17% dropped, jump 0.2–0.3 s | 23–27 Mbit/s, jump 0.3 s | 18 Mbit/s, queue 234–279 ms, jump 0.5 s |
| quinn Cubic | 32 Mbit/s, 1% dropped, jump 0.25 s | **1.8 Mbit/s**, jump 1.8 s | 18 Mbit/s, queue 269 ms, jump 0.5 s |
| noq 1.5 BBRv3 | 27 Mbit/s, 13% dropped, jump 0.3 s | did not end within 5 minutes | – |
| **quinn BBR, `maxUploadMbit` 16** | 14.5 Mbit/s, none dropped, queue 1 ms, jump 0.2 s | 15.6 Mbit/s, none dropped, jump 0.25 s | 14.6 Mbit/s, queue 6 ms, jump 0.25 s |

Left behind by an abandoned range: 0.9 to 1.2 MB without the cap, at most 1.3 MB; 0.3 MB with it. (It counts packet overhead and what had to be sent again.)

So: quinn with BBR, because a mobile network loses packets and Cubic takes each for congestion. Its price is the queue it fills and the packets it has dropped on a full one, so **set `maxUploadMbit`** to about 80% of the upload: then the queue stays empty and the rest of the house notices nothing. Nothing is capped unless it is set, because the server cannot know the line.

### Turning it off, rotation, trouble

- **Off now**: the app's switch or `lobby outside off`: every connection, the line to the introducer, the pairing room and the program itself are gone within a second or two. **Off for good**: take `direct` out of the config and restart; delete the Worker.
- **The certificate** changes by itself once a year; the next one is known to devices for at least 60 days before. `lobby direct rotate` takes the next one now; restart. A device that missed it learns it, sealed, when it rings.
- **The data folder may be known to others**: `lobby direct reset`, restart, put the new box id in the introducer, and let every device connect at home once (apps enrol by themselves). Remove devices whose credentials may be known.
- **The relay's secret**: new one in `turnserver.conf` and `turn.secret`, restart both. Passwords made with the old one end with it.
- **The introducer may be known to others**: put up another one under another address. Nothing on the devices is lost; it held nothing to lose.
- **After a restore**: nobody is enrolled, and the entrance is off. In a new data folder the box has a new id too.
- `problem` in `GET /v1/outside` says what is wrong: `the lobby-direct program is not there`, `the introducer cannot be reached: it does not know this box`. The program is started again with growing waits (1 s to a minute), the line too (1 s to five minutes).

### In the apps

`packages/LobbyKit`: `LobbyDirect` (what is said, the path, QUIC, the local server) and `ServerRoad` (the choice). Order: an address at home, one in the tailnet, the direct connection, and inside that the owner's relay. The addresses get 1.5 s before the app rings, or no head start on a network where the direct road was right before; once the direct road is there they get one more second. Looked at again when the network changes, when the app comes to the front and when a call fails. An address is used only after the server's id answered there; over the direct road the certificate takes that place.

Over the direct road **every** request goes through a server inside the app: 127.0.0.1, a random port, a path of 256 random bits, one `Host`, local connections only, no `Origin`, only `/v1/`. `URLProtocol` would not do: neither the player nor the system's downloads use one. No credential is ever sent to that port; the local server puts it on, so a program that took the port while the app was suspended learns the path and no credential. After suspension it is tried, and made again at the same port and path if it is gone. An answer that breaks off goes on from the missing byte (`Range`, `If-Range`, the same `ETag`) on a new connection or at the server's own address at home. At most 20 requests at once, six of them pictures.

**A path that breaks** (the mobile network gives the phone another port, or lets nothing through for a while) is mended by the device, not waited out (D-055). While something is carried, Apple's QUIC asks the box every second; when nothing at all came from the box for 3 s, that connection ends and a new one is rung at once, and what was under way goes on from the missing byte. The player shows "Reconnecting…" only if it runs dry meanwhile. A connection the device leaves ends on the Pi at once, as `left`. `no path` in the Pi's log therefore means that both ICE agents stopped hearing each other for half a minute, which a device in use no longer lets happen: seen now, it is a phone that went out of reach, or an app from before this.

Measured on the test road of the end-to-end tests (`SeekTests`: 70 ms, 1 to 1.5% lost, 20 Mbit/s, the Pi's cap at 45), 26 November 2026, before and after:

| | before | after |
| --- | --- | --- |
| A jump right after the path broke (silent, or a new NAT port) | 15.8 s | 3.9 to 4.2 s |
| A jump 7 s after the path broke under a full player | not measured (the same waits) | 0.2 to 0.7 s |
| The system player dragged over the bar, playing again (progressive MP4 / prepared HLS) | 1.4 to 1.7 s / 2.0 to 3.0 s | the same |
| The same by hand at the HTTP level: first byte / a second of film | 0.2 to 0.4 s / 0.6 to 0.8 s | the same |

The player asks for the place it jumps to, never what lies between (`Range: bytes=<there>-` for a file, the segment there for a stream). What a player gave up is still sent up to what the device's QUIC lets the box have under way: 4 to 5 MB for a drag over the bar with seven places. It goes beside the new request, not before it.

- **AirPlay** to another screen is off over it: the receiver fetches the film itself and cannot reach a server inside an app.
- **Downloads** over it run while the app does, in pieces of 4 MB, and go on when it is opened again. At home and in the tailnet the system runs them in the background. Mobile data only when the person allowed it: the app checks that itself, because to the system these connections never leave the device. A copy that was begun on one road starts over on the other.
- **Managing** stays at home and in the tailnet.
- **Keys** are in the Keychain, this device only, readable after first unlock, one entry beside the credential. Signing out and `device_revoked` remove them. On tvOS the Keychain is the only storage the system does not empty by itself; which server it is stands in the app's preferences, as before. That both survive there, and an update, has not been tried on a device.
- **The compiler**: pairing stretches the code with scrypt, half a second in a release build, about six in a debug build.

**A TV abroad.** It shows a QR code with its address on that network, a port and a key made for this once (`lobby://tv?a=…&p=…&k=…`). A manager's iPhone on the same network, with Tailscale on (the window can only be opened from home or the tailnet), reads it under Access From Outside and sends introducer and code, sealed with that key: who shares the hotel's network sees nothing and can put nothing in. Where devices cannot see each other, the remote picks the sixteen characters from the code's own 32 keys, and the address is typed; the system offers a nearby iPhone's keyboard. The app remembers the address. The manager's screen also shows `lobby://pair?i=…&c=…` as a QR code for an iPhone or iPad and as a link to send; opening one only fills in what a person would type: on a device that is not paired, or on a paired one as another server (D-048). Either way six digits are compared.

## The push relay

Apple takes pushes for the App Store apps only when they are signed with the publisher's APNs key, so a server someone runs at home cannot send them. The push relay (`apps/push-relay`, a Cloudflare Worker named `lobby-push`) holds that key and sends for any Lobby Server, without being able to read what is sent (D-064, the messages in [api.md](api.md#push-notifications--built)). It is run by the publisher, like the public introducer; nothing of it is at home.

```
 Lobby Server ── POST /v1/send, signed by the box ──▶ lobby-push ──▶ Apple ──▶ device
                  { handle, sealed text }               holds the key          notification service
 app ── POST /v1/tokens { ticket from its server, token } ──▶ lobby-push      opens the text
     ◀── handle ──                                                             with its key
 app ── PUT /v1/me/push { handle, key } ──▶ Lobby Server
```

### What it sees, and what it does not

| It sees | It never sees |
| --- | --- |
| The box id of each server that sends, and its address | What a notification says: who asks, for which title, which device waits |
| Each device's APNs token, its environment, and the handle it gave for it | The server's address at home, its name, or anything of the library |
| When and how many notifications, and their sizes | The keys the text is sealed with: they are made by the app and given only to its server |
| The address an app registers from | A credential: neither apps nor servers have one there |

It keeps the handles, which token and box each is for, and counts; no log. Apple sees the same as it does for any app: tokens, times, and the generic alert ("Lobby: A request is waiting.").

### What it protects against

| Threat | Answer |
| --- | --- |
| A server pushes to devices that are not its own | It knows no tokens, only the handles its own apps gave it, and the relay sends a box's notifications only to handles registered under that box's ticket. |
| Somebody sends as a household's server | Every send is signed by the box's key, and the box id is the hash of that key. A send said again, or an old one, is refused. |
| Somebody fills a household's list of devices | A registration needs a ticket that box signed in the last ten minutes. |
| The relay, or who takes it over, reads along | The text is sealed with a key per device and server; it sees ciphertext and sizes. It could withhold, delay or count, and send the generic alert to a device whose token it holds. |
| Too much | 32 devices a send, 30 sends a minute and 1,000 notifications a day per box, 30 an hour per device, 2,800 characters sealed, a daily cap in all. |
| A removed device | Its handle goes from the server; the app forgets it at the relay when it is signed out or removed, and a handle not registered again in 60 days is forgotten. |

**Not protected against:** somebody who has both a box's ticket and a token of the apps registering that token for the box; the relay's owner sending generic alerts to tokens it holds; traffic analysis of when a household's grown-ups are asked something. On a Mac the generic alert shows without actions (no notification service there yet); opening Lobby shows the question.

### Setting it up

For the publisher, once, on a machine that has the key (never print or copy it elsewhere):

1. `cd apps/push-relay`, copy `wrangler.jsonc` to `wrangler.local.jsonc` (git-ignored) and fill in the key id, team id and bundle id.
2. `npx wrangler deploy -c wrangler.local.jsonc`.
3. `npx wrangler secret put APNS_KEY -c wrangler.local.jsonc < <path of the .p8>`: the key goes from the file to Cloudflare, not through a terminal or a clipboard.
4. Put the Worker's address in `DEFAULT_RELAY` (`apps/server/src/push/service.ts`) for the next release, so that servers use it without a word in their config.

On a server: name the relay in the config, as the introducer is named: `"push": { "relay": "https://lobby-push.vandipyan.workers.dev" }` for the publisher's relay, which is the one that reaches the App Store apps. Once `DEFAULT_RELAY` is set in the code, a server without `push.relay` uses it. A server with its own key keeps sending directly (`"push": { "apns": … }`, operations.md); `"mode": "relay"` beside it uses the relay instead, `"mode": "off"` sends nothing. The box's key is the direct road's (`lobby direct id` prints its id); it is made at the first start if the direct road is not set up. After `lobby direct reset` the apps register again by themselves the next time they open.

## Turning it off

In the app, or `lobby outside off` on the Pi: every connection, road and pairing window closes within a second. For good: `"enabled": false` and a restart, then take the tunnel down. After a restored backup the entrance is off and no device is let in (see [operations.md](operations.md)).

## Keys and trouble

- **Tunnel keys**: make a new pair, put it in both ends, restart both. Once a year, and when anyone who had access to the VPS leaves.
- **The certificate's key**: renew with a new key; the server takes it within thirty seconds.
- **A device**: remove it and pair it again. `GET /v1/outside/access` shows where it came from.
- **The VPS is compromised, or may be**: `lobby outside off`, take `wg-lobby` down on the Pi, and make a new tunnel key there. It saw names, sizes, times and addresses, and could cut or redirect connections, not read them, as long as devices accept only a valid certificate. Look in the certificate transparency logs for certificates nobody asked for (who holds the VPS's address can answer HTTP-01 and TLS-ALPN-01 challenges for the name: a `CAA` record with `validationmethods=dns-01` and an account takes that away). Set up a new VPS; do not clean the old one. Device credentials need no change unless such a certificate was issued: then remove and pair again every device that was let in.

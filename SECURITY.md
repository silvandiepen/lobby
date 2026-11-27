# Security policy

Lobby Server faces the network: the home network, a tailnet, and, with the outside entrance on,
the internet. We take reports seriously and are grateful for them.

## Reporting a vulnerability

**Do not open a public issue.** Report privately, in either way:

- GitHub's private vulnerability reporting: the **Security** tab of this repository, then
  **Report a vulnerability**.
- Email: **support@hakobs.com**, with "Lobby security" in the subject.

Please include what is affected (component and version), how to reproduce it, and what an attacker
gains. A proof of concept helps but is not required. Leave out anything private from your own
library.

## What happens next

- We confirm that we received the report within **5 working days**.
- We investigate, keep you informed, and agree on a date for disclosure with you. We aim to fix
  serious problems within **90 days**, sooner when they are being exploited.
- We publish a fix and an advisory (GitHub Security Advisories), and credit you unless you would
  rather not be named.

This is coordinated disclosure: please give us the time to fix a problem before you publish it.
We will not take legal action against research done in good faith within this policy.

## Scope

In scope:

- **Lobby Server** (`apps/server`): authentication, pairing, the device and household guards,
  the outside entrance, file serving, imports and uploads.
- **lobby-direct** (`apps/direct`) and the direct connection (`packages/LobbyKit`, LobbyDirect).
- **The introducer** (`apps/introducer`).
- **The Apple apps** (`apps/apple`, `packages/LobbyKit`): credential storage, the loopback proxy,
  kids mode and the grown-up gate.
- **The installer and release archives** (`tools/release`): `install.sh`, the Docker image.

Out of scope:

- Problems that need an attacker who already controls the server's computer or a paired
  manager device.
- Vulnerabilities in ffmpeg, Node.js, the operating system or other dependencies, unless Lobby
  uses them unsafely. Report those to their projects.
- The vendored libjuice: report to [libjuice](https://github.com/paullouisageneau/libjuice) and
  tell us, so we can update.
- Denial of service by flooding a server on a network you are already on.

Known trade-offs, documented and by design:

- A fresh server can be claimed by the first device nearby (`claim: "open"`, the default) until
  it is claimed. Claim it straight after installing, or use the setup secret.
- At home and over Tailscale, devices talk to the server over plain HTTP with a bearer
  credential. The home network and Tailscale are trusted for transport; the outside entrance is
  end-to-end encrypted.

`docs/outside.md` ("What it protects against") describes the threat model of the outside
entrance.

## Supported versions

| Component | Supported |
| --- | --- |
| Lobby Server | the latest release (security fixes ship as a new patch release) |
| Apple apps | the latest version on the App Store, and `main` |
| Everything else | `main` |

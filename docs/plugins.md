# Plugins (design, not built)

**Status:** a design for later, on a low-priority card. Nothing here is built. It is written down now so that what is built in the meantime does not make it harder.

## Why, and why not yet

Plugins let a household, or someone else, add to Lobby Server what Lobby itself should not carry: another source of film information, a message to a home automation system when a film starts, another kind of library. They pay off once Lobby is released and people ask for such things. Until then they would slow the work that matters more, and every plugin interface is a promise that has to be kept.

Two rules hold for whatever comes:

- **Plugins run on the server only.** The apps on the App Store never load, show or advertise code from elsewhere. A plugin can add data the apps already understand (a title, a picture, a category); it cannot add screens to the apps.
- **Lobby ships no plugin that fetches media from the internet,** and its website and documentation point to none. What a household runs beside Lobby is its own business. The import folders already take in whatever lands in a folder, without Lobby knowing how it got there.

## What a plugin is

A folder with a manifest and a program:

```
plugins/
  example-notify/
    lobby-plugin.json
    main.ts            (or any program: see "How it runs")
```

```json
{
  "id": "example-notify",
  "name": "Example notifications",
  "version": "1.2.0",
  "lobby": ">=1.4 <2",
  "entry": "main.ts",
  "permissions": ["events:playback", "network:homeassistant.local:8123"],
  "settings": [
    { "key": "url", "type": "url", "label": "Home Assistant address" },
    { "key": "token", "type": "secret", "label": "Access token" }
  ]
}
```

- `lobby`: which versions of the plugin interface it works with. A Lobby that does not match does not start it, and says so.
- `permissions`: everything it may do. A manager sees them in plain words before turning it on, and again when an update asks for more.
- `settings`: shown as a form on a Plugins page in the Server group of Settings. `secret` values are kept like the TMDB key: never shown again, never in a backup meant for sharing.

## How it runs

Each plugin runs **as its own process**, never inside the server:

- Node's permission model where the plugin is JavaScript (`--permission`, with file and network access only as its manifest asks), or a separate user and a sandbox (systemd's `ProtectSystem`, `PrivateTmp`, a fixed network allow-list) where it is anything else.
- It talks to the server over a local socket with JSON lines, as the direct connection's helper does: requests, answers, events. It never sees the database, the media drive or other plugins, only what the interface gives it.
- Limits: memory, CPU time, answers within a time, messages per second. A plugin that breaks a limit or crashes is stopped and restarted with a growing wait; after five failures it stays off until a manager turns it on.
- A plugin never blocks the server: if it does not answer, Lobby goes on without it.

## What a plugin can do

| Kind | It gets | It may give back | Example |
| --- | --- | --- | --- |
| **Events** | Played, finished, added, removed, a device paired (never who, unless a permission asks for the viewer's name) | Nothing | A light dims when a film starts |
| **Information** | A title Lobby could not match, or asks about | Title, year, summary, pictures, a match | A source for home videos, or for a country TMDB knows little of |
| **Import** | A file the import folders found | Where it belongs, its name, its kind | A rule for a household's own naming |
| **Actions** | A button a server admin presses on that Plugins page | A message, a result | Rebuild something on demand |

What it cannot do: change files on the media drive, read other households' data, see secrets other than its own, add screens or code to the apps, or reach the internet beyond its listed addresses.

## Installing, updating, removing

- Plugins live in their own repositories on GitHub, named `lobby-plugin-<name>` so they can be found by searching for that name. A small index may follow later; a store run by Lobby does not.
- A manager installs a plugin from a release of such a repository (an archive with a checksum), from a file, or by putting its folder in `plugins/`. Lobby fetches no plugins by itself.
- Updating replaces the folder and asks again for any new permission.
- Removing stops it and deletes its folder and settings; what it added to titles stays, marked as coming from it, and can be removed with it.
- Every start, stop, failure and permission change is in the server's log and in the settings audit.

## Kids, households, away

- A kids device never triggers a plugin action, and events about kids viewers carry no titles a plugin has no permission for.
- Each guest household sees only its own events; plugins are the owner's, and only the owner's managers turn them on.
- Plugin actions are home and tailnet only, like all managing.

## What has to be true first

1. Lobby is released, and there are requests that plugins would answer.
2. The server's events are one internal stream (playback, library, devices) that a plugin interface can listen to without reaching into the code.
3. The settings store can hold a plugin's settings and secrets.
4. A first plugin from the Lobby project, small and useful, proves the interface before others write any: for example events to a home automation system.

## Not planned

- Plugins in the apps.
- A plugin store run by Lobby.
- A plugin from Lobby that downloads media from the internet.

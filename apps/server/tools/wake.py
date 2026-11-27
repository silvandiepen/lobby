# SPDX-License-Identifier: MPL-2.0
"""Lobby's helper for waking Apple TVs (docs/operations.md, "Waking the Apple TV").

Lobby Server keeps this running with the Python of a virtual environment that has pyatv in it,
and talks to it in JSON lines: one request per line on stdin, one answer per line on stdout.
It speaks Apple's Companion protocol through pyatv's library, which is not an official
interface: a tvOS update can break it, and then waking fails while everything else goes on.

Requests carry an "id" that comes back in the answer, and an "op":

  ping                                  -> {"pyatv": "0.18.0"}
  scan        {timeout?, hosts?}        -> {"televisions": [Television]}
  pair_begin  {device}                  -> {"pairing": "<token>"}   the TV shows a code now
  pair_pin    {pairing, pin}            -> {}
  pair_finish {pairing}                 -> {"television": Television}
  pair_cancel {pairing}                 -> {}
  wake        {device, app, pickProfile?} -> {"front", "selected", "reason"}  turns it on, opens the app
  pick        {device, app}             -> {"front", "selected", "reason"}    presses select once, opens the app again
  unpair      {device}                  -> {"removed": bool}

"front" says whether the app is in front afterwards: true, false, or null when pyatv cannot tell
(over Companion alone it cannot: Lobby Server then waits for Lobby on its live channel, and asks
"pick" itself). When pyatv can tell and the app is not in front within FRONT_SECONDS, which is
what tvOS's "who is watching" screen does, "wake" presses select once (that picks the profile
that is focused, normally the last one used) and opens the app again, unless pickProfile is
false. "selected" says whether it did. Never more than one select per request.

Television: {"id", "name", "model", "paired", "identifiers"}. A failure is
{"id", "ok": false, "code", "message"}; codes: bad_request, not_found, not_paired,
pairing_failed, timeout, failed.

The credentials stay in pyatv's file (~/.pyatv.conf unless --storage says otherwise), which is
kept readable by this user only. Nothing here writes a credential or a PIN to stdout or stderr.
"""

import argparse
import asyncio
import json
import os
import secrets
import sys
import time

try:
    import pyatv
    from pyatv import exceptions
    from pyatv.const import FeatureName, FeatureState, OperatingSystem, Protocol
    from pyatv.storage.file_storage import FileStorage
except ImportError:  # pragma: no cover - said to Lobby, which shows it to the manager
    print(json.dumps({"event": "missing", "message": "pyatv is not installed for this Python"}), flush=True)
    sys.exit(3)

MAX_LINE = 16 * 1024
PAIRING_SECONDS = 60
CONNECT_SECONDS = 15
SCAN_SECONDS = 5
MAX_PAIRINGS = 2
# How long the app may take to be in front after it was opened, when pyatv can tell.
FRONT_SECONDS = 5
FRONT_LOOK_SECONDS = 0.5

CREDENTIAL_PROTOCOLS = ("airplay", "companion", "dmap", "mrp", "raop")


class Refusal(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


def version():
    try:
        from importlib.metadata import version as installed

        return installed("pyatv")
    except Exception:  # noqa: BLE001 - only for the hello
        return "unknown"


class Helper:
    def __init__(self, loop, storage_path):
        self.loop = loop
        self.storage_path = storage_path
        self.storage = FileStorage(storage_path, loop)
        self.pairings = {}
        self.out = sys.stdout

    async def start(self):
        await self.storage.load()
        self.protect()

    def protect(self):
        try:
            if os.path.exists(self.storage_path):
                os.chmod(self.storage_path, 0o600)
        except OSError:
            pass

    async def save(self):
        await self.storage.save()
        self.protect()

    def say(self, message):
        self.out.write(json.dumps(message, separators=(",", ":")) + "\n")
        self.out.flush()

    # ---- What is known ----

    def stored(self, identifiers):
        """The stored settings of a device with one of these identifiers, or None."""
        for settings in self.storage.settings:
            protocols = settings.protocols
            if any(getattr(protocols, name).identifier in identifiers for name in CREDENTIAL_PROTOCOLS):
                return settings
        return None

    def is_paired(self, identifiers):
        settings = self.stored(identifiers)
        return settings is not None and bool(settings.protocols.companion.credentials)

    def describe(self, conf):
        identifiers = sorted(i for i in conf.all_identifiers if i)
        return {
            "id": conf.identifier,
            "name": conf.name,
            "model": conf.device_info.model_str,
            "paired": self.is_paired(set(identifiers)),
            "identifiers": identifiers,
        }

    async def find(self, device, timeout=SCAN_SECONDS):
        found = await pyatv.scan(
            self.loop, timeout=timeout, identifier=device, protocol=Protocol.Companion, storage=self.storage
        )
        if not found:
            raise Refusal("not_found", "That Apple TV was not found on the network.")
        return found[0]

    # ---- The requests ----

    async def op_ping(self, _request):
        return {"pyatv": version()}

    async def op_scan(self, request):
        timeout = request.get("timeout", SCAN_SECONDS)
        if not isinstance(timeout, (int, float)) or not 1 <= timeout <= 15:
            raise Refusal("bad_request", "timeout must be 1 to 15 seconds")
        hosts = request.get("hosts")
        if hosts is not None and (not isinstance(hosts, list) or not all(isinstance(h, str) for h in hosts)):
            raise Refusal("bad_request", "hosts must be a list of addresses")
        found = await pyatv.scan(
            self.loop,
            timeout=timeout,
            hosts=hosts or None,
            protocol=Protocol.Companion,
            storage=self.storage,
        )
        televisions = [
            self.describe(conf)
            for conf in found
            if conf.device_info.operating_system in (OperatingSystem.TvOS, OperatingSystem.Unknown)
        ]
        return {"televisions": televisions}

    async def op_pair_begin(self, request):
        device = text(request, "device")
        self.forget_stale()
        if len(self.pairings) >= MAX_PAIRINGS:
            raise Refusal("bad_request", "Another pairing is under way.")
        conf = await self.find(device)
        handler = await pyatv.pair(conf, Protocol.Companion, self.loop, storage=self.storage, name="Lobby")
        try:
            await asyncio.wait_for(handler.begin(), CONNECT_SECONDS)
        except Exception:
            await handler.close()
            raise
        token = secrets.token_urlsafe(16)
        self.pairings[token] = {"handler": handler, "conf": conf, "until": time.monotonic() + PAIRING_SECONDS}
        return {"pairing": token, "expiresInMs": PAIRING_SECONDS * 1000}

    def pairing(self, request):
        self.forget_stale()
        one = self.pairings.get(text(request, "pairing"))
        if one is None:
            raise Refusal("timeout", "The code was not typed in time. Start again.")
        return one

    async def op_pair_pin(self, request):
        one = self.pairing(request)
        pin = request.get("pin")
        if not isinstance(pin, str) or not pin.isdigit() or not 4 <= len(pin) <= 8:
            raise Refusal("bad_request", "The code is the digits the TV shows.")
        one["handler"].pin(int(pin))
        return {}

    async def op_pair_finish(self, request):
        token = text(request, "pairing")
        one = self.pairing(request)
        self.pairings.pop(token, None)
        handler = one["handler"]
        try:
            await asyncio.wait_for(handler.finish(), CONNECT_SECONDS)
            if not handler.has_paired:
                raise Refusal("pairing_failed", "The Apple TV did not take the code.")
            await self.save()
        except exceptions.PairingError as error:
            raise Refusal("pairing_failed", "The Apple TV did not take the code.") from error
        finally:
            await handler.close()
        return {"television": self.describe(one["conf"])}

    async def op_pair_cancel(self, request):
        one = self.pairings.pop(text(request, "pairing"), None)
        if one is not None:
            await one["handler"].close()
        return {}

    async def connected(self, device):
        conf = await self.find(device)
        if not self.is_paired(set(conf.all_identifiers)):
            raise Refusal("not_paired", "Lobby Server is not connected to that Apple TV.")
        return await asyncio.wait_for(pyatv.connect(conf, self.loop, storage=self.storage), CONNECT_SECONDS)

    async def close(self, atv):
        closing = atv.close()
        if closing:
            await asyncio.wait(closing, timeout=5)

    async def in_front(self, atv, app):
        """Whether the app is in front within FRONT_SECONDS: True, False, or None when pyatv cannot tell."""
        try:
            if atv.features.get_feature(FeatureName.App).state != FeatureState.Available:
                return None
        except Exception:  # noqa: BLE001 - not knowing is an answer too
            return None
        until = time.monotonic() + FRONT_SECONDS
        while True:
            try:
                current = atv.metadata.app
            except Exception:  # noqa: BLE001
                return None
            if current is not None and current.identifier == app:
                return True
            if time.monotonic() >= until:
                return False
            await asyncio.sleep(FRONT_LOOK_SECONDS)

    async def select_and_open(self, atv, app):
        """One press of select, which takes the focused profile on "who is watching", and the app again."""
        await asyncio.wait_for(atv.remote_control.select(), CONNECT_SECONDS)
        # The picker takes a moment to go.
        await asyncio.sleep(1)
        await asyncio.wait_for(atv.apps.launch_app(app), CONNECT_SECONDS)

    async def op_wake(self, request):
        device = text(request, "device")
        app = text(request, "app")
        pick = request.get("pickProfile", True) is not False
        atv = await self.connected(device)
        try:
            await asyncio.wait_for(atv.power.turn_on(), CONNECT_SECONDS)
            await asyncio.wait_for(atv.apps.launch_app(app), CONNECT_SECONDS)
            front = await self.in_front(atv, app)
            if front is False and pick:
                await self.select_and_open(atv, app)
                return opened(await self.in_front(atv, app), True)
            return opened(front, False)
        finally:
            await self.close(atv)

    async def op_pick(self, request):
        device = text(request, "device")
        app = text(request, "app")
        atv = await self.connected(device)
        try:
            await self.select_and_open(atv, app)
            return opened(await self.in_front(atv, app), True)
        finally:
            await self.close(atv)

    async def op_unpair(self, request):
        device = text(request, "device")
        settings = self.stored({device})
        if settings is None:
            return {"removed": False}
        await self.storage.remove_settings(settings)
        await self.save()
        return {"removed": True}

    def forget_stale(self):
        now = time.monotonic()
        for token, one in list(self.pairings.items()):
            if one["until"] < now:
                self.pairings.pop(token, None)
                self.loop.create_task(one["handler"].close())

    async def handle(self, line):
        request_id = None
        try:
            if len(line) > MAX_LINE:
                raise Refusal("bad_request", "That request is too long.")
            request = json.loads(line)
            if not isinstance(request, dict):
                raise Refusal("bad_request", "A request is a JSON object.")
            request_id = request.get("id")
            op = request.get("op")
            method = getattr(self, f"op_{op}", None) if isinstance(op, str) and op.isidentifier() else None
            if method is None:
                raise Refusal("bad_request", "There is no such request.")
            answer = await method(request)
            self.say({"id": request_id, "ok": True, **answer})
        except Refusal as refusal:
            self.say({"id": request_id, "ok": False, "code": refusal.code, "message": refusal.message})
        except json.JSONDecodeError:
            self.say({"id": None, "ok": False, "code": "bad_request", "message": "That is not JSON."})
        except asyncio.TimeoutError:
            self.say({"id": request_id, "ok": False, "code": "timeout", "message": "The Apple TV did not answer in time."})
        except exceptions.AuthenticationError:
            self.say({"id": request_id, "ok": False, "code": "not_paired", "message": "The Apple TV no longer accepts Lobby Server. Connect it again."})
        except Exception as error:  # noqa: BLE001 - every request gets an answer
            # The kind only: a message from deep inside could carry more than it should.
            self.say({"id": request_id, "ok": False, "code": "failed", "message": f"The Apple TV could not be reached ({type(error).__name__})."})


def opened(front, selected):
    """The answer to wake and pick. "reason" is "timeout" when the app was not in front in time."""
    return {"front": front, "selected": selected, "reason": "timeout" if front is False else None}


def text(request, key):
    value = request.get(key)
    if not isinstance(value, str) or value == "" or len(value) > 200:
        raise Refusal("bad_request", f"{key} is missing.")
    return value


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--storage", default=os.path.join(os.path.expanduser("~"), ".pyatv.conf"))
    args = parser.parse_args()
    # Whatever this writes is for this user only, the credentials file first of all.
    os.umask(0o077)
    loop = asyncio.get_running_loop()
    helper = Helper(loop, args.storage)
    await helper.start()

    reader = asyncio.StreamReader(limit=MAX_LINE * 2)
    await loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(reader), sys.stdin)
    helper.say({"event": "ready", "pyatv": version()})
    tasks = set()
    while True:
        try:
            line = await reader.readline()
        except ValueError:
            helper.say({"id": None, "ok": False, "code": "bad_request", "message": "That request is too long."})
            continue
        if not line:
            break
        line = line.decode("utf-8", "replace").strip()
        if not line:
            continue
        task = loop.create_task(helper.handle(line))
        tasks.add(task)
        task.add_done_callback(tasks.discard)
    for one in list(helper.pairings.values()):
        await one["handler"].close()
    if tasks:
        await asyncio.wait(tasks, timeout=5)


if __name__ == "__main__":
    asyncio.run(main())

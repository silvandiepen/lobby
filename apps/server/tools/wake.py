# SPDX-License-Identifier: MPL-2.0
"""Lobby's helper for Apple TVs and AirPlay speakers (docs/operations.md, "Waking the Apple TV"
and "Playing on speakers").

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

  speakers    {timeout?, hosts?}        -> {"speakers": [Speaker]}
  stream      {speaker, stream, ffmpeg, file, startMs, volume?, title?, artist?, album?}
                                        -> {"volume"}   once the speaker takes the sound
  stream_stop {stream}                  -> {"stopped": bool}
  volume      {stream, volume}          -> {"volume"}
  speaker_password {speaker, password}  -> {}           null takes it away

A stream decodes the file with ffmpeg from startMs into FLAC, which pyatv's RAOP client sends to
the speaker. It goes on after its answer; when it ends, by itself or by stream_stop, the helper
says {"event": "stream_ended", "stream", "reason": "ended" | "stopped" | "failed", "code"}.
pyatv's RAOP client has no pause of its own (its pause stops), so Lobby Server pauses by
stopping and resumes by streaming again from where it was. Volume is 0 to 1.

Speaker: {"id", "name", "model", "kind": "homepod" | "speaker", "access", "hasPassword"};
access: "open", "password" (one is needed and none is stored), or "home_only" (the speaker lets
only people of its Home play; in the Home app: Allow Speaker & TV Access, Everyone on the Same
Network). Apple TVs and Macs are left out: they are in Play On as themselves.

"front" says whether the app is in front afterwards: true, false, or null when pyatv cannot tell
(over Companion alone it cannot: Lobby Server then waits for Lobby on its live channel, and asks
"pick" itself). When pyatv can tell and the app is not in front within FRONT_SECONDS, which is
what tvOS's "who is watching" screen does, "wake" presses select once (that picks the profile
that is focused, normally the last one used) and opens the app again, unless pickProfile is
false. "selected" says whether it did. Never more than one select per request.

Television: {"id", "name", "model", "paired", "identifiers"}. A failure is
{"id", "ok": false, "code", "message"}; codes: bad_request, not_found, not_paired,
pairing_failed, timeout, failed; for speakers also refused (the speaker said no: its access,
or a wrong password) and not_streaming.

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
    from pyatv.const import (
        DeviceModel,
        FeatureName,
        FeatureState,
        OperatingSystem,
        PairingRequirement,
        Protocol,
    )
    from pyatv.interface import MediaMetadata
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
# A speaker has this long to take the sound before a stream counts as refused.
STREAM_START_SECONDS = 3
MAX_STREAMS = 8

# Apple TVs are in Play On as Lobby devices; as speakers they would be there twice.
APPLE_TVS = ("Gen2", "Gen3", "Gen4", "Gen4K", "AppleTV4KGen2", "AppleTV4KGen3", "AppleTVGen1")
HOMEPODS = ("HomePod", "HomePodMini", "HomePodGen2")


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
        self.streams = {}
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

    # ---- Speakers ----

    def speaker(self, conf):
        """A speaker as Lobby Server sees it, or None for an Apple TV or a Mac."""
        info = conf.device_info
        model = getattr(info.model, "name", "Unknown")
        if model in APPLE_TVS or info.operating_system == OperatingSystem.MacOS:
            return None
        service = conf.get_service(Protocol.RAOP)
        if service is None:
            return None
        airplay = conf.get_service(Protocol.AirPlay)
        properties = airplay.properties if airplay is not None else {}
        if properties.get("acl", "0") == "1" or properties.get("act", "0") == "2":
            access = "home_only"
        elif service.pairing in (PairingRequirement.Disabled, PairingRequirement.Unsupported):
            access = "home_only"
        elif service.requires_password and not service.password:
            access = "password"
        else:
            access = "open"
        return {
            "id": conf.identifier,
            "name": conf.name,
            "model": info.model_str,
            "kind": "homepod" if model in HOMEPODS else "speaker",
            "access": access,
            "hasPassword": bool(service.password),
        }

    async def op_speakers(self, request):
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
            protocol={Protocol.RAOP, Protocol.AirPlay},
            storage=self.storage,
        )
        speakers = [one for one in (self.speaker(conf) for conf in found) if one is not None]
        return {"speakers": speakers}

    async def find_speaker(self, speaker):
        found = await pyatv.scan(
            self.loop, timeout=SCAN_SECONDS, identifier=speaker, protocol=Protocol.RAOP, storage=self.storage
        )
        if not found:
            raise Refusal("not_found", "That speaker was not found on the network.")
        return found[0]

    async def op_stream(self, request):
        speaker = text(request, "speaker")
        token = text(request, "stream")
        ffmpeg = text(request, "ffmpeg")
        path = request.get("file")
        if not isinstance(path, str) or not os.path.isabs(path):
            raise Refusal("bad_request", "file must be an absolute path.")
        start_ms = request.get("startMs", 0)
        if not isinstance(start_ms, (int, float)) or start_ms < 0:
            raise Refusal("bad_request", "startMs must be 0 or more.")
        volume = request.get("volume")
        if volume is not None and (not isinstance(volume, (int, float)) or not 0 <= volume <= 1):
            raise Refusal("bad_request", "volume must be 0 to 1.")
        if token in self.streams:
            raise Refusal("bad_request", "That stream is under way.")
        if len(self.streams) >= MAX_STREAMS:
            raise Refusal("bad_request", "Too many streams at once.")
        conf = await self.find_speaker(speaker)
        atv = await asyncio.wait_for(pyatv.connect(conf, self.loop, storage=self.storage), CONNECT_SECONDS)
        decoder = None
        try:
            # Decoded here, as the speaker wants it (44.1 kHz, 16 bits, stereo), so that every
            # file of the library plays, whatever pyatv's decoder knows.
            decoder = await asyncio.create_subprocess_exec(
                ffmpeg,
                "-nostdin",
                "-hide_banner",
                "-loglevel",
                "error",
                "-ss",
                f"{start_ms / 1000:.3f}",
                "-i",
                path,
                "-map",
                "0:a:0",
                "-vn",
                "-ac",
                "2",
                "-ar",
                "44100",
                "-sample_fmt",
                "s16",
                "-f",
                "flac",
                "pipe:1",
                stdin=asyncio.subprocess.DEVNULL,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL,
            )
        except Exception:
            await self.close(atv)
            raise
        metadata = MediaMetadata(
            title=short(request.get("title")),
            artist=short(request.get("artist")),
            album=short(request.get("album")),
        )
        one = {"atv": atv, "decoder": decoder, "stopped": False, "speaker": speaker}
        self.streams[token] = one

        async def send():
            if volume is not None:
                await atv.audio.set_volume(volume * 100)
            await atv.stream.stream_file(decoder.stdout, metadata=metadata)

        task = self.loop.create_task(send())
        one["task"] = task
        done, _ = await asyncio.wait({task}, timeout=STREAM_START_SECONDS)
        if done:
            # Over before it began: refused, or a file of nothing.
            error = task.exception()
            if error is not None:
                await self.end_stream(token, None)
                raise error
        task.add_done_callback(lambda finished: self.loop.create_task(self.end_stream(token, finished)))
        return {"volume": round(atv.audio.volume / 100, 3)}

    async def end_stream(self, token, task):
        one = self.streams.pop(token, None)
        if one is None:
            return
        decoder = one["decoder"]
        if decoder.returncode is None:
            decoder.kill()
        try:
            await asyncio.wait_for(decoder.wait(), 5)
        except asyncio.TimeoutError:
            pass
        await self.close(one["atv"])
        if task is None:
            return
        error = None if task.cancelled() else task.exception()
        if one["stopped"]:
            self.say({"event": "stream_ended", "stream": token, "reason": "stopped", "code": None})
        elif error is None:
            self.say({"event": "stream_ended", "stream": token, "reason": "ended", "code": None})
        else:
            self.say({"event": "stream_ended", "stream": token, "reason": "failed", "code": failure_code(error)})

    async def op_stream_stop(self, request):
        token = text(request, "stream")
        one = self.streams.get(token)
        if one is None:
            return {"stopped": False}
        one["stopped"] = True
        try:
            await asyncio.wait_for(one["atv"].remote_control.stop(), CONNECT_SECONDS)
        finally:
            task = one.get("task")
            if task is not None:
                await asyncio.wait({task}, timeout=CONNECT_SECONDS)
            await self.end_stream(token, task)
        return {"stopped": True}

    async def op_volume(self, request):
        token = text(request, "stream")
        volume = request.get("volume")
        if not isinstance(volume, (int, float)) or not 0 <= volume <= 1:
            raise Refusal("bad_request", "volume must be 0 to 1.")
        one = self.streams.get(token)
        if one is None:
            raise Refusal("not_streaming", "Nothing plays on that speaker now.")
        atv = one["atv"]
        await asyncio.wait_for(atv.audio.set_volume(volume * 100), CONNECT_SECONDS)
        return {"volume": round(atv.audio.volume / 100, 3)}

    async def op_speaker_password(self, request):
        speaker = text(request, "speaker")
        password = request.get("password")
        if password is not None and (not isinstance(password, str) or not 1 <= len(password) <= 128):
            raise Refusal("bad_request", "The password is 1 to 128 characters.")
        conf = await self.find_speaker(speaker)
        settings = await self.storage.get_settings(conf)
        settings.protocols.raop.password = password
        await self.save()
        return {}

    def forget_stale(self):
        now = time.monotonic()
        for token, one in list(self.pairings.items()):
            if one["until"] < now:
                self.pairings.pop(token, None)
                self.loop.create_task(one["handler"].close())

    async def handle(self, line):
        request_id = None
        thing = "The Apple TV"
        try:
            if len(line) > MAX_LINE:
                raise Refusal("bad_request", "That request is too long.")
            request = json.loads(line)
            if not isinstance(request, dict):
                raise Refusal("bad_request", "A request is a JSON object.")
            request_id = request.get("id")
            op = request.get("op")
            if op in SPEAKER_OPS:
                thing = "The speaker"
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
            self.say({"id": request_id, "ok": False, "code": "timeout", "message": f"{thing} did not answer in time."})
        except exceptions.AuthenticationError:
            if thing == "The speaker":
                self.say({"id": request_id, "ok": False, "code": "refused", "message": "The speaker did not let Lobby Server play."})
            else:
                self.say({"id": request_id, "ok": False, "code": "not_paired", "message": "The Apple TV no longer accepts Lobby Server. Connect it again."})
        except Exception as error:  # noqa: BLE001 - every request gets an answer
            # The kind only: a message from deep inside could carry more than it should.
            self.say({"id": request_id, "ok": False, "code": "failed", "message": f"{thing} could not be reached ({type(error).__name__})."})


SPEAKER_OPS = ("speakers", "stream", "stream_stop", "volume", "speaker_password")


def failure_code(error):
    """What a stream that broke says of why: the speaker refused, or anything else."""
    if isinstance(error, exceptions.AuthenticationError):
        return "refused"
    if isinstance(error, asyncio.TimeoutError):
        return "timeout"
    return "failed"


def short(value):
    """A title for the speaker's own display, or None."""
    return value[:200] if isinstance(value, str) and value else None


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
    for token in list(helper.streams):
        await helper.op_stream_stop({"stream": token})
    if tasks:
        await asyncio.wait(tasks, timeout=5)


if __name__ == "__main__":
    asyncio.run(main())

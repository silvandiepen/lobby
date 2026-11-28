# SPDX-License-Identifier: MPL-2.0
"""A stand-in for pyatv in the tests of tools/wake.py: one Apple TV, "AA:BB", that behaves as the
state file says. What it is asked goes to the log file, one JSON line each.

scenario:
  direct  Lobby is in front once it is opened.
  picker  tvOS asks who is watching: Lobby is in front only after select and opening it again.
  never   Lobby never comes to the front.
  blind   pyatv cannot tell which app is in front (as over Companion alone).

Speakers, for "speakers" and "stream" (looked for with the RAOP protocol): a HomePod "11:22"
that plays, one "33:44" that lets only its Home play, one "55:66" that wants a password, and the
Apple TV, which is not a speaker. "speaker" in the state file says how a stream goes:
  plays   it takes the sound until the decoder ends or it is stopped (the default).
  refuses it says no, as a speaker that lets only its Home play does.
What a stream sent is logged: how many bytes, and whether they began as FLAC.
"""

import asyncio
import json
import os

from pyatv import const, exceptions  # noqa: F401 - wake.py imports them from here

__all__ = ["scan", "connect", "pair", "exceptions", "const"]


def _state():
    with open(os.environ["LOBBY_FAKE_PYATV"], encoding="utf-8") as file:
        return json.load(file)


def _log(what, **more):
    with open(_state()["log"], "a", encoding="utf-8") as file:
        file.write(json.dumps({"call": what, **more}) + "\n")


class _Info:
    def __init__(self, model=const.DeviceModel.Gen4K, model_str="Apple TV 4K (fake)"):
        self.model = model
        self.model_str = model_str
        self.operating_system = const.OperatingSystem.TvOS


class _Service:
    def __init__(self, pairing=const.PairingRequirement.NotNeeded, password=False, properties=None):
        self.pairing = pairing
        self.requires_password = password
        self.password = None
        self.properties = properties or {}


class _Conf:
    def __init__(self, identifier="AA:BB", name="Living Room", info=None, services=None):
        self.identifier = identifier
        self.name = name
        self.all_identifiers = [identifier]
        self.device_info = info or _Info()
        self.services = services or {const.Protocol.RAOP: _Service(), const.Protocol.AirPlay: _Service()}

    def get_service(self, protocol):
        return self.services.get(protocol)


def _speakers():
    home = _Info(const.DeviceModel.HomePod, "HomePod (fake)")
    mini = _Info(const.DeviceModel.HomePodMini, "HomePod mini (fake)")
    return [
        _Conf(),
        _Conf("11:22", "Kitchen", home),
        _Conf("33:44", "Bedroom", mini, {
            const.Protocol.RAOP: _Service(),
            const.Protocol.AirPlay: _Service(properties={"acl": "1"}),
        }),
        _Conf("55:66", "Garden", _Info(const.DeviceModel.Unknown, "Speaker (fake)"), {
            const.Protocol.RAOP: _Service(password=True),
        }),
    ]


async def scan(loop, timeout=5, identifier=None, protocol=None, storage=None, hosts=None):
    _log("scan")
    wanted = protocol if isinstance(protocol, set) else {protocol}
    if const.Protocol.RAOP in wanted:
        found = _speakers()
        return [one for one in found if identifier is None or one.identifier == identifier]
    if identifier not in (None, "AA:BB"):
        return []
    return [_Conf()]


class _App:
    def __init__(self, identifier):
        self.identifier = identifier
        self.name = identifier


class _Feature:
    def __init__(self, state):
        self.state = state


class _Tv:
    def __init__(self):
        self.scenario = _state()["scenario"]
        self.front = None
        self.selected = False
        tv = self

        class Power:
            async def turn_on(self, await_new_state=False):
                _log("turn_on")

        class Apps:
            async def launch_app(self, app):
                _log("launch_app", app=app)
                if tv.scenario == "direct" or (tv.scenario == "picker" and tv.selected):
                    tv.front = app

        class Remote:
            async def select(self, action=None):
                _log("select")
                tv.selected = True

        class Features:
            def get_feature(self, name):
                available = tv.scenario != "blind"
                return _Feature(const.FeatureState.Available if available else const.FeatureState.Unavailable)

        class Metadata:
            @property
            def app(self):
                return _App(tv.front) if tv.front else None

        self.power = Power()
        self.apps = Apps()
        self.remote_control = Remote()
        self.features = Features()
        self.metadata = Metadata()

    def close(self):
        _log("close")
        return set()


class _Speaker:
    def __init__(self, conf):
        speaker = self
        self.level = 40.0
        self.stopped = False
        how = _state().get("speaker", "plays")

        class Audio:
            @property
            def volume(self):
                return speaker.level

            async def set_volume(self, level):
                _log("set_volume", volume=level)
                speaker.level = level

        class Stream:
            async def stream_file(self, source, metadata=None):
                _log("stream_file", title=metadata.title if metadata else None)
                if how == "refuses":
                    raise exceptions.AuthenticationError("not of this Home")
                sent = 0
                head = b""
                while not speaker.stopped:
                    chunk = await source.read(65536)
                    if not chunk:
                        break
                    if len(head) < 4:
                        head += chunk[: 4 - len(head)]
                    sent += len(chunk)
                    # A speaker takes the sound as it plays, not all at once.
                    await asyncio.sleep(1)
                _log("sent", bytes=sent, flac=head == b"fLaC", stopped=speaker.stopped)

        class Remote:
            async def stop(self):
                _log("stop")
                speaker.stopped = True

        self.audio = Audio()
        self.stream = Stream()
        self.remote_control = Remote()

    def close(self):
        _log("close")
        return set()


async def connect(conf, loop, storage=None):
    _log("connect")
    if conf.identifier != "AA:BB":
        return _Speaker(conf)
    return _Tv()


async def pair(conf, protocol, loop, storage=None, name=None):
    raise exceptions.PairingError("not in the stand-in")

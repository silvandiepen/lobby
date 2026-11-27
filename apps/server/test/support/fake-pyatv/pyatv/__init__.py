# SPDX-License-Identifier: MPL-2.0
"""A stand-in for pyatv in the tests of tools/wake.py: one Apple TV, "AA:BB", that behaves as the
state file says. What it is asked goes to the log file, one JSON line each.

scenario:
  direct  Lobby is in front once it is opened.
  picker  tvOS asks who is watching: Lobby is in front only after select and opening it again.
  never   Lobby never comes to the front.
  blind   pyatv cannot tell which app is in front (as over Companion alone).
"""

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
    model_str = "Apple TV 4K (fake)"
    operating_system = const.OperatingSystem.TvOS


class _Conf:
    identifier = "AA:BB"
    name = "Living Room"
    all_identifiers = ["AA:BB"]
    device_info = _Info()


async def scan(loop, timeout=5, identifier=None, protocol=None, storage=None, hosts=None):
    _log("scan")
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


async def connect(conf, loop, storage=None):
    _log("connect")
    return _Tv()


async def pair(conf, protocol, loop, storage=None, name=None):
    raise exceptions.PairingError("not in the stand-in")

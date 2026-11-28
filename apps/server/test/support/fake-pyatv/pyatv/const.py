# SPDX-License-Identifier: MPL-2.0
"""The parts of pyatv.const that tools/wake.py uses."""

from enum import Enum


class OperatingSystem(Enum):
    Unknown = 0
    TvOS = 3
    MacOS = 4


class Protocol(Enum):
    AirPlay = 3
    Companion = 5
    RAOP = 6


class DeviceModel(Enum):
    Unknown = 0
    Gen4K = 4
    HomePod = 5
    HomePodMini = 6


class PairingRequirement(Enum):
    Unsupported = 1
    Disabled = 2
    NotNeeded = 3
    Optional = 4
    Mandatory = 5


class FeatureName(Enum):
    App = 37


class FeatureState(Enum):
    Unknown = 0
    Unsupported = 1
    Unavailable = 2
    Available = 3

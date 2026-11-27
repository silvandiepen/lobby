# SPDX-License-Identifier: MPL-2.0
"""The parts of pyatv.const that tools/wake.py uses."""

from enum import Enum


class OperatingSystem(Enum):
    Unknown = 0
    TvOS = 3


class Protocol(Enum):
    Companion = 5


class FeatureName(Enum):
    App = 37


class FeatureState(Enum):
    Unknown = 0
    Unsupported = 1
    Unavailable = 2
    Available = 3

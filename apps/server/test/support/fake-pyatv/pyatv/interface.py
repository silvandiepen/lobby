# SPDX-License-Identifier: MPL-2.0
"""The parts of pyatv.interface that tools/wake.py uses."""

from dataclasses import dataclass
from typing import Optional


@dataclass
class MediaMetadata:
    title: Optional[str] = None
    artist: Optional[str] = None
    album: Optional[str] = None
    artwork: Optional[bytes] = None
    duration: Optional[float] = None

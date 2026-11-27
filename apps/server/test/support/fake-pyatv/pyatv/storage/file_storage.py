# SPDX-License-Identifier: MPL-2.0
"""A storage that holds credentials for the stand-in's one TV, "AA:BB", and writes nothing."""


class _Protocol:
    def __init__(self, identifier=None, credentials=None):
        self.identifier = identifier
        self.credentials = credentials


class _Protocols:
    def __init__(self):
        self.airplay = _Protocol()
        self.companion = _Protocol("AA:BB", "fake")
        self.dmap = _Protocol()
        self.mrp = _Protocol()
        self.raop = _Protocol()


class _Settings:
    def __init__(self):
        self.protocols = _Protocols()


class FileStorage:
    def __init__(self, path, loop):
        self.settings = [_Settings()]

    async def load(self):
        pass

    async def save(self):
        pass

    async def remove_settings(self, settings):
        self.settings.remove(settings)

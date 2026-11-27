# SPDX-License-Identifier: MPL-2.0
"""The exceptions of pyatv that tools/wake.py catches."""


class PairingError(Exception):
    pass


class AuthenticationError(Exception):
    pass

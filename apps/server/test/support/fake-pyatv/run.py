# SPDX-License-Identifier: MPL-2.0
"""Runs the real tools/wake.py against the stand-in pyatv beside this file, for the tests.

  python3 -I run.py --fake <state.json> [wake.py's arguments]

The state file says how the Apple TV behaves ("scenario") and where to write what it was asked
("log"). Nothing here reaches a network. The waits of wake.py are made short.
"""

import asyncio
import importlib.util
import os
import sys

# Nothing is written beside the code, tools/wake.py's folder included.
sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

at = sys.argv.index("--fake")
os.environ["LOBBY_FAKE_PYATV"] = sys.argv[at + 1]
del sys.argv[at : at + 2]

script = os.path.join(HERE, "..", "..", "..", "tools", "wake.py")
spec = importlib.util.spec_from_file_location("wake", script)
wake = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wake)
wake.FRONT_SECONDS = 0.6
wake.FRONT_LOOK_SECONDS = 0.1

asyncio.run(wake.main())

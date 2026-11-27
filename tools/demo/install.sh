#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# Puts the App Review demo server on a Linux computer, as its own user, in ~/lobby-demo:
# Lobby Server from a release archive, the open-movie library, and two systemd user services,
# lobby-demo (the server, on 127.0.0.1 only) and lobby-demo-doorman. Opens no port.
#
#   sh tools/demo/install.sh <dist folder with install.sh, SHA256SUMS and the archive> <public address>
#
# <public address> is this computer's own public IPv4 address (the direct connection binds there).
# The archive must have bin/lobby-direct in it, or put one at ~/lobby-demo/server/bin/lobby-direct.
# Then: add the box id it prints to the introducer's BOXES (README.md), and run invites.ts.
set -eu

dist="${1:?the folder with install.sh, SHA256SUMS and lobby-server-<v>-linux-*.tar.xz}"
public="${2:?the public IPv4 address of this computer}"
here="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
root="$HOME/lobby-demo"
introducer="${LOBBY_DEMO_INTRODUCER:-wss://lobby-introducer.vandipyan.workers.dev}"
port="${LOBBY_DEMO_PORT:-8674}"

mkdir -p "$root/tools"
cp "$here"/*.ts "$here/films.json" "$root/tools/"

archive="$(ls "$dist"/lobby-server-*-linux-*.tar.xz | head -n 1)"
(cd "$dist" && sh install.sh --archive "$archive" --prefix "$root/server" --service none)
node="$root/server/runtime/bin/node"

"$node" "$root/tools/library.ts" --media "$root/media" --state "$root/state"

m="$root/media"
cat > "$root/server/lobby.config.json" <<EOF
{
  "serverName": "Lobby Demo",
  "dataDir": "data",
  "host": "127.0.0.1",
  "port": $port,
  "advertise": false,
  "claim": "open",
  "roots": [
    { "path": "$m/Adventure", "name": "Adventure", "hint": "movies" },
    { "path": "$m/Science Fiction", "name": "Science Fiction", "hint": "movies" },
    { "path": "$m/Strange Worlds", "name": "Strange Worlds", "hint": "movies" },
    { "path": "$m/Kids/Funny Animals", "name": "Funny Animals", "hint": "movies", "group": "Kids" }
  ],
  "stabilityMs": 2000,
  "outside": {
    "enabled": true,
    "name": "demo.lobby.hakobs.com",
    "direct": {
      "introducer": "$introducer",
      "stun": [{ "host": "stun.l.google.com", "port": 19302 }],
      "bind": "$public",
      "maxUploadMbit": 50,
      "binary": "bin/lobby-direct"
    }
  }
}
EOF

units="$HOME/.config/systemd/user"
mkdir -p "$units"
cat > "$units/lobby-demo.service" <<'EOF'
[Unit]
Description=Lobby Server, App Review demo (~/lobby-demo)
After=network-online.target

[Service]
WorkingDirectory=%h/lobby-demo/server
ExecStart=%h/lobby-demo/server/bin/lobby serve --config %h/lobby-demo/server/lobby.config.json
Restart=on-failure
RestartForceExitStatus=75
StandardOutput=append:%h/lobby-demo/server/server.log
StandardError=append:%h/lobby-demo/server/server.log
Nice=10

[Install]
WantedBy=default.target
EOF
cat > "$units/lobby-demo-doorman.service" <<'EOF'
[Unit]
Description=Lobby demo doorman: approves App Review invitations (~/lobby-demo)
After=lobby-demo.service
Requires=lobby-demo.service

[Service]
WorkingDirectory=%h/lobby-demo
ExecStart=%h/lobby-demo/server/runtime/bin/node %h/lobby-demo/tools/doorman.ts --state %h/lobby-demo/state
Restart=always
RestartSec=5
StandardOutput=append:%h/lobby-demo/doorman.log
StandardError=append:%h/lobby-demo/doorman.log

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now lobby-demo.service
sleep 8
"$node" "$root/tools/setup.ts" --server "http://127.0.0.1:$port" --state "$root/state"
systemctl --user enable --now lobby-demo-doorman.service

echo "The box id for the introducer's BOXES:"
"$root/server/bin/lobby" direct id --config "$root/server/lobby.config.json"

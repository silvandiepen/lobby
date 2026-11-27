#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# Starts Lobby Server in its container. Makes a config in /lobby the first time, and never again.
set -eu

config="${LOBBY_CONFIG:-/lobby/lobby.config.json}"
if [ ! -e "$config" ]; then
  # No folders: a manager picks them in the app's first setup, from what is mounted.
  node -e '
    const [path, serverName, port] = process.argv.slice(1);
    const config = { serverName, dataDir: "data", host: "0.0.0.0", port: Number(port) };
    require("node:fs").writeFileSync(path, JSON.stringify(config, null, 2) + "\n", { flag: "wx", mode: 0o600 });
  ' "$config" "${LOBBY_NAME:-Lobby}" "${LOBBY_PORT:-8674}"
  echo "Wrote $config. Edit it there; the settings managers change in the app are in data/settings."
fi
exec node /opt/lobby/app/src/cli.ts "$@" --config "$config"

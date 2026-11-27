#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# The `lobby` command of an installed Lobby Server (bin/lobby in a release archive).
#
# Runs the server's own command (`lobby help`) with the private Node in runtime/, and the config
# beside it. `lobby update` and `lobby uninstall` are the installer's, which is kept in installer/.
set -eu

# Where this file really is, also through a link such as ~/.local/bin/lobby.
self="$0"
while [ -L "$self" ]; do
  target="$(readlink "$self")"
  case "$target" in
    /*) self="$target" ;;
    *) self="$(dirname -- "$self")/$target" ;;
  esac
done
home="$(CDPATH='' cd -- "$(dirname -- "$self")/.." && pwd)"

case "${1:-}" in
  update | uninstall)
    exec sh "$home/installer/install.sh" "$@" --prefix "$home"
    ;;
  version | --version)
    cat "$home/VERSION"
    exit 0
    ;;
esac

LOBBY_CONFIG="${LOBBY_CONFIG:-$home/lobby.config.json}"
export LOBBY_CONFIG
exec "$home/runtime/bin/node" "$home/app/src/cli.ts" "$@"

#!/bin/zsh
# SPDX-License-Identifier: MPL-2.0
# Copies Lobby Server to the Pi and installs its production dependencies there.
#
#   tools/deploy-pi.sh <user@host>        or   LOBBY_HOST=<user@host> tools/deploy-pi.sh
#
# For a Raspberry Pi (Linux arm64) you reach over SSH with a key. There is no default host.
#
# It writes only to ~/lobby on the Pi (the system disk). It never touches the media drive,
# other services, or system packages. Node is a private copy in ~/lobby/runtime, fetched once.
# A release archive with install.sh (docs/release.md) is the supported way to install; this is
# for trying a working tree on a Pi.
set -euo pipefail

HOST="${1:-${LOBBY_HOST:-}}"
[[ -n "$HOST" ]] || { echo "Usage: $0 <user@host> (or set LOBBY_HOST)" >&2; exit 64; }
REPO="$(cd "$(dirname "$0")/.." && pwd)"
# The Node the release archives carry (tools/release/node-runtime.json), so both stay the same.
NODE_VERSION="$(sed -n 's/^ *"version": *"\(v[^"]*\)".*/\1/p' "$REPO/tools/release/node-runtime.json")"
[[ -n "$NODE_VERSION" ]] || { echo "No Node version in tools/release/node-runtime.json" >&2; exit 1; }

ssh -o BatchMode=yes "$HOST" "mkdir -p ~/lobby/app ~/lobby/data ~/lobby/runtime"

# A private Node for the service, so nothing on the Pi's system changes.
ssh -o BatchMode=yes "$HOST" "
  set -e
  if [ ! -x ~/lobby/runtime/bin/node ] || [ \"\$(~/lobby/runtime/bin/node -v)\" != '$NODE_VERSION' ]; then
    cd ~/lobby && curl -fsSLO https://nodejs.org/dist/$NODE_VERSION/node-$NODE_VERSION-linux-arm64.tar.xz
    curl -fsSL https://nodejs.org/dist/$NODE_VERSION/SHASUMS256.txt | grep node-$NODE_VERSION-linux-arm64.tar.xz | sha256sum -c -
    rm -rf runtime && mkdir runtime && tar -xJf node-$NODE_VERSION-linux-arm64.tar.xz -C runtime --strip-components=1
    rm node-$NODE_VERSION-linux-arm64.tar.xz
  fi
  ~/lobby/runtime/bin/node -v
"

rsync -az --delete \
  --exclude node_modules --exclude data --exclude test \
  "$REPO/apps/server/" "${HOST}:lobby/app/"

ssh -o BatchMode=yes "$HOST" "
  set -e
  cd ~/lobby/app
  PATH=~/lobby/runtime/bin:\$PATH npm install --omit=dev --no-audit --no-fund 2>&1 | tail -2
"
echo "Deployed to $HOST:~/lobby/app"

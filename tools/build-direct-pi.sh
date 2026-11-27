#!/bin/zsh
# SPDX-License-Identifier: MPL-2.0
# Builds lobby-direct on the Pi, in a container that is thrown away, and puts it in ~/lobby/bin.
#
#   tools/build-direct-pi.sh <user@host>        or   LOBBY_HOST=<user@host> tools/build-direct-pi.sh
#
# For a Raspberry Pi (Linux arm64) you reach over SSH with a key. There is no default host.
#
# A static musl program, from the sources and the lock file here, with the compiler that is named
# below: the same sources give the same bytes, and the checksum is printed to compare. It takes two
# of the Pi's cores at low priority for some minutes, about 1.5 GB of disk while it runs, and
# leaves the program and nothing else. The image is removed unless it was there before.
set -euo pipefail

HOST="${1:-${LOBBY_HOST:-}}"
[[ -n "$HOST" ]] || { echo "Usage: $0 <user@host> (or set LOBBY_HOST)" >&2; exit 64; }
IMAGE="rust:1.90-alpine3.22@sha256:b4b54b176a74db7e5c68fdfe6029be39a02ccbcfe72b6e5a3e18e2c61b57ae26"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

rsync -az --delete --exclude target "$REPO/apps/direct/" "${HOST}:lobby/build-direct/"
ssh -o BatchMode=yes "$HOST" "
  set -eu
  cd ~/lobby
  free=\$(df --output=avail -k . | tail -1)
  [ \"\$free\" -gt 3000000 ] || { echo 'Less than 3 GB free on the Pi.' >&2; exit 1; }
  had=\$(docker images -q '$IMAGE')
  trap 'rm -rf ~/lobby/build-direct; [ -n \"\$had\" ] || docker rmi \"$IMAGE\" >/dev/null 2>&1 || true' EXIT
  mkdir -p bin build-direct/out
  docker run --rm --cpus 2 --memory 2g --cpu-shares 128 \
    -v ~/lobby/build-direct:/src:ro -v ~/lobby/build-direct/out:/out \
    -e CARGO_TARGET_DIR=/build -e CARGO_HOME=/cargo -e SOURCE_DATE_EPOCH=0 \
    -e RUSTFLAGS='-C target-feature=+crt-static --remap-path-prefix=/cargo=cargo --remap-path-prefix=/src=src' \
    '$IMAGE' sh -c '
      set -eu
      apk add --no-cache musl-dev gcc >/dev/null
      cd /src
      nice -n 19 cargo test --release --locked --lib
      nice -n 19 cargo build --release --locked --bin lobby-direct
      cp /build/release/lobby-direct /out/ && chown \$(stat -c %u:%g /out) /out/lobby-direct'
  install -m 0755 build-direct/out/lobby-direct bin/lobby-direct.new
  mv bin/lobby-direct.new bin/lobby-direct
  sha256sum bin/lobby-direct
"
echo "Built. Lobby Server starts it when outside.direct is in the config and the entrance is on."

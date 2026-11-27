#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# Builds lobby-direct (apps/direct) for one release platform.
#
#   tools/release/build-direct.sh <platform> <output file>
#
# platform: linux-arm64, linux-x64, macos-arm64 or macos-x64.
#
# - Linux: a static musl program, built in a throw-away container from the pinned Rust image below
#   (the one tools/build-direct-pi.sh uses), so it runs on any distribution. Needs Docker. The
#   container's architecture is the platform's; on another one Docker needs QEMU (binfmt), which is
#   slow: build on a machine of that architecture where possible.
# - macOS: with rustup's toolchain named below and its target for the platform
#   (`rustup target add --toolchain 1.90.0 x86_64-apple-darwin`). Builds on a Mac only.
#
# The same sources and lock file give the same bytes on Linux; the checksum is printed. Exits 3,
# changing nothing, when the toolchain for the platform is not on this machine.
set -eu

IMAGE="rust:1.90-alpine3.22@sha256:b4b54b176a74db7e5c68fdfe6029be39a02ccbcfe72b6e5a3e18e2c61b57ae26"
TOOLCHAIN="1.90.0"
# Node 24 itself needs macOS 13.5.
MACOS_MIN="13.5"

platform="${1:-}"
out="${2:-}"
if [ -z "$platform" ] || [ -z "$out" ]; then
  echo "Usage: $0 <linux-arm64|linux-x64|macos-arm64|macos-x64> <output file>" >&2
  exit 2
fi
repo="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
cache="${LOBBY_RELEASE_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/lobby-release}"
mkdir -p "$(dirname -- "$out")"

missing() {
  echo "lobby-direct for $platform: $1" >&2
  exit 3
}

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi
}

case "$platform" in
  linux-arm64 | linux-x64)
    [ "$platform" = linux-arm64 ] && arch=linux/arm64 || arch=linux/amd64
    [ "$platform" = linux-arm64 ] && triple=aarch64-unknown-linux-musl || triple=x86_64-unknown-linux-musl
    docker info >/dev/null 2>&1 || missing "needs Docker, which is not running here."
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT
    # Only what the build reads: no target folder.
    (cd "$repo/apps/direct" && tar -cf - --exclude ./target .) | (cd "$work" && mkdir src out && tar -xf - -C src)
    docker run --rm --platform "$arch" \
      -v "$work/src:/src:ro" -v "$work/out:/out" \
      -e CARGO_TARGET_DIR=/build -e CARGO_HOME=/cargo -e SOURCE_DATE_EPOCH=0 \
      -e RUSTFLAGS='-C target-feature=+crt-static --remap-path-prefix=/cargo=cargo --remap-path-prefix=/src=src' \
      -e TRIPLE="$triple" \
      "$IMAGE" sh -c '
        set -eu
        apk add --no-cache musl-dev gcc >/dev/null
        cd /src
        # An explicit --target keeps RUSTFLAGS (crt-static) off the host: without it a
        # proc-macro dependency (thiserror-impl) cannot be built on a musl host.
        cargo build --release --locked --bin lobby-direct --target "$TRIPLE"
        cp "/build/$TRIPLE/release/lobby-direct" /out/ && chown "$(stat -c %u:%g /out)" /out/lobby-direct'
    install -m 0755 "$work/out/lobby-direct" "$out"
    ;;
  macos-arm64 | macos-x64)
    [ "$(uname -s)" = Darwin ] || missing "builds on a Mac only."
    [ "$platform" = macos-arm64 ] && triple=aarch64-apple-darwin || triple=x86_64-apple-darwin
    command -v rustup >/dev/null 2>&1 || missing "needs rustup (https://rustup.rs)."
    rustup run "$TOOLCHAIN" rustc --version >/dev/null 2>&1 ||
      missing "needs the Rust toolchain $TOOLCHAIN: rustup toolchain install $TOOLCHAIN"
    rustup target list --installed --toolchain "$TOOLCHAIN" | grep -qx "$triple" ||
      missing "needs its target: rustup target add --toolchain $TOOLCHAIN $triple"
    cargo_home="${CARGO_HOME:-$HOME/.cargo}"
    # `rustup run` puts the toolchain behind a cargo and rustc found earlier on PATH (Homebrew's):
    # put the pinned toolchain's own folder first, so its compiler and its targets are used.
    toolchain_bin="$(dirname -- "$(rustup which --toolchain "$TOOLCHAIN" cargo)")"
    PATH="$toolchain_bin:$PATH" \
      CARGO_TARGET_DIR="$cache/direct-target" \
      MACOSX_DEPLOYMENT_TARGET="$MACOS_MIN" \
      SOURCE_DATE_EPOCH=0 \
      RUSTFLAGS="--remap-path-prefix=$cargo_home=cargo --remap-path-prefix=$repo/apps/direct=src" \
      cargo build --release --locked --bin lobby-direct \
      --target "$triple" --manifest-path "$repo/apps/direct/Cargo.toml"
    install -m 0755 "$cache/direct-target/$triple/release/lobby-direct" "$out"
    ;;
  *)
    echo "Unknown platform: $platform" >&2
    exit 2
    ;;
esac
sha256 "$out"

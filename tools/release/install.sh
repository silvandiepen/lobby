#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# Installs Lobby Server on a Linux computer or a Mac, updates it, and removes it.
#
#   sh install.sh [options]              Install the newest release in ~/lobby.
#   sh install.sh update [options]       The same as `lobby update`.
#   sh install.sh uninstall [options]    The same as `lobby uninstall`.
#   sh install.sh help
#
# What it does, so that you can check before you run it:
#
# - It runs as you, not as root, and writes only to its folder (~/lobby unless --prefix says
#   otherwise) and to one service file: ~/.config/systemd/user/lobby.service on Linux, or
#   ~/Library/LaunchAgents/lobby.server.plist on a Mac. With `--service system` it asks for sudo
#   to write /etc/systemd/system/lobby.service or /Library/LaunchDaemons/lobby.server.plist instead.
# - It downloads one archive and its checksum file, and refuses an archive whose SHA-256 does not
#   match. It installs no system packages: it checks for ffmpeg and says how to get it.
# - It never overwrites the data folder or the config. An update first makes a backup of the
#   catalogue, and keeps the version it replaced in .previous/. Uninstalling keeps the data folder
#   and the config unless you ask for them to go (--delete-data).
#
# The folder it makes:
#
#   app/                 Lobby Server and its dependencies
#   runtime/             a private Node.js, used by nothing else
#   bin/lobby            the command (bin/lobby-direct: the direct connection's helper, if any)
#   installer/           this script, for `lobby update` and `lobby uninstall`
#   lobby.config.json    what the server starts from (made once, then yours)
#   data/                the catalogue, settings, secrets and backups
#   server.log           what the server says
set -eu

# Where releases are found: this repository's GitHub Releases. A release archive carries the
# address its build was given (build.ts --releases), which is the same for official releases.
RELEASES_DEFAULT="https://github.com/silvandiepen/lobby/releases"
LABEL="lobby.server"
UNIT="lobby"
MARKER="Written by Lobby's install.sh"

say() { printf '%s\n' "$*"; }
warn() { printf 'Note: %s\n' "$*" >&2; }
die() {
  printf 'Lobby: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Lobby Server installer

  sh install.sh [install] [options]   Install Lobby Server.
  sh install.sh update [options]      Install a newer release over an installed one.
  sh install.sh uninstall [options]   Remove the program and its service. Keeps the data.

Options:
  --prefix <dir>        Where Lobby lives. Default: ~/lobby ($LOBBY_HOME).
  --version <x.y.z>     A release to install. Default: the newest.
  --archive <file>      Install from an archive that is already here, instead of downloading.
  --sums <file>         The SHA256SUMS file for --archive. Default: SHA256SUMS beside it.
  --sha256 <hash>       Or the archive's SHA-256 itself.
  --releases <url>      Where releases are published ($LOBBY_RELEASES).
  --service <kind>      auto (default), user, system or none. user: a systemd user service, or
                        a launchd agent on a Mac. system: a system service that runs as you, for
                        a computer nobody logs in to; needs sudo. none: start it yourself.
  --no-start            Write the service but do not start it.
  --name <name>         The server's name in the apps, for a new config. Default: Lobby.
  --port <port>         The port, for a new config. Default: 8674.
  --host <address>      The address to listen on, for a new config. Default: 0.0.0.0, every
                        network of this computer.
  --force               update: also install the same or an older version.
  --no-backup           update: do not back the catalogue up first.
  --delete-data         uninstall: also delete the data folder, the config and the log.
  --yes                 uninstall: do not ask before deleting the data.
EOF
}

# ---- Small, separate pieces (also used by the tests) ----

# The release platform for `uname -s` and `uname -m`, or nothing for one without a release.
platform_of() {
  case "$1" in
    Linux) p_os=linux ;;
    Darwin) p_os=macos ;;
    *) return 1 ;;
  esac
  case "$2" in
    aarch64 | arm64) p_arch=arm64 ;;
    x86_64 | amd64) p_arch=x64 ;;
    *) return 1 ;;
  esac
  printf '%s-%s\n' "$p_os" "$p_arch"
}

# This computer's platform, with the cases uname gets wrong.
this_platform() {
  t_os="$(uname -s)"
  t_machine="$(uname -m)"
  # A shell under Rosetta on an Apple silicon Mac says x86_64.
  if [ "$t_os" = Darwin ] && [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = 1 ]; then
    t_machine=arm64
  fi
  # A 64-bit kernel with a 32-bit system, such as the 32-bit Raspberry Pi OS.
  if [ "$t_os" = Linux ] && [ "$(getconf LONG_BIT 2>/dev/null || echo 64)" = 32 ]; then
    die "this is a 32-bit system ($t_machine). Lobby needs a 64-bit one: on a Raspberry Pi, the 64-bit Raspberry Pi OS. Or use the Docker image."
  fi
  platform_of "$t_os" "$t_machine" ||
    die "there is no Lobby Server for $t_os on $t_machine. Releases exist for Linux and macOS on arm64 and x86_64."
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d ' ' -f 1
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$1" | sed 's/^.*= *//'
  else
    die "no sha256sum, shasum or openssl to check the download with."
  fi
}

# The archive's name in a SHA256SUMS file for a platform: "<hash> <name>".
sums_entry() {
  grep -E "^[0-9a-f]{64}  \\*?lobby-server-[0-9A-Za-z.+-]+-$2\\.tar\\.xz\$" "$1" | head -n 1 |
    sed 's/  \*\{0,1\}/ /'
}

# 0 when version $1 is older than $2. Only the x.y.z part counts.
older_than() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    split(a, x, /[.+-]/); split(b, y, /[.+-]/)
    for (i = 1; i <= 3; i++) { if (x[i] + 0 < y[i] + 0) exit 0; if (x[i] + 0 > y[i] + 0) exit 1 }
    exit 1
  }'
}

# How to get ffmpeg here, as one line.
ffmpeg_hint() {
  if [ "$(uname -s)" = Darwin ]; then
    say "brew install ffmpeg   (Homebrew: https://brew.sh)"
    return
  fi
  h_ids=""
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    h_ids="$(. /etc/os-release && printf '%s %s' "${ID:-}" "${ID_LIKE:-}")"
  fi
  case " $h_ids " in
    *" debian "* | *" ubuntu "* | *" raspbian "*) say "sudo apt install ffmpeg" ;;
    *" fedora "*) say "sudo dnf install ffmpeg-free   (or ffmpeg from RPM Fusion)" ;;
    *" rhel "* | *" centos "*) say "enable EPEL and RPM Fusion, then: sudo dnf install ffmpeg" ;;
    *" arch "*) say "sudo pacman -S ffmpeg" ;;
    *" suse "* | *" opensuse "*) say "sudo zypper install ffmpeg" ;;
    *" alpine "*) say "sudo apk add ffmpeg" ;;
    *" void "*) say "sudo xbps-install ffmpeg" ;;
    *" gentoo "*) say "sudo emerge media-video/ffmpeg" ;;
    *" nixos "*) say "add ffmpeg to environment.systemPackages" ;;
    *) say "install ffmpeg (with ffprobe) with your system's package manager" ;;
  esac
}

# A folder for PATH in the service: where ffmpeg is, and the usual ones.
service_path() {
  s_path="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  [ "$(uname -s)" = Darwin ] && s_path="/opt/homebrew/bin:$s_path"
  if s_ffmpeg="$(command -v ffmpeg 2>/dev/null)"; then
    s_dir="$(dirname -- "$s_ffmpeg")"
    case ":$s_path:" in
      *":$s_dir:"*) ;;
      *) s_path="$s_dir:$s_path" ;;
    esac
  fi
  printf '%s\n' "$s_path"
}

systemd_unit() { # prefix kind path
  cat <<EOF
# $MARKER. \`lobby uninstall\` removes it.
[Unit]
Description=Lobby Server
EOF
  if [ "$2" = system ]; then
    printf '%s\n' "After=network-online.target" "Wants=network-online.target"
  fi
  cat <<EOF
StartLimitIntervalSec=0

[Service]
Type=simple
WorkingDirectory="$1"
Environment="LOBBY_CONFIG=$1/lobby.config.json"
Environment="PATH=$3"
EOF
  if [ "$2" = system ]; then
    printf 'User=%s\nGroup=%s\nNoNewPrivileges=true\nPrivateTmp=true\n' "$(id -un)" "$(id -gn)"
  else
    # A user's services can start before the network at boot; the announcement needs it.
    cat <<'EOF'
ExecStartPre=/bin/sh -c 'command -v ip >/dev/null 2>&1 || exit 0; i=0; while [ $$i -lt 60 ]; do ip -4 route show default | grep -q . && exit 0; sleep 1; i=$$((i + 1)); done; exit 0'
EOF
  fi
  cat <<EOF
ExecStart="$1/bin/lobby" serve
Restart=always
RestartSec=3
# 75: the server stopped itself to take new settings from the app; start it again.
RestartForceExitStatus=75
TimeoutStartSec=90
TimeoutStopSec=30
Nice=5
StandardOutput=append:$1/server.log
StandardError=append:$1/server.log

[Install]
WantedBy=$([ "$2" = system ] && echo multi-user.target || echo default.target)
EOF
}

launchd_plist() { # prefix kind path
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- $MARKER. \`lobby uninstall\` removes it. -->
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$1/bin/lobby</string>
    <string>serve</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$1</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>LOBBY_CONFIG</key>
    <string>$1/lobby.config.json</string>
    <!-- The server exits with 75 to take new settings; launchd starts it again. -->
    <key>LOBBY_SUPERVISED</key>
    <string>1</string>
    <key>PATH</key>
    <string>$3</string>
  </dict>
EOF
  if [ "$2" = system ]; then
    printf '  <key>UserName</key>\n  <string>%s</string>\n' "$(id -un)"
  fi
  cat <<EOF
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>3</integer>
  <key>Nice</key>
  <integer>5</integer>
  <key>StandardOutPath</key>
  <string>$1/server.log</string>
  <key>StandardErrorPath</key>
  <string>$1/server.log</string>
</dict>
</plist>
EOF
}

# The file a service of this kind lives in.
service_file() {
  if [ "$(uname -s)" = Darwin ]; then
    case "$1" in
      user) printf '%s\n' "$HOME/Library/LaunchAgents/$LABEL.plist" ;;
      system) printf '%s\n' "/Library/LaunchDaemons/$LABEL.plist" ;;
    esac
  else
    case "$1" in
      user) printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$UNIT.service" ;;
      system) printf '%s\n' "/etc/systemd/system/$UNIT.service" ;;
    esac
  fi
}

if [ "${LOBBY_INSTALL_LIB:-}" = 1 ]; then
  # Sourced by the tests for the pieces above.
  return 0
fi

# ---- Options ----

command_name=install
case "${1:-}" in
  install | update | uninstall)
    command_name="$1"
    shift
    ;;
  help | -h | --help)
    usage
    exit 0
    ;;
esac

prefix="${LOBBY_HOME:-$HOME/lobby}"
version=""
archive=""
sums=""
sha=""
releases="${LOBBY_RELEASES:-$RELEASES_DEFAULT}"
service=auto
start=yes
name="Lobby"
port=8674
host="0.0.0.0"
force=no
backup=yes
delete_data=no
assume_yes=no

need_value() {
  [ $# -ge 2 ] && [ -n "$2" ] || die "$1 needs a value. See: sh install.sh help"
}
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) need_value "$@"; prefix="$2"; shift 2 ;;
    --version) need_value "$@"; version="${2#v}"; shift 2 ;;
    --archive) need_value "$@"; archive="$2"; shift 2 ;;
    --sums) need_value "$@"; sums="$2"; shift 2 ;;
    --sha256) need_value "$@"; sha="$2"; shift 2 ;;
    --releases) need_value "$@"; releases="$2"; shift 2 ;;
    --service) need_value "$@"; service="$2"; shift 2 ;;
    --no-start) start=no; shift ;;
    --name) need_value "$@"; name="$2"; shift 2 ;;
    --port) need_value "$@"; port="$2"; shift 2 ;;
    --host) need_value "$@"; host="$2"; shift 2 ;;
    --force) force=yes; shift ;;
    --no-backup) backup=no; shift ;;
    --delete-data) delete_data=yes; shift ;;
    --yes | -y) assume_yes=yes; shift ;;
    *) die "unknown option $1. See: sh install.sh help" ;;
  esac
done

case "$service" in
  auto | user | system | none) ;;
  *) die "--service is auto, user, system or none." ;;
esac
case "$port" in
  '' | *[!0-9]*) die "--port must be a number." ;;
esac
[ "$port" -ge 1 ] && [ "$port" -le 65535 ] || die "--port must be from 1 to 65535."

[ "$(id -u)" -ne 0 ] ||
  die "run this as the user Lobby should run as, not as root. It asks for sudo itself where it must (--service system). For a NAS that runs everything as root, the Docker image is the better fit."

case "$prefix" in
  /*) ;;
  *) prefix="$(pwd)/$prefix" ;;
esac
prefix="${prefix%/}"
# shellcheck disable=SC1003
case "$prefix" in
  *'"'* | *'\'* | *'%'* | *'$'* | *'`'* | *'&'* | *'<'* | *'>'*)
    die "the folder name must not hold any of \" \\ % \$ \` & < >."
    ;;
esac
[ -n "$prefix" ] && [ "$prefix" != "$HOME" ] && [ "$prefix" != / ] ||
  die "--prefix must be a folder of Lobby's own, such as ~/lobby."

os="$(uname -s)"
platform="$(this_platform)"
work=""
lock=""
made_prefix=no
cleanup() {
  [ -z "$work" ] || rm -rf "$work"
  # Half an unpacked archive is no use to anyone.
  rm -rf "${prefix:?}/.incoming"
  [ -z "$lock" ] || rmdir "$lock" 2>/dev/null || true
  [ "$made_prefix" = no ] || rmdir "$prefix" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT TERM

take_lock() {
  [ -d "$prefix" ] || made_prefix=yes
  mkdir -p "$prefix"
  lock="$prefix/.installing"
  mkdir "$lock" 2>/dev/null || {
    lock=""
    die "another install, update or uninstall is running in $prefix (or one stopped halfway: remove $prefix/.installing if none is)."
  }
}

# ---- Getting and checking an archive ----

download() { # url file
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --proto '=https' --proto-redir '=https' --retry 2 -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$2" "$1"
  else
    die "no curl or wget to download with."
  fi
}

# Sets $archive and $sha: downloaded, or the ones given.
fetch_archive() {
  work="$(mktemp -d "${TMPDIR:-/tmp}/lobby-install.XXXXXX")"
  if [ -n "$archive" ]; then
    [ -f "$archive" ] || die "there is no archive at $archive."
    archive="$(CDPATH='' cd -- "$(dirname -- "$archive")" && pwd)/$(basename -- "$archive")"
    if [ -z "$sha" ]; then
      [ -n "$sums" ] || sums="$(dirname -- "$archive")/SHA256SUMS"
      [ -f "$sums" ] || die "no checksum for the archive: pass --sums <SHA256SUMS> or --sha256 <hash>."
      f_name="$(basename -- "$archive")"
      sha="$(grep -E "  \\*?$f_name\$" "$sums" | head -n 1 | cut -d ' ' -f 1)"
      [ -n "$sha" ] || die "$sums has no line for $f_name."
    fi
    return
  fi
  [ -n "$releases" ] ||
    die "this copy of the installer does not know where releases are. Download the archive and pass --archive, or pass --releases <url>."
  releases="${releases%/}"
  if [ -n "$version" ]; then
    f_base="$releases/download/v$version"
  else
    f_base="$releases/latest/download"
  fi
  say "Looking for the release for $platform..."
  download "$f_base/SHA256SUMS" "$work/SHA256SUMS" ||
    die "could not download $f_base/SHA256SUMS."
  f_entry="$(sums_entry "$work/SHA256SUMS" "$platform")"
  [ -n "$f_entry" ] || die "the release has no archive for $platform."
  sha="${f_entry%% *}"
  f_name="${f_entry#* }"
  say "Downloading $f_name..."
  download "$f_base/$f_name" "$work/$f_name" || die "could not download $f_base/$f_name."
  archive="$work/$f_name"
}

# Checks and unpacks the archive into $prefix/.incoming, and sets $new and $new_version.
unpack() {
  case "$sha" in
    *[!0-9a-f]* | '') die "the checksum must be 64 hexadecimal digits." ;;
  esac
  [ "${#sha}" -eq 64 ] || die "the checksum must be 64 hexadecimal digits."
  u_actual="$(sha256_of "$archive")"
  [ "$u_actual" = "$sha" ] ||
    die "the archive's SHA-256 is $u_actual, not $sha. It was not installed. Download it again."
  say "Checksum matches: $sha"
  if [ "$os" = Linux ] && ! command -v xz >/dev/null 2>&1; then
    die "unpacking needs xz. $(
      if command -v apt-get >/dev/null 2>&1; then echo "sudo apt install xz-utils"; else echo "Install xz with your package manager."; fi
    )"
  fi
  rm -rf "$prefix/.incoming"
  mkdir "$prefix/.incoming"
  (cd "$prefix/.incoming" && tar -xJf "$archive") || die "the archive could not be unpacked."
  set -- "$prefix/.incoming"/lobby-server-*
  [ $# -eq 1 ] && [ -d "$1" ] || die "this is not a Lobby Server archive."
  new="$1"
  case "$(basename -- "$new")" in
    *-"$platform") ;;
    *) die "this archive is for another computer: $(basename -- "$new"), and this is $platform." ;;
  esac
  for u_part in app/src/cli.ts runtime/bin/node bin/lobby installer/install.sh VERSION; do
    [ -e "$new/$u_part" ] || die "the archive has no $u_part."
  done
  new_version="$(cat "$new/VERSION")"
  if ! u_node="$("$new/runtime/bin/node" --version 2>&1)"; then
    if [ "$os" = Linux ]; then
      die "its Node.js does not run here ($u_node). It needs glibc 2.28 or later (Debian 10, Ubuntu 20.04, Raspberry Pi OS 64-bit, and newer); on Alpine and other musl systems use the Docker image."
    fi
    die "its Node.js does not run here: $u_node (macOS 13.5 or later is needed)."
  fi
}

# ---- Services ----

installed_service() {
  if [ -f "$prefix/.service" ]; then
    cat "$prefix/.service"
    return
  fi
  # Installed before the installer existed, or by hand.
  for i_kind in user system; do
    i_file="$(service_file "$i_kind")"
    if [ -f "$i_file" ]; then
      printf '%s\n' "$i_kind"
      return
    fi
  done
  printf 'none\n'
}

systemd_user_works() {
  command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1
}

choose_service() {
  [ "$service" = auto ] || return 0
  if [ "$os" = Darwin ]; then
    service=user
  elif systemd_user_works; then
    service=user
  elif command -v systemctl >/dev/null 2>&1; then
    warn "systemd has no session of yours here (as over some SSH logins). No service was installed; run the installer with --service system to have one that starts at boot, or log in and run it again."
    service=none
  else
    warn "this system has no systemd. No service was installed: start \"$prefix/bin/lobby serve\" with your system's own way of starting services."
    service=none
  fi
}

as_root() {
  command -v sudo >/dev/null 2>&1 || die "--service system needs sudo."
  sudo "$@"
}

write_service() { # kind
  w_file="$(service_file "$1")"
  w_path="$(service_path)"
  if [ -f "$w_file" ] && ! grep -q "$MARKER" "$w_file"; then
    say "Kept the service in $w_file: it was not written by this installer."
    return
  fi
  if [ "$os" = Darwin ]; then
    w_text="$(launchd_plist "$prefix" "$1" "$w_path")"
  else
    w_text="$(systemd_unit "$prefix" "$1" "$w_path")"
  fi
  if [ "$1" = system ]; then
    say "Writing $w_file with sudo: a service that starts at boot and runs as $(id -un)."
    printf '%s\n' "$w_text" | as_root tee "$w_file" >/dev/null
    as_root chmod 0644 "$w_file"
  else
    mkdir -p "$(dirname -- "$w_file")"
    printf '%s\n' "$w_text" >"$w_file"
  fi
  printf '%s\n' "$1" >"$prefix/.service"
}

start_service() { # kind
  case "$os:$1" in
    Linux:user)
      systemctl --user daemon-reload
      systemctl --user enable "$UNIT" >/dev/null 2>&1
      systemctl --user restart "$UNIT"
      if [ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null || true)" != yes ]; then
        warn "as it is, Lobby runs only while you are logged in. To have it start at boot and keep running: sudo loginctl enable-linger $(id -un)"
      fi
      ;;
    Linux:system)
      as_root systemctl daemon-reload
      as_root systemctl enable "$UNIT" >/dev/null 2>&1
      as_root systemctl restart "$UNIT"
      ;;
    Darwin:user)
      s_domain="gui/$(id -u)"
      launchctl bootout "$s_domain/$LABEL" >/dev/null 2>&1 || true
      launchctl bootstrap "$s_domain" "$(service_file user)" ||
        warn "launchd could not start Lobby: an agent needs you to be logged in on this Mac. Log in and run \"lobby update --force\", or use --service system for a Mac that nobody logs in to."
      ;;
    Darwin:system)
      as_root launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
      as_root launchctl bootstrap system "$(service_file system)"
      ;;
  esac
}

stop_service() { # kind
  case "$os:$1" in
    Linux:user) systemctl --user stop "$UNIT" 2>/dev/null || true ;;
    Linux:system) as_root systemctl stop "$UNIT" || true ;;
    Darwin:user) launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true ;;
    Darwin:system) as_root launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true ;;
  esac
}

remove_service() { # kind
  r_file="$(service_file "$1")"
  [ -n "$r_file" ] && [ -f "$r_file" ] || return 0
  if ! grep -q "$MARKER" "$r_file"; then
    say "Left $r_file alone: it was not written by this installer. Stop and remove it yourself."
    return
  fi
  stop_service "$1"
  case "$os:$1" in
    Linux:user)
      systemctl --user disable "$UNIT" >/dev/null 2>&1 || true
      rm -f "$r_file"
      systemctl --user daemon-reload 2>/dev/null || true
      ;;
    Linux:system)
      as_root systemctl disable "$UNIT" >/dev/null 2>&1 || true
      as_root rm -f "$r_file"
      as_root systemctl daemon-reload || true
      ;;
    Darwin:user) rm -f "$r_file" ;;
    Darwin:system) as_root rm -f "$r_file" ;;
  esac
  say "Removed the service ($r_file)."
}

# ---- Config and checks ----

node_here() { "$prefix/runtime/bin/node" "$@"; }

write_config() {
  if [ -e "$prefix/lobby.config.json" ]; then
    say "Kept the config: $prefix/lobby.config.json"
    return
  fi
  # No folders: a manager picks them in the app's first setup. "wx": never over an existing file.
  node_here -e '
    const [path, serverName, host, port] = process.argv.slice(1);
    const config = { serverName, dataDir: "data", host, port: Number(port) };
    require("node:fs").writeFileSync(path, JSON.stringify(config, null, 2) + "\n", { flag: "wx", mode: 0o600 });
  ' "$prefix/lobby.config.json" "$name" "$host" "$port"
  say "Wrote the config: $prefix/lobby.config.json"
}

config_value() { # key default
  node_here -e '
    const [path, key, fallback] = process.argv.slice(1);
    let value;
    try { value = JSON.parse(require("node:fs").readFileSync(path, "utf8"))[key]; } catch {}
    console.log(value ?? fallback);
  ' "$prefix/lobby.config.json" "$1" "$2"
}

data_dir() {
  node_here -e '
    const { resolve, dirname, join } = require("node:path");
    const path = process.argv[1];
    let dir;
    try { dir = JSON.parse(require("node:fs").readFileSync(path, "utf8")).dataDir; } catch {}
    console.log(typeof dir === "string" && dir !== "" ? resolve(dirname(path), dir) : join(dirname(path), "data"));
  ' "$prefix/lobby.config.json"
}

check_ffmpeg() {
  c_missing=""
  command -v ffmpeg >/dev/null 2>&1 || c_missing="ffmpeg"
  command -v ffprobe >/dev/null 2>&1 || c_missing="${c_missing:+$c_missing and }ffprobe"
  if [ -n "$c_missing" ]; then
    warn "Lobby needs ffmpeg and ffprobe to read and play films, and $c_missing is not here. Install it, then restart Lobby: $(ffmpeg_hint)"
  fi
}

# Waits up to $1 seconds for the server to answer.
server_answers() {
  a_host="$(config_value host 127.0.0.1)"
  case "$a_host" in 0.0.0.0 | :: | '') a_host=127.0.0.1 ;; esac
  case "$a_host" in *:*) a_host="[$a_host]" ;; esac
  a_url="http://$a_host:$(config_value port 8674)/v1/server"
  a_left="$1"
  while [ "$a_left" -gt 0 ]; do
    if command -v curl >/dev/null 2>&1; then
      curl -fsS -o /dev/null --max-time 2 "$a_url" 2>/dev/null && return 0
    elif command -v wget >/dev/null 2>&1; then
      wget -q -O /dev/null -T 2 "$a_url" 2>/dev/null && return 0
    else
      return 1
    fi
    sleep 1
    a_left=$((a_left - 1))
  done
  return 1
}

# Moves the unpacked parts into place. Whatever was there goes to .previous.
PARTS="app runtime installer LICENSES VERSION BUILD.json README.txt bin/lobby bin/lobby-direct"
put_in_place() {
  # Each step is checked: `set -e` does not hold inside a function called from `if`.
  rm -rf "$prefix/.previous" || return 1
  mkdir -p "$prefix/.previous/bin" "$prefix/bin" || return 1
  for p_part in $PARTS; do
    [ -e "$new/$p_part" ] || continue
    if [ -e "$prefix/$p_part" ]; then
      mv "$prefix/$p_part" "$prefix/.previous/$p_part" || return 1
    fi
    mv "$new/$p_part" "$prefix/$p_part" || return 1
  done
  rm -rf "$prefix/.incoming"
}

# Puts back what put_in_place moved aside, after a failed update.
put_back() {
  for p_part in $PARTS; do
    [ -e "$prefix/.previous/$p_part" ] || continue
    rm -rf "${prefix:?}/$p_part"
    mv "$prefix/.previous/$p_part" "$prefix/$p_part"
  done
}

after_start() {
  if [ "$start" = yes ] && [ "$1" != none ]; then
    if server_answers 60; then
      say "Lobby Server $new_version is running."
    else
      warn "Lobby did not answer within a minute. Look at $prefix/server.log."
    fi
  fi
}

# ---- Commands ----

do_install() {
  [ ! -e "$prefix/app" ] ||
    die "Lobby is already installed in $prefix. To update it: \"$prefix/bin/lobby\" update"
  take_lock
  fetch_archive
  unpack
  put_in_place
  rm -rf "$prefix/.previous"
  mkdir -p "$prefix/data"
  chmod 0700 "$prefix/data"
  write_config
  check_ffmpeg
  choose_service
  if [ "$service" != none ]; then
    write_service "$service"
    [ "$start" = no ] || start_service "$service"
  else
    printf 'none\n' >"$prefix/.service"
  fi
  after_start "$service"
  say ""
  say "Lobby Server $new_version is installed in $prefix."
  say "- Open Lobby on a Mac, iPhone, iPad or Apple TV on the same network: it finds this server."
  say "  The first device to connect from the home network or the tailnet sets it up and picks"
  say "  the folders with films. Nobody from elsewhere can."
  say "- Lobby listens on every network of this computer ($host, port $port). On a computer that"
  say "  can be reached from the internet, set \"host\" in the config to a private address first."
  say "- The command: $prefix/bin/lobby help   (put $prefix/bin on your PATH to type just lobby)"
  [ "$service" != none ] || say "- Start it: $prefix/bin/lobby serve"
  say "- Update: lobby update. Remove: lobby uninstall (keeps the data)."
}

do_update() {
  [ -e "$prefix/app/src/cli.ts" ] || die "Lobby is not installed in $prefix."
  take_lock
  if [ -f "$prefix/VERSION" ]; then
    current="$(cat "$prefix/VERSION")"
  else
    current="$(sed -n 's/^ *"version": *"\([^"]*\)".*/\1/p' "$prefix/app/package.json" | head -n 1)"
  fi
  fetch_archive
  unpack
  if [ "$force" = no ]; then
    if [ "$new_version" = "$current" ]; then
      rm -rf "$prefix/.incoming"
      say "Lobby Server $current is installed already."
      return
    fi
    if older_than "$new_version" "$current"; then
      rm -rf "$prefix/.incoming"
      die "$new_version is older than $current, which is installed. An older server may not read a catalogue a newer one wrote; use --force only with a backup from that version at hand."
    fi
  fi
  kind="$(installed_service)"
  say "Updating Lobby Server ${current:-?} to $new_version..."
  stop_service "$kind"
  if [ "$backup" = yes ] && [ -f "$prefix/lobby.config.json" ]; then
    # With the version that wrote the catalogue, before the new one changes it.
    if ! node_here "$prefix/app/src/cli.ts" backup --config "$prefix/lobby.config.json"; then
      start_service "$kind"
      die "the catalogue could not be backed up, so nothing was changed. --no-backup updates without one."
    fi
  fi
  if ! put_in_place; then
    put_back
    start_service "$kind"
    die "the update could not be put in place; the version that was there is back."
  fi
  # A service this installer wrote gets the new version's definition.
  if [ "$kind" != none ] && grep -q "$MARKER" "$(service_file "$kind")" 2>/dev/null; then
    write_service "$kind"
  fi
  [ "$start" = no ] || start_service "$kind"
  after_start "$kind"
  say "Updated to $new_version. The data folder and the config were not changed; the version before is in $prefix/.previous until the next update."
  [ "$kind" != none ] || say "Restart Lobby yourself to use it: $prefix/bin/lobby serve"
}

confirm() {
  [ "$assume_yes" = yes ] && return 0
  [ -t 0 ] || die "pass --yes to delete the data without being asked."
  printf '%s Type "delete" to go on: ' "$1"
  read -r c_answer || c_answer=""
  [ "$c_answer" = delete ]
}

do_uninstall() {
  [ -e "$prefix/app" ] || [ -e "$prefix/runtime" ] || [ -e "$prefix/.service" ] ||
    die "Lobby is not installed in $prefix."
  if [ "$delete_data" = yes ]; then
    d_dir="$prefix/data"
    if [ -x "$prefix/runtime/bin/node" ] && [ -f "$prefix/lobby.config.json" ]; then
      d_dir="$(data_dir)"
    fi
    confirm "This deletes the catalogue, watch history, paired devices and settings in $d_dir, and the config." ||
      die "nothing was removed."
  fi
  take_lock
  for u_kind in user system; do
    if [ "$(installed_service)" = "$u_kind" ] || [ -f "$(service_file "$u_kind")" ]; then
      remove_service "$u_kind"
    fi
  done
  for u_part in $PARTS .previous .incoming .service; do
    rm -rf "${prefix:?}/$u_part"
  done
  rmdir "$prefix/bin" 2>/dev/null || true
  if [ "$delete_data" = yes ]; then
    case "$d_dir/" in
      "$prefix"/*) rm -rf "$d_dir" ;;
      *) say "The data folder is outside $prefix and was kept: $d_dir" ;;
    esac
    rm -f "$prefix/lobby.config.json" "$prefix/server.log"
    rmdir "$lock" 2>/dev/null || true
    lock=""
    rmdir "$prefix" 2>/dev/null || say "Kept $prefix: it holds files that are not Lobby's."
    say "Lobby Server and its data are removed. Library folders were never changed by uninstalling."
  else
    say "Lobby Server is removed. Kept: the data folder, $prefix/lobby.config.json and the log."
    say "Installing again uses them. To delete them as well: sh install.sh uninstall --delete-data"
  fi
}

case "$command_name" in
  install) do_install ;;
  update) do_update ;;
  uninstall) do_uninstall ;;
esac

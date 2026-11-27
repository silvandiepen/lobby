#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# A real Lobby Server on this Mac for the UI tests, with a temporary data folder and a few
# small films made by ffmpeg. Nothing is written outside apps/apple/build/.
#
#   ui-test-server.sh start    make the media, start three servers, write build/ui-test-server/server.json
#   ui-test-server.sh stop     stop them
#
# Two servers, because the tests cover both ways in:
#   paired  already claimed, with the viewers "Alex", "Kids" and "Guest". The app pairs with a code and
#           the test approves it through the API with the manager token in server.json.
#   fresh   not claimed. The app claims it with the setup secret in server.json.
#   second  another household's, claimed, with the viewer "Oma": a second server in the same app.
#           Paired like the first.
#
# The scheme's test action runs this before and after the tests. The UI tests read
# server.json, and skip themselves with a clear message when it is not there (no Node 24, no
# ffmpeg).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../../.." && pwd)"
WORK="${HERE}/../build/ui-test-server"
MUSIC="${HERE}/../build/music-sample"

# The server under test is this checkout's. While its other half is still in another worktree,
# that one's path can be named in the git-ignored build folder.
SERVER_REPO="${REPO}"
if [ -f "${HERE}/../build/test-server-path" ]; then
  SERVER_REPO="$(cat "${HERE}/../build/test-server-path")"
fi
# Other checkouts on this Mac run the same tests: LOBBY_TEST_PORT (or build/test-port) moves
# both servers, the fresh one on the port after.
if [ -z "${LOBBY_TEST_PORT:-}" ] && [ -f "${HERE}/../build/test-port" ]; then
  LOBBY_TEST_PORT="$(cat "${HERE}/../build/test-port")"
fi
PAIRED_PORT="${LOBBY_TEST_PORT:-18674}"
FRESH_PORT=$((PAIRED_PORT + 1))
SECOND_PORT=$((PAIRED_PORT + 2))

# Xcode runs scheme scripts with a short PATH.
export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"

find_node() {
  local candidate
  for candidate in "$(command -v node || true)" "${HOME}"/.nvm/versions/node/*/bin/node; do
    [ -x "${candidate}" ] || continue
    if [ "$("${candidate}" -p 'Number(process.versions.node.split(".")[0]) >= 24')" = "true" ]; then
      echo "${candidate}"
      return 0
    fi
  done
  return 1
}

stop() {
  local pid_file
  for pid_file in "${WORK}"/*.pid; do
    [ -f "${pid_file}" ] || continue
    kill "$(cat "${pid_file}")" 2>/dev/null || true
    rm -f "${pid_file}"
  done
  rm -f "${WORK}/server.json"
}

make_video() { # path seconds seed [video codec]
  mkdir -p "$(dirname "$1")"
  "${FFMPEG}" -v error -y \
    -f lavfi -i "testsrc2=size=320x180:rate=10:duration=$2" \
    -f lavfi -i "sine=frequency=$((330 + $3 * 40)):duration=$2" \
    -c:v "${4:-libx264}" -pix_fmt yuv420p -g 10 -c:a aac -metadata "comment=seed-$3" -shortest "$1"
}

# Logos for the Kids categories, to look at them: set LOBBY_TEST_LOGOS to a folder of PNGs
# outside the repository. They are put where the server keeps logos, so it fetches nothing.
# Without it the categories have no logo, which is what the tests expect.
seed_logos() { # name
  LOGO_1="" LOGO_2="" EXTRA_ROOTS=""
  # The scheme's own start does not see the shell's variables: the folder can also be named
  # in the git-ignored build folder.
  if [ -z "${LOBBY_TEST_LOGOS:-}" ] && [ -f "${HERE}/../build/test-logos-path" ]; then
    LOBBY_TEST_LOGOS="$(cat "${HERE}/../build/test-logos-path")"
  fi
  [ -n "${LOBBY_TEST_LOGOS:-}" ] && [ -d "${LOBBY_TEST_LOGOS}" ] || return 0
  local dir="${WORK}/$1-data/artwork/logos" index=0 file id
  mkdir -p "${dir}"
  for file in "${LOBBY_TEST_LOGOS}"/*.png; do
    [ -f "${file}" ] || continue
    index=$((index + 1))
    id="lobbytestlogo${index}"
    cp "${file}" "${dir}/${id}.png"
    case "${index}" in
      1) LOGO_1=", \"logo\": \"/${id}.png\"" ;;
      2) LOGO_2=", \"logo\": \"/${id}.png\"" ;;
      3|4)
        mkdir -p "${WORK}/media/Extra${index}"
        [ -f "${WORK}/media/Extra${index}/Sample ${index} (2000).mp4" ] || make_video "${WORK}/media/Extra${index}/Sample ${index} (2000).mp4" 6 "$((index + 10))"
        EXTRA_ROOTS="${EXTRA_ROOTS},
    { \"path\": \"${WORK}/media/Extra${index}\", \"name\": \"Studio ${index}\", \"hint\": \"movies\", \"group\": \"Kids\", \"logo\": \"/${id}.png\" }" ;;
    esac
  done
}

start_server() { # name port [server name]
  local name="$1" port="$2" config="${WORK}/$1.config.json" title="${3:-Lobby UI Test}"
  seed_logos "$1"
  cat > "${config}" <<JSON
{
  "serverName": "${title}",
  "dataDir": "${WORK}/$1-data",
  "host": "127.0.0.1",
  "port": ${port},
  "stabilityMs": 100,
  "ffmpegPath": "${FFMPEG}",
  "ffprobePath": "${FFPROBE}",
  "conversion": { "dir": "${WORK}/$1-lobby", "server": false },
  "roots": [
    { "path": "${WORK}/media/Movies", "name": "Test Films", "hint": "movies" },
    { "path": "${WORK}/media/Series", "name": "Test Series", "hint": "series" },
    { "path": "${WORK}/media/Zebra", "name": "Zebra Tales", "hint": "movies", "group": "Kids"${LOGO_1} },
    { "path": "${WORK}/media/Animals", "name": "Animal Films", "hint": "movies", "group": "Kids"${LOGO_2} }${EXTRA_ROOTS},
    { "path": "${MUSIC}/Music", "name": "Music", "hint": "music" },
    { "path": "${MUSIC}/Audiobooks", "name": "Audiobooks", "hint": "audiobooks" }
  ]
}
JSON
  "${NODE}" "${SERVER_REPO}/apps/server/src/cli.ts" scan --config "${config}"
  nohup "${NODE}" "${SERVER_REPO}/apps/server/src/cli.ts" serve --config "${config}" > "${WORK}/${name}.log" 2>&1 &
  echo $! > "${WORK}/${name}.pid"
  local tries=0
  until curl -fsS "http://127.0.0.1:${port}/v1/server" > /dev/null 2>&1; do
    tries=$((tries + 1))
    [ "${tries}" -lt 100 ] || { echo "The ${name} server did not start. See ${WORK}/${name}.log" >&2; return 1; }
    sleep 0.1
  done
}

json_field() { # field  (reads JSON on stdin)
  "${NODE}" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s)[process.argv[1]]))' "$1"
}

start() {
  NODE="$(find_node)" || { echo "Node 24 or later was not found." >&2; exit 1; }
  FFMPEG="$(command -v ffmpeg)" || { echo "ffmpeg was not found." >&2; exit 1; }
  FFPROBE="$(command -v ffprobe)" || { echo "ffprobe was not found." >&2; exit 1; }

  mkdir -p "${WORK}"
  stop
  rm -rf "${WORK}"
  mkdir -p "${WORK}"

  # A film long enough to stop in the middle of, a short one that plays to its end, one in a
  # container Apple cannot open, one whose picture Apple cannot decode, and a show.
  make_video "${WORK}/media/Movies/The Long Test (2019).mp4" 240 1
  make_video "${WORK}/media/Movies/Short Notice (2021).mp4" 12 2
  # A subtitle file beside the long film: one line for every second of its first minute.
  {
    for second in $(seq 0 58); do
      printf '%d\n00:00:%02d,000 --> 00:00:%02d,000\nRegel %d\n\n' "$((second + 1))" "${second}" "$((second + 1))" "$((second + 1))"
    done
  } > "${WORK}/media/Movies/The Long Test (2019).nl.srt"
  make_video "${WORK}/media/Movies/Matroska Morning (2015).mkv" 20 3
  make_video "${WORK}/media/Movies/Old Format (2001).avi" 20 4 mpeg4
  make_video "${WORK}/media/Series/Test Show/Season 1/Test Show - S01E01 - Pilot.mp4" 12 5
  make_video "${WORK}/media/Series/Test Show/Season 1/Test Show - S01E02 - Second Thoughts.mp4" 12 6
  make_video "${WORK}/media/Series/Test Show/Season 2/Test Show - S02E01 - Return.mp4" 12 7

  # A part of the library of its own ("Kids"), with two categories in the household's order,
  # which is not the alphabet's.
  make_video "${WORK}/media/Zebra/Stripes (2012).mp4" 6 8
  make_video "${WORK}/media/Animals/Paper Boats (2010).mp4" 6 9
  # A film on "this device", for the upload test to send as if it was picked in Files.
  make_video "${WORK}/upload/Sent From Phone (2020).mp4" 4 12

  # An invented music library: tunes, drawn covers, one audiobook (tools/music-sample). Made
  # once, beside the work folder, which every start empties: it takes half a minute.
  FFMPEG="${FFMPEG}" "${REPO}/tools/music-sample/make-library.sh" "${MUSIC}"

  start_server paired "${PAIRED_PORT}"
  start_server fresh "${FRESH_PORT}"
  start_server second "${SECOND_PORT}" "Lobby UI Test Two"

  local paired="http://127.0.0.1:${PAIRED_PORT}" fresh="http://127.0.0.1:${FRESH_PORT}" second="http://127.0.0.1:${SECOND_PORT}"
  local paired_secret fresh_secret second_secret token second_token
  paired_secret="$("${NODE}" "${SERVER_REPO}/apps/server/src/cli.ts" setup-secret --config "${WORK}/paired.config.json")"
  fresh_secret="$("${NODE}" "${SERVER_REPO}/apps/server/src/cli.ts" setup-secret --config "${WORK}/fresh.config.json")"

  token="$(curl -fsS -X POST "${paired}/v1/pairing/claim" -H 'Content-Type: application/json' \
    -d "{\"setupSecret\":\"${paired_secret}\",\"deviceName\":\"UI test manager\",\"platform\":\"cli\"}" | json_field token)"
  for viewer in '{"name":"Alex","color":"blue"}' '{"name":"Kids","color":"green"}' '{"name":"Guest","color":"purple"}'; do
    curl -fsS -X POST "${paired}/v1/profiles" -H "Authorization: Bearer ${token}" \
      -H 'Content-Type: application/json' -d "${viewer}" > /dev/null
  done

  second_secret="$("${NODE}" "${SERVER_REPO}/apps/server/src/cli.ts" setup-secret --config "${WORK}/second.config.json")"
  second_token="$(curl -fsS -X POST "${second}/v1/pairing/claim" -H 'Content-Type: application/json' \
    -d "{\"setupSecret\":\"${second_secret}\",\"deviceName\":\"UI test manager\",\"platform\":\"cli\"}" | json_field token)"
  curl -fsS -X POST "${second}/v1/profiles" -H "Authorization: Bearer ${second_token}" \
    -H 'Content-Type: application/json' -d '{"name":"Oma","color":"pink"}' > /dev/null

  cat > "${WORK}/server.json" <<JSON
{
  "paired": { "url": "${paired}", "managerToken": "${token}" },
  "fresh": { "url": "${fresh}", "setupSecret": "${fresh_secret}" },
  "second": { "url": "${second}", "managerToken": "${second_token}" },
  "uploadFile": "${WORK}/upload/Sent From Phone (2020).mp4"
}
JSON
  echo "Lobby test servers are running: ${paired} (paired), ${fresh} (fresh) and ${second} (second)."
}

case "${1:-}" in
  start) start ;;
  stop) stop ;;
  *) echo "Usage: $0 start|stop" >&2; exit 2 ;;
esac

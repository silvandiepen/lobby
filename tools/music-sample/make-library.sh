#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# A small invented music library, made with ffmpeg at test time: four albums of synthesised
# tones in four formats, drawn covers, plausible tags, and one audiobook with chapters. Every
# artist, title and picture here is made up; nothing is a real song. A few MB in all.
#
#   make-library.sh <folder>      writes <folder>/Music and <folder>/Audiobooks
#
# Point two library folders at them, with the hints "music" and "audiobooks":
#
#   { "path": "<folder>/Music", "name": "Music", "hint": "music" },
#   { "path": "<folder>/Audiobooks", "name": "Audiobooks", "hint": "audiobooks" }
#
# Running it again leaves a finished library as it is.

set -euo pipefail

OUT="${1:?Usage: make-library.sh <folder>}"
FFMPEG="${FFMPEG:-$(command -v ffmpeg)}" || { echo "ffmpeg was not found." >&2; exit 1; }
[ -f "${OUT}/.complete" ] && exit 0
MUSIC="${OUT}/Music"
BOOKS="${OUT}/Audiobooks"
WORK="${OUT}/.work"
rm -rf "${MUSIC}" "${BOOKS}" "${WORK}"
mkdir -p "${MUSIC}" "${BOOKS}" "${WORK}"

# A square picture of soft colour fields: the four colours, a shape (0 linear, 1 radial,
# 2 circular, 3 spiral, 4 square) and a seed.
cover() { # path c0 c1 c2 c3 type seed
  mkdir -p "$(dirname "$1")"
  "${FFMPEG}" -v error -y -f lavfi \
    -i "gradients=s=600x600:c0=$2:c1=$3:c2=$4:c3=$5:n=4:type=$6:seed=$7:speed=0.02:d=1" \
    -vf "noise=alls=6:allf=u" -frames:v 1 -q:v 3 "$1"
}

# A tune: plucked notes from a scale over a soft drone, in stereo. Every argument changes
# what it sounds like, so every file is its own.
#   seconds  root (Hz)  notes per second  pattern (a number that picks the steps)
tune() {
  local seconds="$1" root="$2" rate="$3" pattern="$4"
  local step="pow(2,(mod(floor(t*${rate})*${pattern},7)*2-mod(floor(t*${rate})*${pattern},3))/12)"
  local pluck="exp(-3*mod(t*${rate},1))"
  local drone="0.08*sin(2*PI*${root}/2*t)*(0.7+0.3*sin(2*PI*0.25*t))"
  local fade="min(1,t/0.5)*min(1,(${seconds}-t)/0.8)"
  echo "aevalsrc=exprs='(${drone}+0.22*${pluck}*sin(2*PI*${root}*${step}*t))*${fade}|(${drone}+0.18*${pluck}*sin(2*PI*${root}*${step}*t+0.6))*${fade}':s=44100:d=${seconds}"
}

# One file. Extra ffmpeg arguments (codec, tags) follow the source.
track() { # path seconds root rate pattern [ffmpeg arguments…]
  local path="$1" seconds="$2" root="$3" rate="$4" pattern="$5"
  shift 5
  mkdir -p "$(dirname "${path}")"
  "${FFMPEG}" -v error -y -f lavfi -i "$(tune "${seconds}" "${root}" "${rate}" "${pattern}")" "$@" "${path}"
}

# With the cover inside the file, as many shops sell them.
track_with_cover() { # path seconds root rate pattern cover [ffmpeg arguments…]
  local path="$1" seconds="$2" root="$3" rate="$4" pattern="$5" picture="$6"
  shift 6
  mkdir -p "$(dirname "${path}")"
  "${FFMPEG}" -v error -y -f lavfi -i "$(tune "${seconds}" "${root}" "${rate}" "${pattern}")" -i "${picture}" \
    -map 0:a -map 1:v -c:v copy -disposition:v:0 attached_pic "$@" "${path}"
}

# 1. FLAC, a cover beside the files, ReplayGain in the tags.
album="${MUSIC}/The Paper Lanterns/Harbour Lights (2019)"
cover "${album}/cover.jpg" 0x1d3557 0x457b9d 0xa8dadc 0xf1c27d 1 11
n=0
for title in "Low Tide Signal" "Glass Buoys" "Copper Gulls" "Night Ferry"; do
  n=$((n + 1))
  track "${album}/0${n} ${title}.flac" $((24 + n * 4)) $((196 + n * 22)) 3 $((n + 2)) \
    -compression_level 5 \
    -metadata "title=${title}" -metadata "artist=The Paper Lanterns" -metadata "album_artist=The Paper Lanterns" \
    -metadata "album=Harbour Lights" -metadata "date=2019" -metadata "genre=Dream Pop" \
    -metadata "track=${n}/4" -metadata "disc=1/1" \
    -metadata "REPLAYGAIN_TRACK_GAIN=-$((n + 2)).40 dB" -metadata "REPLAYGAIN_TRACK_PEAK=0.8$((n + 1))" \
    -metadata "REPLAYGAIN_ALBUM_GAIN=-4.10 dB" -metadata "REPLAYGAIN_ALBUM_PEAK=0.89"
done

# 2. MP3 with the cover inside, two artists on one track.
cover "${WORK}/static-orchard.jpg" 0x2b2d42 0xef233c 0xffb703 0x8d99ae 3 23
album="${MUSIC}/Mira Calloway/Static Orchard"
n=0
for title in "Apple Circuit" "Ninth Furrow" "Pollen Drift" "Orchard at Noon"; do
  n=$((n + 1))
  artist="Mira Calloway"
  [ "${n}" = 3 ] && artist="Mira Calloway feat. Oskar Lunde"
  track_with_cover "${album}/0${n} - ${title}.mp3" $((20 + n * 5)) $((262 + n * 18)) 4 $((n + 4)) \
    "${WORK}/static-orchard.jpg" -c:a libmp3lame -q:a 4 -id3v2_version 3 \
    -metadata "title=${title}" -metadata "artist=${artist}" -metadata "album_artist=Mira Calloway" \
    -metadata "album=Static Orchard" -metadata "date=2022" -metadata "genre=Electronic" \
    -metadata "track=${n}" -metadata "composer=Mira Calloway"
done

# 3. AAC in M4A, made as one take and cut in three, so its tracks run into each other
#    (gapless).
album="${MUSIC}/Kettle & Kite/Morning Tram (2016)"
cover "${album}/folder.jpg" 0x3d405b 0xe07a5f 0xf4f1de 0x81b29a 2 37
track "${WORK}/morning-tram.wav" 75 220 2 3
n=0
for title in "First Stop" "Bridge Street" "Depot Lights"; do
  "${FFMPEG}" -v error -y -ss $((n * 25)) -t 25 -i "${WORK}/morning-tram.wav" -c:a aac -b:a 160k \
    -metadata "title=${title}" -metadata "artist=Kettle & Kite" -metadata "album_artist=Kettle & Kite" \
    -metadata "album=Morning Tram" -metadata "date=2016" -metadata "genre=Folk" \
    -metadata "track=$((n + 1))/3" -metadata "itunes_gapless=1" "${album}/0$((n + 1)) ${title}.m4a"
  n=$((n + 1))
done

# 4. A compilation in Opus, which Apple does not play: the server makes AAC copies.
album="${MUSIC}/Compilations/Northern Lines"
cover "${album}/cover.jpg" 0x0b132b 0x3a506b 0x5bc0be 0xfca311 4 41
n=0
for entry in "Signal Hill|Ivy Marsh" "Paper Compass|The Quiet Engines" "Snow Ledger|Hollis Grey"; do
  n=$((n + 1))
  title="${entry%%|*}"
  artist="${entry##*|}"
  track "${album}/0${n} ${title}.opus" $((22 + n * 3)) $((174 + n * 30)) 3 $((n + 1)) -c:a libopus -b:a 96k \
    -metadata "title=${title}" -metadata "artist=${artist}" -metadata "album_artist=Various Artists" \
    -metadata "album=Northern Lines" -metadata "date=2021" -metadata "genre=Ambient" \
    -metadata "track=${n}" -metadata "compilation=1"
done

# 5. An audiobook: one M4B with five chapters, a cover, author, reader and series.
book="${BOOKS}/Ada Penhallow/The Lighthouse Keeper's Cat"
cover "${WORK}/lighthouse.jpg" 0x264653 0x2a9d8f 0xe9c46a 0xf4a261 0 53
{
  echo ";FFMETADATA1"
  start=0
  for chapter in "Opening Credits" "The Lamp Room" "A Storm from the West" "Seven Fishing Boats" "Morning, at Last"; do
    end=$((start + 36000))
    printf '[CHAPTER]\nTIMEBASE=1/1000\nSTART=%d\nEND=%d\ntitle=%s\n' "${start}" "${end}" "${chapter}"
    start="${end}"
  done
} > "${WORK}/chapters.txt"
mkdir -p "${book}"
"${FFMPEG}" -v error -y -f lavfi -i "$(tune 180 147 1 2)" -i "${WORK}/lighthouse.jpg" -f ffmetadata -i "${WORK}/chapters.txt" \
  -map 0:a -map 1:v -map_chapters 2 -c:a aac -b:a 64k -ac 1 -c:v copy -disposition:v:0 attached_pic \
  -metadata "title=The Lighthouse Keeper's Cat" -metadata "album=The Lighthouse Keeper's Cat" \
  -metadata "artist=Ada Penhallow" -metadata "album_artist=Ada Penhallow" -metadata "narrator=Tom Wren" \
  -metadata "composer=Tom Wren" -metadata "genre=Children's Fiction" -metadata "date=2020" \
  -metadata "series=Tales from Gull Point" -metadata "seriespart=1" \
  -metadata "description=A cat keeps a lighthouse lit through one long night. An invented story for trying Lobby." \
  -f ipod "${book}/The Lighthouse Keeper's Cat.m4b"

rm -rf "${WORK}"
touch "${OUT}/.complete"
echo "An invented music library is in ${OUT}."

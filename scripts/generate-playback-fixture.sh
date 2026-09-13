#!/usr/bin/env bash
# Synthetic SDR baseline; does not pretend to exercise Dolby Vision or Atmos.
set -euo pipefail
if [[ $# -ne 1 || "$1" != /* ]]; then
  echo 'Usage: bash scripts/generate-playback-fixture.sh /absolute/path/fixture.mkv' >&2
  exit 1
fi
command -v ffmpeg >/dev/null
ffmpeg -hide_banner -loglevel error -n \
  -f lavfi -i testsrc2=duration=12:size=640x360:rate=24 \
  -f lavfi -i anullsrc=r=48000:cl=5.1 \
  -f lavfi -i sine=frequency=880:sample_rate=48000 \
  -map 0:v -map 1:a -map 2:a -t 12 \
  -c:v libx264 -pix_fmt yuv420p -g 48 \
  -c:a:0 eac3 -c:a:1 aac -ac:a:1 2 \
  -metadata:s:a:0 language=fra -metadata:s:a:1 language=eng "$1"

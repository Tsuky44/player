#!/usr/bin/env bash
# Local checks only; never deploys or contacts the configured media server.
set -euo pipefail
root_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
command -v go >/dev/null
command -v flutter >/dev/null
if [[ -n "${ONYX_IT_MEDIA:-}" ]]; then
  [[ "$ONYX_IT_MEDIA" = /* && -r "$ONYX_IT_MEDIA" ]] || {
    echo 'ONYX_IT_MEDIA must be an absolute, readable local file.' >&2
    exit 1
  }
  command -v ffmpeg >/dev/null
  command -v ffprobe >/dev/null
else
  echo 'FFmpeg corpus integrations skipped: ONYX_IT_MEDIA is not set.'
fi
(
  cd "$root_dir/server"
  go test -count=1 ./...
)
(
  cd "$root_dir/app"
  flutter test
)

#!/usr/bin/env bash
# Decode your own Seven Cities of Gold disk images into assets/.
#
# Put the images in d64/ first:
#     d64/7CITIES1.D64    program disk, side 1
#     d64/7CITIES2.D64    program disk, side 2 (the historical map)
#
# No game data ships with this project.
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v swift >/dev/null 2>&1; then
    echo "Swift not found. Install Xcode or the Swift toolchain, then re-run." >&2
    exit 1
fi

if [ ! -d d64 ] || [ -z "$(ls -A d64 2>/dev/null)" ]; then
    mkdir -p d64
    cat <<'MSG'
No disk images found.

Put images of disks you own into d64/ and run this again:

    d64/7CITIES1.D64    program disk, side 1 — the terrain art
    d64/7CITIES2.D64    program disk, side 2 — the historical map

No game data ships with this project. You can still explore generated worlds
without any disks at all: run "make run" and use the World menu.
MSG
    exit 1
fi

exec swift run --package-path SevenCitiesCore Extract .

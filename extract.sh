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

if [ ! -d d64 ]; then
    echo "Creating d64/ — put your disk images there and run this again."
    mkdir -p d64
fi

exec swift run --package-path SevenCitiesCore Extract .

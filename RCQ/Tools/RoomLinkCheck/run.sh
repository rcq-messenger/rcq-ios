#!/bin/sh
# Drives PinnedRoomLink in Services/CrossIslandLogic.swift: which room links a
# pinned announcement turns into cards, with their island and key (#990).
# Compiled from the REAL source the app builds. Outside the app target on
# purpose, like CrossIslandRosterCheck: this project has no test target.
#
# Run by hand after touching the pattern:
#
#     iOS/RCQ/Tools/RoomLinkCheck/run.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
out=$(mktemp -d)
swiftc -O -swift-version 5 \
  "$root/RCQ/Services/CrossIslandLogic.swift" \
  "$here/main.swift" -o "$out/check"
"$out/check"

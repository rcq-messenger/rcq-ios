#!/bin/sh
# Drives Services/GroupLogStall.swift: when a room-log row that will not open
# is given up on (`GroupLogStall`), and how a drain walks past a room such a
# row is holding (`GroupLogWalk`). Compiled from the REAL source the app
# builds. Outside the app target on purpose: this project has no test target.
#
# Worth a check because both ways of getting it wrong are silent: a count that
# never adds up leaves one bad row holding its room, and every room after it,
# until the island's log drops it a month later (report 981); a count that adds
# up too eagerly acks past messages this phone could have opened. Run by hand
# after touching it:
#
#     iOS/RCQ/Tools/GroupLogStallCheck/run.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
out=$(mktemp -d)
swiftc -O -swift-version 5 \
  "$root/RCQ/Services/GroupLogStall.swift" \
  "$here/main.swift" -o "$out/check"
"$out/check"

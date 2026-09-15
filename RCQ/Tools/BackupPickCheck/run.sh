#!/bin/sh
# Drives the pure backup auto-pick rule at the bottom of
# Services/CrossIslandLogic.swift (report #988) through every branch the three
# clients share: the door read from /server/info, the probe that makes an
# island silent, open or shut, and the walk that registers only on an open
# door, recovers only on a shut one, and runs the relay pass only when nothing
# answered. Compiled from the REAL source the app builds. Outside the app
# target on purpose, like IslandTrustCheck: this project has no test target.
# Run by hand after touching the rule:
#
#     iOS/RCQ/Tools/BackupPickCheck/run.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
out=$(mktemp -d)
swiftc -O -swift-version 5 \
  "$root/RCQ/Services/CrossIslandLogic.swift" \
  "$here/main.swift" -o "$out/check"
"$out/check"

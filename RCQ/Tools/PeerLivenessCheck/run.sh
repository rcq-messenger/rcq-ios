#!/bin/sh
# Drives PeerLiveness at the bottom of Services/CrossIslandLogic.swift: whether
# a contact on another island still exists, from what their island answers
# about the number and the key we pinned (report 1067). Compiled from the REAL
# source the app builds. Outside the app target on purpose, like
# BlockRuleCheck: this project has no test target.
#
# Worth a check because the costly mistake is silent: an answer read as
# "deleted" that only looked like one (a decoy page, an island without the
# route) marks every contact of that island deleted. Run by hand after
# touching it:
#
#     iOS/RCQ/Tools/PeerLivenessCheck/run.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
out=$(mktemp -d)
swiftc -O -swift-version 5 \
  "$root/RCQ/Services/CrossIslandLogic.swift" \
  "$here/main.swift" -o "$out/check"
"$out/check"

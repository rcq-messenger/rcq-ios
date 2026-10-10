#!/bin/sh
# Drives BlockRule at the bottom of Services/CrossIslandLogic.swift: whom a
# block names, and whether a row's sender is one of them (reports 1064, 1065).
# And CIAckRule beside it: when a block or an unblock from another device was
# decided, which one wins, and whether it names the address or only a key.
# Compiled from the REAL source the app builds. Outside the app target on
# purpose, like CrossIslandRosterCheck: this project has no test target.
#
# Worth a check because both ways of getting it wrong are silent: a block that
# names a bare number drops everybody with that number on every island, and a
# block that names too little lets the blocked person through from their other
# island. Run by hand after touching it:
#
#     iOS/RCQ/Tools/BlockRuleCheck/run.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
out=$(mktemp -d)
swiftc -O -swift-version 5 \
  "$root/RCQ/Services/CrossIslandLogic.swift" \
  "$here/main.swift" -o "$out/check"
"$out/check"

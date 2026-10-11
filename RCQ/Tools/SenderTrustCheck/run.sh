#!/bin/sh
# Drives Services/SenderTrust.swift: who an envelope is from (`SenderTrust`),
# who may edit, delete or react to a row that is already in a chat
# (`ControlAuthority`), which sender-key chains are taken (`SkdmRule`) and how
# far a room key may move (`RoomKeyRule`). Compiled from the REAL source both
# the app and the notification extension build. Outside the app target on
# purpose, like BlockRuleCheck: this project has no test target.
#
# Worth a check because every way of getting it wrong is silent: a forged
# message lands in a contact's chat looking exactly like theirs, and a refused
# honest one looks like a message that never came. Run by hand after touching
# it:
#
#     iOS/RCQ/Tools/SenderTrustCheck/run.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
out=$(mktemp -d)
swiftc -O -swift-version 5 \
  "$root/RCQ/Services/SenderTrust.swift" \
  "$here/main.swift" -o "$out/check"
"$out/check"

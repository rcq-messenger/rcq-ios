#!/bin/sh
# Drives the three rules at the bottom of Services/CrossIslandLogic.swift:
# CrossIslandRoster.fold (the cross-island half of the visible roster, both
# directions), PeerIsland.cardHost (which island a number means) and GuestFlag
# (what a reply can say about our own row being a guest copy). Compiled from the
# REAL source the app builds. Outside the app target on purpose, like
# BackupPickCheck and IslandTrustCheck: this project has no test target.
#
# Why these three are worth a check rather than a careful read: each is invisible
# when wrong. Report #1024 threw nothing, logged nothing, and left the roster one
# row wrong until the account was switched away and back; the wrong island does
# not fail a card, it confidently describes somebody else and then tells them we
# looked; and a stale guest flag silences push with no error on either side.
#
# Android pins the same rules in app/src/test/java/app/rcq/android/data/
# (CrossIslandRosterTest, PeerIslandTest) and net/GuestFlagWireTest. Run by hand
# after touching any of them:
#
#     iOS/RCQ/Tools/CrossIslandRosterCheck/run.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
out=$(mktemp -d)
swiftc -O -swift-version 5 \
  "$root/RCQ/Services/CrossIslandLogic.swift" \
  "$here/main.swift" -o "$out/check"
"$out/check"

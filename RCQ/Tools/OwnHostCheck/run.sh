#!/bin/sh
# Holds the notification extension's copy of the island address rule
# (`AppGroup.canonicalHost`) to the app's own (`IslandTrust.endpoint`, which
# `Multihome.normalizeHost` and so `isOwnHost` use), compiled from the REAL
# sources both targets build. Report 1071: the extension decides "our island
# or another one" from the names the app hands it, so the two spellings of an
# address must come out the same on both sides, or a message from our own
# island would be announced as a request. Run by hand after touching either:
#
#     iOS/RCQ/Tools/OwnHostCheck/run.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
out=$(mktemp -d)
swiftc -O -swift-version 5 \
  "$root/RCQ/Services/IslandTrust.swift" \
  "$root/RCQ/Services/AppGroup.swift" \
  "$here/main.swift" -o "$out/check"
"$out/check"

#!/bin/sh
# Drives the pure half of Services/IslandTrust.swift - the fingerprint
# parser, the display form, the address splitter and the §1 rule - through
# every branch of docs/island-fingerprint-design.md, compiled from the REAL
# source the app builds. Outside the app target on purpose, like
# SitesConformance and VaultCheck: this project has no test target. Run by hand
# after touching IslandTrust.swift:
#
#     iOS/RCQ/Tools/IslandTrustCheck/run.sh
#
# The file compiles alone because the app-side host list reaches it through
# `caOnlyHostsProvider` rather than through APIClient; the check sets the
# provider the way RCQApp.init does.
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
out=$(mktemp -d)
swiftc -O -swift-version 5 \
  "$root/RCQ/Services/IslandTrust.swift" \
  "$here/main.swift" -o "$out/check"
"$out/check"

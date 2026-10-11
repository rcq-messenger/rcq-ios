#!/bin/sh
# Holds the notification extension to the app's same-island stranger
# quarantine (Privacy -> "Strangers go to requests"): the rule it reads from
# the App Group (`AppGroup.QuarantineMirror`, compiled from the REAL source
# both targets build), and its copy of the envelope kinds the quarantine holds
# against `StrangerQuarantine.isContentKind` (both read as TEXT, never
# compiled). With the two apart, a stranger's words reach the lock screen while
# the app files them under Requests, or a contact's message is announced as a
# request. Outside the app target on purpose: this project has no test target.
# Run by hand after touching either:
#
#     iOS/RCQ/Tools/StrangerQuarantineCheck/run.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
out=$(mktemp -d)
swiftc -O -swift-version 5 \
  "$root/RCQ/Services/AppGroup.swift" \
  "$here/main.swift" -o "$out/check"
"$out/check" \
  "$root/RCQ/Services/StrangerQuarantine.swift" \
  "$root/RCQNotificationService/NotificationService.swift"

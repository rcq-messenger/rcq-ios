#!/bin/sh
# Round-trips a Message through the archive record and back, plus the shapes
# another client can legitimately send us: no optional key at all, a kind we
# spell differently, a line that cannot be a message here.
#
# Outside the app target on purpose — this project has no test target, and a
# check that needs one would simply never have been written. Run it by hand
# after touching BackupRecordMapping.swift:
#
#     iOS/RCQ/Tools/BackupMappingCheck/run.sh
#
# For the container itself (the bytes), use the conformance reader that lives
# next to the spec: rcq-docs/scripts/rcqbak-check.py
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
out=$(mktemp -d)
swiftc -O \
  "$root/RCQ/Services/BackupRecordMapping.swift" \
  "$root/RCQ/Models/Message.swift" \
  "$here/main.swift" \
  -o "$out/check"
"$out/check"

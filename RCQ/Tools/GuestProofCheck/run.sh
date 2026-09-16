#!/bin/sh
# Drives the pure guest-copy rules in Services/CrossIslandLogic.swift (spec
# 2026-09-15, C-G) against the island's own proof vector: the `rcq-guest-v1`
# bytes byte for byte, the host and key spellings that must bind the same, a
# signature made here verifying and the fixture's verifying, the path decision
# from /server/info, the answer table of the self-join, the refusal sentences,
# and the kinds a room frame may not carry. Compiled from the REAL source the
# app builds. Outside the app target on purpose, like BackupPickCheck: this
# project has no test target.
#
# guest-proof-v1.json is a verbatim copy of rcq-server-ref/fixtures; when the
# island's vector changes, copy it again rather than editing it here.
#
#     iOS/RCQ/Tools/GuestProofCheck/run.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
out=$(mktemp -d)
swiftc -O -swift-version 5 \
  "$root/RCQ/Services/CrossIslandLogic.swift" \
  "$here/main.swift" -o "$out/check"
# The two app sources are read as TEXT, never compiled: the drop list of spec 7
# is checked against the kinds the real Envelope encoder and decoder carry, and
# against the ingest switch that applies it (E3).
"$out/check" "$here/guest-proof-v1.json" \
  "$root/RCQ/Services/CryptoService.swift" \
  "$root/RCQ/Services/MessageService.swift"

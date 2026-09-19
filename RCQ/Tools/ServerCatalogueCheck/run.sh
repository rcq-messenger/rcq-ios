#!/bin/sh
# Drives the tolerant island-catalogue reader in Services/ServerCatalogue.swift:
# the two required fields, the defaults for everything else, the per-entry skip
# that keeps one hand-edited row from costing the whole deck, the flagship-first
# ordering and the source order. Compiled from the REAL source the app builds.
# Outside the app target on purpose, like BackupPickCheck and IslandTrustCheck:
# this project has no test target.
#
# The two json files are VERBATIM copies of what rcq.app and GitHub served on
# 19.09, kept because they are the pair that found the bug: the site copy has no
# `operator_contact` key on the Falcon entry and the GitHub copy has it patched
# to an empty string, and a strict reader dropped the whole catalogue over it.
# When the catalogue changes shape, fetch fresh copies rather than editing these.
#
# ServerCatalogue.swift compiles alone because it is Foundation only: the fetch,
# the cache and the logging all live in ServerDirectoryService. Run by hand after
# touching either:
#
#     iOS/RCQ/Tools/ServerCatalogueCheck/run.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
out=$(mktemp -d)
swiftc -O -swift-version 5 \
  "$root/RCQ/Services/ServerCatalogue.swift" \
  "$here/main.swift" -o "$out/check"
"$out/check" \
  "$here/servers-rcq.app-2026-09-19.json" \
  "$here/servers-github-2026-09-19.json"

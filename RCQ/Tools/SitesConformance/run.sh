#!/bin/sh
# Runs docs/rcq-sites-conformance.json against the REAL sources in
# RCQ/Services/Sites — the same files the app builds, compiled into a
# command-line binary. Outside the app target on purpose, like VaultCheck and
# BackupMappingCheck: this project has no test target.
#
# The corpus is shared with web-chat and Android, and that is the point: a `.rcq`
# address that resolves on one client and errors on another is worse than one
# that errors everywhere, and a page that is inert in one reader and live in
# another is worse than both. Run by hand after touching anything under
# Services/Sites:
#
#     iOS/RCQ/Tools/SitesConformance/run.sh
#
# SitesRepository.swift is deliberately NOT compiled in: it is the half with a
# network in it and it reaches for SingBoxTransport, which drags the whole app.
# Nothing the corpus asserts lives there.
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
out=$(mktemp -d)
swiftc -O -swift-version 5 \
  "$root/RCQ/Services/Sites/SiteAddress.swift" \
  "$root/RCQ/Services/Sites/SiteManifest.swift" \
  "$root/RCQ/Services/Sites/SitePins.swift" \
  "$root/RCQ/Services/Sites/SiteSanitizer.swift" \
  "$root/RCQ/Services/SigningKeys.swift" \
  "$here/main.swift" -o "$out/check"
"$out/check" "${1:-$root/../../docs/rcq-sites-conformance.json}"

#!/bin/sh
# Pins Services/SectionsVault.swift to the web's sections.ts, byte for byte,
# by running the same fixtures through both and diffing the answers. Outside
# the app target on purpose, like VaultCheck and BackupMappingCheck: this
# project has no test target. Run by hand after touching either merge:
#
#     iOS/RCQ/Tools/SectionsParity/run.sh
#
# The web side is the web's OWN built bundle, not a transcription: `node
# cli/build.mjs` bundles web-chat/src/lib/sections.ts into cli/dist/vault.mjs
# and the harness imports mergeSections out of it.
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
web=${RCQ_WEB_CHAT:-$(cd "$root/../../web-chat" && pwd)}
out=$(mktemp -d)

echo "web bundle: $web/cli/dist/vault.mjs"
(cd "$web" && node cli/build.mjs)

swiftc -O "$root/RCQ/Services/SectionsVault.swift" "$here/stubs.swift" "$here/main.swift" -o "$out/parity"
"$out/parity" "$here" > "$out/ios.txt"
node "$here/web.mjs" "$here" "$web/cli/dist/vault.mjs" > "$out/web.txt"

if diff -u "$out/web.txt" "$out/ios.txt" > "$out/diff.txt"; then
    echo "ALL PASS ($(wc -l < "$out/ios.txt" | tr -d ' ') facts, iOS == web)"
else
    echo "MISMATCH (- web, + iOS):"
    cat "$out/diff.txt"
    exit 1
fi

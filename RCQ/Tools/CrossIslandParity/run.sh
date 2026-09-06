#!/bin/sh
# Pins Services/CrossIslandVault.swift to the web's crossisland-vault.ts, byte
# for byte, by running the same fixtures through both and diffing the answers.
# Outside the app target on purpose, like SectionsParity and VaultCheck: this
# project has no test target. Run by hand after touching either merge:
#
#     iOS/RCQ/Tools/CrossIslandParity/run.sh
#
# Why byte for byte and not "equivalent": this slot is the ONLY copy of a
# user's cross-island contacts in existence, three clients write it, and a
# client that disagrees about the encoding reads the others' writes as a
# difference, rewrites, and burns the account's 240-puts-an-hour budget
# rewriting the same contacts at them forever.
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
web=${RCQ_WEB_CHAT:-$(cd "$root/../../web-chat" && pwd)}
out=$(mktemp -d)

echo "web bundle: $web/cli/dist/vault.mjs"
(cd "$web" && node cli/build.mjs)

swiftc -O "$root/RCQ/Services/CrossIslandVault.swift" "$here/stubs.swift" "$here/main.swift" -o "$out/parity"
"$out/parity" "$here" > "$out/ios.txt"
node "$here/web.mjs" "$here" "$web/cli/dist/vault.mjs" > "$out/web.txt"

if diff -u "$out/web.txt" "$out/ios.txt" > "$out/diff.txt"; then
    echo "ALL PASS ($(wc -l < "$out/ios.txt" | tr -d ' ') facts, iOS == web)"
else
    echo "MISMATCH (- web, + iOS):"
    cat "$out/diff.txt"
    exit 1
fi

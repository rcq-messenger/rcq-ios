#!/bin/sh
# Pins Services/Vault.swift to the web's vault.ts with a vector the web
# produced (see main.swift). Outside the app target on purpose, like
# BackupMappingCheck: this project has no test target. Run by hand after
# touching Vault.swift:
#
#     iOS/RCQ/Tools/VaultCheck/run.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
out=$(mktemp -d)
swiftc -O "$root/RCQ/Services/Vault.swift" "$here/main.swift" -o "$out/check"
"$out/check"

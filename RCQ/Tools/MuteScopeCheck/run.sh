#!/bin/sh
# Mutes per account: the names the lists give a chat (a number of our island,
# uin@host for somebody on another one), the file the notification extension
# reads them from for the account a push is for (and an older build's file,
# read the way it was written), what an island's answer changes, and where the
# phone-wide lists of older builds go (`MuteKeys.handOut`). Compiled from the
# REAL source both targets build. Outside the app target on purpose: this
# project has no test target. Run by hand after touching mutes:
#
#     iOS/RCQ/Tools/MuteScopeCheck/run.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
out=$(mktemp -d)
swiftc -O -swift-version 5 \
  "$root/RCQ/Services/AppGroup.swift" \
  "$root/RCQ/Services/RemovedContactsStore.swift" \
  "$here/main.swift" -o "$out/check"
"$out/check" "$root/RCQNotificationService/NotificationService.swift"

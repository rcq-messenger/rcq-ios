import Foundation

/// Shared App Group container for state that both the main app and the
/// `RCQNotificationService` extension need to read and write. As of
/// Stage 3 the only resident here is the libsignal protocol-store SQLite
/// (sessions, prekeys, sender keys) — the NSE has to be able to decrypt
/// `v=2` push envelopes and persist any newly-derived ratchet state
/// before the push is shown.
///
/// Identifier matches the value listed under
/// `com.apple.security.application-groups` in both targets'
/// entitlements (see project.yml). Hardcoded so we don't accidentally
/// drift between the entitlement file and the runtime lookup.
enum AppGroup {
    static let identifier = "group.app.rcq.shared"

    /// URL of the shared container's root. Force-unwrapped because a
    /// missing App Group entitlement is a build-time misconfiguration —
    /// crashing on first access surfaces the problem loudly instead of
    /// letting silently-degraded crypto ship.
    ///
    /// Resolved once per process. `containerURL(forSecurityApplicationGroupIdentifier:)`
    /// is a container lookup, not a string join, and this used to be a
    /// computed property that a dozen stores called on their way to a
    /// filename: MessageDB, BadgeCounter, RosterSnapshot, FavoritesStore,
    /// CrossIslandStore, the alias store, the vault. The path cannot change
    /// while the process lives, so caching it is free of semantics.
    static let containerURL: URL = {
        guard let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: identifier
        ) else {
            fatalError("App Group \(identifier) not available — check entitlements")
        }
        return url
    }()

    /// Shared dir for libsignal stores. Created on first access.
    static var signalStoreURL: URL {
        let dir = containerURL.appendingPathComponent("signal", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Plain file mirror of the user-picked app language. We use a flat
    /// file (not `UserDefaults(suiteName:)`) because cfprefsd is
    /// unreliable for App Group containers — iOS routinely logs
    /// "Couldn't read values in CFPrefsPlistSource ... detaching from
    /// cfprefsd" and silently stops sharing values across the main app
    /// and the NSE process. A single-line UTF-8 file under the shared
    /// container dodges that whole layer: write it from the main app
    /// when language changes, read it from the NSE on every push.
    static var languageFileURL: URL {
        containerURL.appendingPathComponent("language.txt")
    }

    /// Plain file mirror of the currently active `AccountManager.shared.active.id`.
    /// Same cfprefsd-unreliability dodge as `languageFileURL`. Written
    /// by the main app every time the active account changes; read by
    /// the NSE on every push so it knows which per-account Keychain
    /// prefix and MessageDB file to use.
    ///
    /// File contents: a single UUID string (no newline). Empty / absent
    /// file means "fresh install, no account yet" — NSE in that state
    /// falls back to a no-op (push is shown as a generic banner with
    /// no decrypt attempt).
    static var activeAccountIDFileURL: URL {
        containerURL.appendingPathComponent("active-account-id.txt")
    }

    /// In-process memo of the file below. Outer nil = never read yet.
    ///
    /// ⚠ ONLY the main app memoises. The NSE compiles this file too, and iOS
    /// keeps an extension process warm across consecutive pushes, so an
    /// account switch made in the app while that process is alive has to be
    /// visible to the next push: the extension keeps reading the file every
    /// time, exactly as before. In the main app `AccountManager` is the sole
    /// writer (via `writeActiveAccountID`) so the memo cannot go stale.
    private static let memoisesActiveAccountID: Bool =
        Bundle.main.bundleURL.pathExtension != "appex"
    private static let activeAccountIDLock = NSLock()
    private static var activeAccountIDMemo: UUID??

    /// Reads the active account ID from the App Group file. Returns
    /// nil if the file is missing, unreadable, or contains garbage.
    ///
    /// Called on every per-account Keychain hit through `KeychainStore.resolve`,
    /// which is dozens of times during a boot, plus once in the initialiser of
    /// most of the per-account stores. Each call was an open/read/close and a
    /// UUID parse; in the main app it is now one of those per launch.
    static func readActiveAccountID() -> UUID? {
        if memoisesActiveAccountID {
            activeAccountIDLock.lock()
            if let memo = activeAccountIDMemo {
                activeAccountIDLock.unlock()
                return memo
            }
            activeAccountIDLock.unlock()
        }
        let value = readActiveAccountIDFromDisk()
        if memoisesActiveAccountID {
            activeAccountIDLock.lock()
            activeAccountIDMemo = .some(value)
            activeAccountIDLock.unlock()
        }
        return value
    }

    private static func readActiveAccountIDFromDisk() -> UUID? {
        guard let data = try? Data(contentsOf: activeAccountIDFileURL),
              let raw = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        return UUID(uuidString: raw)
    }

    /// Atomically writes the active account ID to the App Group file.
    /// Called by AccountManager whenever active changes. Pass nil to
    /// clear (truly fresh install, no account exists).
    ///
    /// Skips the write when the file already holds this id: `AccountManager.init`
    /// calls this on every launch through `mirrorActiveToLegacy`, and the value
    /// changes about once in the life of an install. The read it does instead
    /// is served by the memo above from the second caller onwards.
    static func writeActiveAccountID(_ id: UUID?) {
        let url = activeAccountIDFileURL
        if let id {
            if readActiveAccountIDFromDisk() != id {
                try? id.uuidString.data(using: .utf8)?.write(to: url, options: .atomic)
            }
        } else if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        if memoisesActiveAccountID {
            activeAccountIDLock.lock()
            activeAccountIDMemo = .some(id)
            activeAccountIDLock.unlock()
        }
    }

    /// Plain file mirror of the FULL list of account IDs in the
    /// local roster, newline-separated. Sibling of `activeAccountIDFileURL`
    /// but for the multi-account NSE push-routing flow: when a push
    /// arrives the NSE needs to know which local accounts exist
    /// (not just which one is active) so it can find the account
    /// whose UIN matches the push payload's `to_uin`. Written by
    /// AccountManager on every roster mutation; read by NSE on
    /// every push.
    static var accountIDsFileURL: URL {
        containerURL.appendingPathComponent("account-ids.txt")
    }

    /// Returns the list of every account ID known to the main app.
    /// Cheap to call — the file is tiny (one UUID per line). Lines
    /// that don't parse as UUIDs are skipped silently.
    static func readAccountIDs() -> [UUID] {
        guard let data = try? Data(contentsOf: accountIDsFileURL),
              let text = String(data: data, encoding: .utf8)
        else { return [] }
        return text.split(separator: "\n")
            .compactMap { line -> UUID? in
                UUID(uuidString: line.trimmingCharacters(in: .whitespacesAndNewlines))
            }
    }

    /// Cross-process "do not render message content in a push" flag.
    ///
    /// The `RCQNotificationService` extension runs in its OWN process. It has no
    /// access to `PanicPINService`, so it has always titled a push with the real
    /// sender and printed the decrypted body — including while the app sat
    /// locked, and including while a DECOY session was up. A real person's name
    /// and a line of what they wrote appearing on the lock screen is exactly the
    /// leak the duress PIN exists to prevent, and it arrives without the coercer
    /// touching anything.
    ///
    /// ⚠ Deliberately covers BOTH "PIN-locked" and "decoy session". If it were
    /// set only under duress, its presence on disk — and the fact that previews
    /// went generic at the exact moment a particular PIN was entered — would
    /// itself be the tell. Locked and duress look identical from here.
    ///
    /// Flat file rather than `UserDefaults(suiteName:)` for the same
    /// cfprefsd-unreliability reason as `languageFileURL`.
    static var pushQuietFileURL: URL {
        containerURL.appendingPathComponent("push-quiet.txt")
    }

    /// True while the app is locked or in a decoy session. Absent file → false,
    /// which is the pre-existing behaviour for anyone with no PIN configured.
    static func pushQuiet() -> Bool {
        guard let data = try? Data(contentsOf: pushQuietFileURL),
              let raw = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        else { return false }
        return raw == "1"
    }

    /// Fails SAFE: if the write does not land the flag stays at whatever it was,
    /// and the only state we ever leave behind on a crash is `1` (quiet), which
    /// costs a few generic banners rather than leaking one.
    static func setPushQuiet(_ quiet: Bool) {
        let url = pushQuietFileURL
        if quiet {
            try? Data("1".utf8).write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Chats whose "ask for a PIN" is in force, for the notification extension:
    /// a JSON object from account id (`uuidString`) to that account's
    /// `LockedChatsStore` keys ("peer:<uin>", "group:<id>").
    ///
    /// #1045: the extension printed a locked chat's words on the lock screen
    /// while the chat itself sat behind the PIN, so the gate in front of it
    /// was worth nothing to anyone who could read the shade. The extension is
    /// a separate process and cannot see `LockedChatsStore` (plain
    /// UserDefaults), so the app writes the set here.
    ///
    /// Per account, because the store is: a uin locked under one account says
    /// nothing about the same number on another island. Written only while an
    /// app PIN exists: a lock with no PIN to ask for is not a lock, and the
    /// chat opens without one. Same flat-file reasoning as `pushQuietFileURL`.
    static var lockedChatsFileURL: URL {
        containerURL.appendingPathComponent("locked-chats.json")
    }

    /// The locks `accountID` holds. With no account (the push named none this
    /// device knows, or an older backend sent no `to_uin`) it is every
    /// account's locks together: the extension cannot tell whose chat it is,
    /// and hiding one message too many costs less than printing a locked one.
    /// Absent file → empty: nothing is locked.
    static func lockedChats(accountID: UUID?) -> Set<String> {
        guard let data = try? Data(contentsOf: lockedChatsFileURL),
              let map = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return [] }
        if let accountID { return Set(map[accountID.uuidString] ?? []) }
        return Set(map.values.joined())
    }

    static func setLockedChats(_ byAccount: [String: Set<String>]) {
        let url = lockedChatsFileURL
        let nonEmpty = byAccount.filter { !$0.value.isEmpty }.mapValues { $0.sorted() }
        if nonEmpty.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else if let data = try? JSONEncoder().encode(nonEmpty) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// The names of each account's own island, for the notification extension:
    /// a JSON object from account id (`uuidString`) to the hosts
    /// `Multihome.isOwnHost` takes as that island (lower case, the port only
    /// when it is not 443).
    ///
    /// Report 1071: the extension could not tell a sender on our island from
    /// one on another, so it could not run the cross-island gate the app runs.
    /// A message the app files under Requests (or drops) went up as a message
    /// from a contact, titled with whoever holds that number HERE, and opening
    /// the app showed nothing. Written by AccountManager with the roster.
    static var ownHostsFileURL: URL {
        containerURL.appendingPathComponent("own-hosts.json")
    }

    /// Nil when the app has not written the names of this account's island
    /// yet (or no account was named): the caller cannot tell, and keeps the
    /// rules it had before it could.
    static func ownHosts(accountID: UUID?) -> Set<String>? {
        guard let accountID,
              let data = try? Data(contentsOf: ownHostsFileURL),
              let map = try? JSONDecoder().decode([String: [String]].self, from: data),
              let names = map[accountID.uuidString], !names.isEmpty
        else { return nil }
        return Set(names)
    }

    /// `Multihome.normalizeHost` (IslandTrust's address rule), copied here
    /// because IslandTrust is not in the extension's target: the fragment off,
    /// the scheme and path ignored, the host in lower case and ASCII, an IPv6
    /// literal bracketed, the port only when it is not 443.
    /// `HTTPS://Is2.RCQ.app:443/` and `is2.rcq.app` are one island. Nil when
    /// there is no host in it. `Tools/OwnHostCheck` holds the two to the same
    /// answers.
    static func canonicalHost(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hash = s.firstIndex(of: "#") {
            s = String(s[..<hash]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !s.isEmpty else { return nil }
        let withScheme = s.contains("://") ? s : "https://\(s)"
        var host: String
        let port: Int
        if let url = URL(string: withScheme), let h = url.host, !h.isEmpty {
            host = h
            port = url.port ?? 443
        } else if let comps = URLComponents(string: withScheme),
                  let h = comps.encodedHost ?? comps.host, !h.isEmpty {
            host = h
            port = comps.port ?? 443
        } else {
            return nil
        }
        host = host.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        let bracketed = host.contains(":") ? "[\(host)]" : host
        return port == 443 ? bracketed : "\(bracketed):\(port)"
    }

    static func setOwnHosts(_ byAccount: [String: [String]]) {
        let url = ownHostsFileURL
        let nonEmpty = byAccount.filter { !$0.value.isEmpty }
        if nonEmpty.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(nonEmpty) else { return }
        // Written on every roster save; the file is read on every push, so an
        // unchanged one is left alone.
        if (try? Data(contentsOf: url)) == data { return }
        try? data.write(to: url, options: .atomic)
    }

    /// The same-island stranger quarantine (Privacy -> "Strangers go to
    /// requests"), for the notification extension: a JSON object from account
    /// id (`uuidString`) to that account's `QuarantineMirror`, present only for
    /// an account whose switch is on.
    ///
    /// The app files a content message from a number of our island that is
    /// not a contact, not let in and never written to under Requests
    /// (`StrangerQuarantine.shouldQuarantine`), and the extension, which saw
    /// none of that, printed the stranger's words on the lock screen anyway.
    /// Written by `StrangerQuarantine`; same flat-file reasoning as
    /// `pushQuietFileURL`.
    static var strangerQuarantineFileURL: URL {
        containerURL.appendingPathComponent("stranger-quarantine.json")
    }

    struct QuarantineMirror: Codable, Equatable {
        /// Strangers whose request was accepted (`StrangerQuarantine.allow`).
        var allowed: [Int]
        /// Whom the app lets through anyway: every contact, and every peer
        /// this account ever wrote to. Nil while the app has not had a live
        /// roster for this account: the app holds nobody without one (it fails
        /// open rather than eat messages blind), and so does the extension.
        var known: [Int]?

        /// Would the app hold a content message from `uin`, a number of our
        /// own island, under Requests?
        func holds(_ uin: Int) -> Bool {
            guard let known else { return false }
            return !allowed.contains(uin) && !known.contains(uin)
        }
    }

    /// Nil when the switch is off for `accountID`, or the app has not said.
    static func strangerQuarantine(accountID: UUID?) -> QuarantineMirror? {
        guard let accountID else { return nil }
        return readStrangerQuarantine()[accountID.uuidString]
    }

    /// `mirror` nil: the switch is off for this account. Entries of accounts
    /// no longer on the device are dropped on the way.
    static func setStrangerQuarantine(_ mirror: QuarantineMirror?, accountID: UUID) {
        var map = readStrangerQuarantine()
        map[accountID.uuidString] = mirror
        let onDevice = Set(readAccountIDs().map(\.uuidString))
        if !onDevice.isEmpty {
            map = map.filter { onDevice.contains($0.key) || $0.key == accountID.uuidString }
        }
        let url = strangerQuarantineFileURL
        if map.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(map) else { return }
        if (try? Data(contentsOf: url)) == data { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func readStrangerQuarantine() -> [String: QuarantineMirror] {
        guard let data = try? Data(contentsOf: strangerQuarantineFileURL),
              let map = try? JSONDecoder().decode([String: QuarantineMirror].self, from: data)
        else { return [:] }
        return map
    }

    /// Atomically writes the account ID list to the App Group file.
    /// AccountManager calls this from save() so the on-disk file
    /// always matches the in-memory roster.
    static func writeAccountIDs(_ ids: [UUID]) {
        let url = accountIDsFileURL
        if ids.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let text = ids.map { $0.uuidString }.joined(separator: "\n")
        try? text.data(using: .utf8)?.write(to: url, options: .atomic)
    }
}

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

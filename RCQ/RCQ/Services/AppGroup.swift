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
    static var containerURL: URL {
        guard let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: identifier
        ) else {
            fatalError("App Group \(identifier) not available — check entitlements")
        }
        return url
    }

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

    /// Reads the active account ID from the App Group file. Returns
    /// nil if the file is missing, unreadable, or contains garbage.
    /// Cheap to call repeatedly — the file is tiny.
    static func readActiveAccountID() -> UUID? {
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
    static func writeActiveAccountID(_ id: UUID?) {
        let url = activeAccountIDFileURL
        if let id {
            try? id.uuidString.data(using: .utf8)?.write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
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

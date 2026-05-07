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
}

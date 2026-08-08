import Foundation

/// Tiny App Group-shared cache of `uin → nickname` so the
/// `RCQNotificationService` extension can render the actual sender
/// name on the lock screen instead of falling back to a UIN. The main
/// app refreshes this whenever it loads `/contacts`; the NSE reads it
/// once per push and never writes.
///
/// Backed by `UserDefaults(suiteName: AppGroup.identifier)` because:
///   - it's tiny (each entry is ~40 bytes)
///   - we already have the App Group entitlement on both targets
///   - UserDefaults handles cross-process atomicity for us
///
/// We don't try to keep this strictly in sync — a stale entry just
/// shows the previous nickname for a few minutes after a peer renames
/// themselves, which is fine. The cache wipes on burn-account.
enum NicknameCache {
    private static let storageKey = "rcq.nicknames"

    private static var defaults: UserDefaults? {
        return UserDefaults(suiteName: AppGroup.identifier)
    }

    /// Map of `String(uin) → nickname`. UserDefaults is happiest with
    /// JSON-friendly types, so we keep keys as strings.
    static func nickname(for uin: Int) -> String? {
        let dict = (defaults?.dictionary(forKey: storageKey) as? [String: String]) ?? [:]
        return dict[String(uin)]
    }

    /// Replace the entire cache. Called from the contact-list refresh
    /// in the main app so the NSE always sees a roughly current map.
    static func setAll(_ pairs: [Int: String]) {
        var asStrings: [String: String] = [:]
        for (uin, name) in pairs { asStrings[String(uin)] = name }
        defaults?.set(asStrings, forKey: storageKey)
    }

    /// Add or update a single entry without rewriting the whole map.
    /// Used by ad-hoc paths (e.g. group-info refresh) so we don't lose
    /// the rest of the cache.
    static func upsert(uin: Int, nickname: String) {
        var dict = (defaults?.dictionary(forKey: storageKey) as? [String: String]) ?? [:]
        dict[String(uin)] = nickname
        defaults?.set(dict, forKey: storageKey)
    }

    /// Clear the cache. Called from `AppState.burnAccount()`.
    static func wipe() {
        defaults?.removeObject(forKey: storageKey)
    }
}

/// App Group-shared cache of `group id → group name`, so the NSE can title a
/// group-message push with the GROUP'S name instead of just the sender (a
/// founder ask). Same UserDefaults-backed, best-effort-stale approach as
/// `NicknameCache`: the main app rewrites it on every `/groups` refresh, the
/// NSE only reads. A stale name just shows the previous group title briefly.
enum GroupNameCache {
    private static let storageKey = "rcq.group_names"

    private static var defaults: UserDefaults? {
        return UserDefaults(suiteName: AppGroup.identifier)
    }

    static func name(for groupID: Int) -> String? {
        let dict = (defaults?.dictionary(forKey: storageKey) as? [String: String]) ?? [:]
        return dict[String(groupID)]
    }

    /// Replace the whole map. Called from `GroupService.refresh()`.
    static func setAll(_ pairs: [Int: String]) {
        var asStrings: [String: String] = [:]
        for (gid, name) in pairs { asStrings[String(gid)] = name }
        defaults?.set(asStrings, forKey: storageKey)
    }

    static func wipe() {
        defaults?.removeObject(forKey: storageKey)
    }
}

/// App Group-shared avatar thumbnails, so a system notification can carry the
/// sender's picture (`INSendMessageIntent`) instead of the app icon.
///
/// ⚠ Lives in this file on purpose: it is compiled into BOTH the app and the
/// notification-service extension, and this file already is. A new file would
/// have to be added to both targets by hand in the project, which is exactly
/// the kind of edit that silently ends up in one of them.
///
/// Written lazily by the app whenever it has actually decrypted someone's
/// avatar (see PersonAvatarView), so the extension gets a picture for the
/// people the user has looked at, and nobody's avatar is fetched or decrypted
/// just to fill a cache. A thumbnail is a small JPEG on disk in the shared
/// container; the cache is wiped with the account.
enum AvatarThumbCache {
    private static var dir: URL? {
        guard let base = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppGroup.identifier
        ) else { return nil }
        let d = base.appendingPathComponent("avatar-thumbs", isDirectory: true)
        if !FileManager.default.fileExists(atPath: d.path) {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        return d
    }

    private static func url(_ uin: Int) -> URL? {
        dir?.appendingPathComponent("\(uin).jpg")
    }

    /// Raw JPEG for [uin], or nil when we have never rendered their avatar.
    static func data(for uin: Int) -> Data? {
        guard let u = url(uin) else { return nil }
        return try? Data(contentsOf: u)
    }

    /// Store a thumbnail. Overwrites; callers pass an already-small image.
    static func store(_ jpeg: Data, for uin: Int) {
        guard let u = url(uin) else { return }
        try? jpeg.write(to: u, options: .atomic)
    }

    static func wipe() {
        guard let d = dir else { return }
        try? FileManager.default.removeItem(at: d)
    }
}

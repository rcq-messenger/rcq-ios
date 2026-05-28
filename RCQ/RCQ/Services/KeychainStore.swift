import Foundation
import Security

/// Tiny Keychain wrapper for the UIN, JWT token and Signal identity material.
///
/// Uses a **shared access group** so both the main app and the
/// `RCQNotificationService` extension read the same keys. The NSE needs
/// the X25519 + Ed25519 private halves to decrypt incoming push
/// envelopes before iOS displays the alert — without shared access it
/// would fall back to showing "New message" generic.
///
/// Group format `<TeamID>.<reverse-DNS>.shared`. `$(AppIdentifierPrefix)`
/// in the entitlement file expands to the team ID at sign time, so
/// hard-coding `P29Q334JHX` here matches what both targets ship with.
///
/// ## Per-account namespacing (v0.3+)
///
/// Identity material is per-account: a device with two accounts on
/// two different servers has two UINs, two JWTs, two X25519 keypairs
/// etc. Per-account keys live under the prefix
/// `acct.<uuid>.<original-key>` where `<uuid>` is `Account.id` of
/// whichever account the entry belongs to. Global keys (PIN material
/// is app-lock, not per-account) keep their unprefixed form.
///
/// Lookup resolves the current account ID via
/// `AppGroup.readActiveAccountID()` — a flat file in the shared App
/// Group container, written by `AccountManager` on every active
/// change. NSE reads the same file. Pre-v0.3 installs see an empty
/// file (no migration yet) and fall through to legacy unprefixed
/// keys until `migrateLegacyKeysToAccount(_:)` runs, which copies
/// every legacy entry under the new prefix and deletes the
/// originals.
enum KeychainStore {
    private static let service = "app.rcq.identity"
    /// Must match the `keychain-access-groups` entitlement on both
    /// `RCQ` and `RCQNotificationService` targets.
    private static let accessGroup = "P29Q334JHX.app.rcq.shared"

    /// Keys whose values are different per account. Looked up under
    /// `acct.<accountID>.<key>`. Anything not in this set is treated
    /// as global and uses the raw key.
    ///
    /// PIN material (`pinPepper`, `pinAttempts`) is deliberately
    /// global because the PIN locks the entire app, not one account.
    /// Switching account doesn't change which PIN is asked.
    private static let perAccountKeys: Set<String> = [
        Keys.uin,
        Keys.token,
        Keys.nickname,
        Keys.identityPriv,
        Keys.signingPriv,
    ]

    // MARK: - Public API (auto-routes per-account vs global)

    static func set(_ key: String, _ data: Data) {
        rawSet(resolve(key), data)
    }

    static func data(_ key: String) -> Data? {
        let resolved = resolve(key)
        if let value = rawData(resolved) {
            return value
        }
        // Lazy migration safety net: if the per-account prefixed
        // key isn't found but the legacy unprefixed key still has a
        // value, return the legacy value. This handles the brief
        // window between `AccountManager.migrateLegacyIfPresent`
        // creating Account[0] and `migrateLegacyKeysToAccount`
        // having had a chance to copy keys across, which can
        // happen if a read races the migration on first launch.
        // Doesn't write to the prefixed slot from here (avoids
        // double-migration); the explicit migration call still
        // copies + deletes as designed.
        if perAccountKeys.contains(key), resolved != key {
            return rawData(key)
        }
        return nil
    }

    static func string(_ key: String) -> String? {
        data(key).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func setString(_ key: String, _ value: String) {
        set(key, Data(value.utf8))
    }

    static func delete(_ key: String) {
        // Delete both the per-account prefixed form AND the legacy
        // unprefixed form. For per-account keys this scrubs both
        // during a burn so no stale legacy entry survives a
        // burn → fresh-install cycle.
        rawDelete(resolve(key))
        if perAccountKeys.contains(key) {
            rawDelete(key)
        }
    }

    // MARK: - Per-account migration

    /// Copy every per-account legacy unprefixed Keychain entry to the
    /// `acct.<accountID>.<key>` prefixed form, then delete the
    /// unprefixed original. Called by `AccountManager` from
    /// `migrateLegacyIfPresent` right after minting Account[0], so
    /// existing TF57 testers' identity material lands on Account[0]'s
    /// prefix without ceremony.
    ///
    /// Idempotent: if no legacy entries exist (fresh install, already
    /// migrated), this is a no-op. Order-safe: subsequent reads via
    /// `string(_:)` etc resolve to the prefixed slot directly.
    static func migrateLegacyKeysToAccount(_ accountID: UUID) {
        for key in perAccountKeys {
            guard let legacy = rawData(key) else { continue }
            let prefixed = "acct.\(accountID.uuidString).\(key)"
            rawSet(prefixed, legacy)
            rawDelete(key)
        }
    }

    /// Wipe every per-account Keychain entry belonging to a given
    /// account. Used by burn-account flows to leave no remnants of
    /// the burned identity. PIN / global keys untouched.
    static func wipeAccount(_ accountID: UUID) {
        for key in perAccountKeys {
            rawDelete("acct.\(accountID.uuidString).\(key)")
        }
    }

    // MARK: - Internal

    /// Resolve a logical key name to the actual Keychain account
    /// string. Per-account keys get the active account's prefix;
    /// global keys pass through. When no active account is set
    /// (truly fresh install before onboarding), per-account keys
    /// fall back to the raw unprefixed form — that's the bootstrap
    /// window between app launch and first onboarding registration.
    private static func resolve(_ key: String) -> String {
        guard perAccountKeys.contains(key) else { return key }
        guard let id = AppGroup.readActiveAccountID() else { return key }
        return "acct.\(id.uuidString).\(key)"
    }

    private static func rawSet(_ key: String, _ data: Data) {
        let q: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecAttrAccessGroup: accessGroup,
        ]
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData] = data
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func rawData(_ key: String) -> Data? {
        let q: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecAttrAccessGroup: accessGroup,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func rawDelete(_ key: String) {
        let q: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecAttrAccessGroup: accessGroup,
        ]
        SecItemDelete(q as CFDictionary)
    }

    enum Keys {
        static let uin = "uin"
        static let token = "token"
        static let nickname = "nickname"
        /// Raw 32-byte X25519 private key for ECDH. Public half lives on the
        /// server as `users.identity_key`.
        static let identityPriv = "rcq.identity.priv"
        /// Raw 32-byte Ed25519 private key for sender-authentication.
        /// Public half lives on the server as `users.signing_key`.
        static let signingPriv = "rcq.signing.priv"
        static let pinPepper = "rcq.pin.pepper"
        static let pinAttempts = "rcq.pin.attempts"
    }
}

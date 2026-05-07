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
enum KeychainStore {
    private static let service = "app.rcq.identity"
    /// Must match the `keychain-access-groups` entitlement on both
    /// `RCQ` and `RCQNotificationService` targets.
    private static let accessGroup = "P29Q334JHX.app.rcq.shared"

    static func set(_ key: String, _ data: Data) {
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

    static func data(_ key: String) -> Data? {
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

    static func string(_ key: String) -> String? {
        data(key).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func setString(_ key: String, _ value: String) {
        set(key, Data(value.utf8))
    }

    static func delete(_ key: String) {
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
    }
}

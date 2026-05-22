import Foundation
import LocalAuthentication
import Security

enum BiometricUnlock {
    private static let service = "app.rcq.identity"
    private static let account = "rcq.pin.biometric"

    static var isAvailable: Bool {
        var err: NSError?
        return LAContext().canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics, error: &err
        )
    }

    static var isEnabled: Bool {
        let ctx = LAContext()
        ctx.interactionNotAllowed = true
        let q: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecUseAuthenticationContext: ctx,
            kSecReturnData: true,
        ]
        let status = SecItemCopyMatching(q as CFDictionary, nil)
        return status == errSecInteractionNotAllowed || status == errSecSuccess
    }

    @discardableResult
    static func enable(payload: Data) -> Bool {
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            .biometryCurrentSet,
            nil
        ) else { return false }
        let base: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecAttrAccessControl] = access
        add[kSecValueData] = payload
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func disable() {
        let q: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(q as CFDictionary)
    }

    static func read(reason: String) async -> Data? {
        await Task.detached(priority: .userInitiated) { () -> Data? in
            let ctx = LAContext()
            ctx.localizedReason = reason
            let q: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
                kSecReturnData: true,
                kSecMatchLimit: kSecMatchLimitOne,
                kSecUseAuthenticationContext: ctx,
            ]
            var item: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess else {
                return nil
            }
            return item as? Data
        }.value
    }
}

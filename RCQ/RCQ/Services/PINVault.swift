import CommonCrypto
import CryptoKit
import Foundation

enum PINVault {
    // MARK: - file layout

    private static let version: UInt8 = 2
    private static let saltLen = 16
    private static let payloadLen = 320
    private static let slotLen = 12 + payloadLen + 16
    private static let slotCount = 3
    private static let kdfRounds: UInt32 = 400_000

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("pin-vault.bin")
    }

    // MARK: - public model

    enum Mode: Int, Codable {
        case real = 1
        case decoy = 2
        case wipe = 3
    }

    struct Layout: Codable {
        var realSlot: Int
        var decoySlot: Int?
        var decoyDataKey: Data?
        var decoyUIN: Int?
        var decoyNickname: String?
        var wipeSlot: Int?
    }

    struct SlotPayload: Codable {
        var mode: Mode
        var dataKey: Data?
        var layout: Layout?
        var decoyUIN: Int?
        var decoyNickname: String?
    }

    struct Unlock {
        let payload: SlotPayload
        let slotKey: SymmetricKey
    }

    static var isConfigured: Bool {
        readVault() != nil
    }

    static func vaultSalt() -> Data? {
        readVault()?.salt
    }

    // MARK: - errors

    enum VaultError: Error {
        case payloadTooLarge
        case corrupt
        case noVault
    }

    // MARK: - KDF

    static func deriveKey(pin: String, salt: Data) -> SymmetricKey {
        var secret = Array(pin.utf8)
        secret.append(contentsOf: [UInt8](pepperData()))
        let saltBytes = [UInt8](salt)
        var out = Data(count: 32)
        out.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) in
            _ = CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                secret, secret.count,
                saltBytes, saltBytes.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                kdfRounds,
                buf.bindMemory(to: UInt8.self).baseAddress, 32
            )
        }
        return SymmetricKey(data: out)
    }

    // MARK: - slot crypto

    static func sealSlot(_ payload: SlotPayload, key: SymmetricKey) throws -> Data {
        let json = try JSONEncoder().encode(payload)
        guard json.count + 2 <= payloadLen else { throw VaultError.payloadTooLarge }
        var plaintext = Data()
        plaintext.append(UInt8(json.count >> 8))
        plaintext.append(UInt8(json.count & 0xFF))
        plaintext.append(json)
        plaintext.append(randomBytes(payloadLen - plaintext.count))
        let box = try AES.GCM.seal(plaintext, using: key)
        guard let combined = box.combined else { throw VaultError.corrupt }
        return combined
    }

    static func openSlot(_ data: Data, key: SymmetricKey) -> SlotPayload? {
        guard data.count == slotLen,
              let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key),
              plain.count >= 2 else { return nil }
        let len = Int(plain[plain.startIndex]) << 8 | Int(plain[plain.startIndex + 1])
        guard len > 0, 2 + len <= plain.count else { return nil }
        let json = plain.subdata(in: (plain.startIndex + 2)..<(plain.startIndex + 2 + len))
        return try? JSONDecoder().decode(SlotPayload.self, from: json)
    }

    // MARK: - file read / write

    private struct VaultFile {
        var salt: Data
        var slots: [Data]   // exactly `slotCount`, each `slotLen` bytes
    }

    private static func readVault() -> VaultFile? {
        guard let raw = try? Data(contentsOf: fileURL) else { return nil }
        let expected = 1 + saltLen + slotCount * slotLen
        guard raw.count == expected, raw[raw.startIndex] == version else { return nil }
        var off = raw.startIndex + 1
        let salt = raw.subdata(in: off..<(off + saltLen))
        off += saltLen
        var slots: [Data] = []
        for _ in 0..<slotCount {
            slots.append(raw.subdata(in: off..<(off + slotLen)))
            off += slotLen
        }
        return VaultFile(salt: salt, slots: slots)
    }

    private static func writeVault(_ v: VaultFile) throws {
        var raw = Data([version])
        raw.append(v.salt)
        for s in v.slots { raw.append(s) }
        try raw.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }

    // MARK: - high-level operations

    @discardableResult
    static func createWithRealPIN(_ pin: String) throws -> Unlock {
        ensurePepper(regenerate: true)
        let salt = randomBytes(saltLen)
        let realSlot = Int.random(in: 0..<slotCount)
        let dataKey = randomBytes(32)
        let layout = Layout(realSlot: realSlot, decoySlot: nil, decoyDataKey: nil, wipeSlot: nil)
        let payload = SlotPayload(mode: .real, dataKey: dataKey, layout: layout)
        let key = deriveKey(pin: pin, salt: salt)

        var slots = (0..<slotCount).map { _ in randomBytes(slotLen) }
        slots[realSlot] = try sealSlot(payload, key: key)
        try writeVault(VaultFile(salt: salt, slots: slots))
        return Unlock(payload: payload, slotKey: key)
    }

    static func unlock(pin: String) -> Unlock? {
        guard let vault = readVault() else { return nil }
        let key = deriveKey(pin: pin, salt: vault.salt)
        for slot in vault.slots {
            if let payload = openSlot(slot, key: key) {
                return Unlock(payload: payload, slotKey: key)
            }
        }
        return nil
    }

    static func writeSlot(index: Int, payload: SlotPayload?, key: SymmetricKey?) throws {
        guard var vault = readVault() else { throw VaultError.noVault }
        guard (0..<slotCount).contains(index) else { throw VaultError.corrupt }
        if let payload, let key {
            vault.slots[index] = try sealSlot(payload, key: key)
        } else {
            vault.slots[index] = randomBytes(slotLen)
        }
        try writeVault(vault)
    }

    static func freeSlotIndex(layout: Layout) -> Int? {
        let used = Set([layout.realSlot, layout.decoySlot, layout.wipeSlot].compactMap { $0 })
        return (0..<slotCount).first { !used.contains($0) }
    }

    static func destroy() {
        try? FileManager.default.removeItem(at: fileURL)
        KeychainStore.delete(KeychainStore.Keys.pinPepper)
        KeychainStore.delete(KeychainStore.Keys.pinAttempts)
    }

    // MARK: - brute-force throttle

    struct AttemptState: Codable {
        var failedCount: Int = 0
        var lockoutUntil: Date?
    }

    static func loadAttemptState() -> AttemptState {
        guard let d = KeychainStore.data(KeychainStore.Keys.pinAttempts),
              let s = try? JSONDecoder().decode(AttemptState.self, from: d) else {
            return AttemptState()
        }
        return s
    }

    static func saveAttemptState(_ s: AttemptState) {
        if let d = try? JSONEncoder().encode(s) {
            KeychainStore.set(KeychainStore.Keys.pinAttempts, d)
        }
    }

    static func clearAttemptState() {
        KeychainStore.delete(KeychainStore.Keys.pinAttempts)
    }

    // MARK: - pepper

    private static func ensurePepper(regenerate: Bool) {
        if regenerate || KeychainStore.data(KeychainStore.Keys.pinPepper) == nil {
            KeychainStore.set(KeychainStore.Keys.pinPepper, randomBytes(32))
        }
    }

    private static func pepperData() -> Data {
        if let p = KeychainStore.data(KeychainStore.Keys.pinPepper) { return p }
        let p = randomBytes(32)
        KeychainStore.set(KeychainStore.Keys.pinPepper, p)
        return p
    }

    // MARK: - randomness

    private static func randomBytes(_ count: Int) -> Data {
        var d = Data(count: count)
        let ok = d.withUnsafeMutableBytes { buf -> Bool in
            guard let base = buf.baseAddress else { return false }
            return SecRandomCopyBytes(kSecRandomDefault, count, base) == errSecSuccess
        }
        precondition(ok, "SecRandomCopyBytes failed")
        return d
    }
}

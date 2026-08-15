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
        // ⚠ NOTHING MAY BE ADDED TO THIS STRUCT. The real slot is the tightest
        // of the three and `maximumPayloadJSONSize()` measures it at 315 of the
        // 320-byte box: five bytes of headroom. The margin is eaten by
        // `dataKey` + `decoyDataKey`, whose base64 can be up to 43 '/'
        // characters each and JSONEncoder escapes every one of them as "\/".
        // Even a one-letter key with a boolean (`,"w":true`, 9 bytes)
        // overflows that case, and an overflow means sealSlot throws and the
        // user simply cannot set a decoy or wipe PIN. Put new state in the
        // slot it belongs to instead — the decoy and wipe payloads are at 160
        // and 36 bytes and have room to spare.
    }

    struct SlotPayload: Codable {
        var mode: Mode
        var dataKey: Data?
        var layout: Layout?
        var decoyUIN: Int?
        var decoyNickname: String?
        /// Wipe slot only: also erase the account on the server, not just this
        /// device. Absent (old slot written before the option existed) decodes
        /// as nil and is read as FALSE — which is what the UI always promised.
        /// Deliberately NOT in UserDefaults: those are readable and writable
        /// without any PIN, so anyone holding an unlocked phone could flip it.
        var wipeDeleteServer: Bool?
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

    /// Re-seal whichever slot `oldKey` currently opens under a key derived from
    /// `newPIN`, keeping `payload` (dataKey unchanged → the store is not
    /// re-encrypted). Used to change the DECOY PIN from within a duress session
    /// WITHOUT the real slot key — the caller holds only the decoy slot's key.
    /// Rejects a `newPIN` that opens a DIFFERENT existing slot (a collision
    /// could make the new decoy PIN accidentally match the real slot). Returns
    /// the new derived key on success, or nil (slot not found / collision).
    static func reSealUnderNewPIN(oldKey: SymmetricKey, payload: SlotPayload, newPIN: String) -> SymmetricKey? {
        guard var vault = readVault() else { return nil }
        guard let idx = vault.slots.firstIndex(where: { openSlot($0, key: oldKey) != nil }) else { return nil }
        let newKey = deriveKey(pin: newPIN, salt: vault.salt)
        for (i, slot) in vault.slots.enumerated() where i != idx {
            if openSlot(slot, key: newKey) != nil { return nil }
        }
        guard let sealed = try? sealSlot(payload, key: newKey) else { return nil }
        vault.slots[idx] = sealed
        guard (try? writeVault(vault)) != nil else { return nil }
        return newKey
    }

    static func freeSlotIndex(layout: Layout) -> Int? {
        let used = Set([layout.realSlot, layout.decoySlot, layout.wipeSlot].compactMap { $0 })
        return (0..<slotCount).first { !used.contains($0) }
    }

    /// Erase every copy of what the vault held. The biometric fast-path stores a
    /// FULL COPY of the real slot payload — `dataKey` included — in its own
    /// Keychain item (`rcq.pin.biometric`), and nothing here used to touch it.
    /// After a vault reset Face ID handed that dead key straight back and the
    /// app configured MessageDB with it, so unlocking biometrically decrypted
    /// nothing and re-encrypted new rows under a key no PIN could ever derive.
    /// Deleting the file without deleting that item is not a reset.
    static func destroy() {
        try? FileManager.default.removeItem(at: fileURL)
        KeychainStore.delete(KeychainStore.Keys.pinPepper)
        KeychainStore.delete(KeychainStore.Keys.pinAttempts)
        BiometricUnlock.disable()
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

    // MARK: - payload budget self-check

    /// R2 guard: every slot is a FIXED `payloadLen` box, and `sealSlot` throws
    /// `payloadTooLarge` the moment the JSON stops fitting. A slot that cannot
    /// be written is a PIN that cannot be set; a FORMAT change to make room
    /// makes `readVault` return nil, which the app reads as "no PIN set" and
    /// every existing history becomes unreadable ciphertext. So the budget is
    /// checked here, at every field's worst case, rather than discovered by a
    /// user with a long decoy nickname.
    ///
    /// Returns the largest sealed payload size in bytes (JSON + the 2-byte
    /// length prefix `sealSlot` writes), or nil if it no longer fits. Any new
    /// field must be added to the worst case below.
    ///
    /// The dominant term is NOT the field list, it is `dataKey` /
    /// `decoyDataKey`: 32 random bytes base64 to 44 characters, and every '/'
    /// among them is escaped by JSONEncoder as "\\/". An all-0xFF key is 43
    /// slashes, so the two keys alone can swing the payload by 84 bytes. That
    /// is the case measured here, because it is reachable — the keys are random
    /// and nothing stops one from coming out that way.
    static func maximumPayloadJSONSize() -> Int? {
        let maxKey = Data(repeating: 0xFF, count: 32)
        // Nicknames here are GENERATED, never user-typed: randomDecoyNickname()
        // yields "user-" + 4 digits, always 9 characters. There is no slack to
        // budget on top of that — at 9 the real slot already lands on 315 of
        // 320 — so anything that makes decoy nicknames longer or user-supplied
        // has to be measured against this before it ships.
        let maxNick = String(repeating: "W", count: 9)
        let layout = Layout(
            realSlot: 2, decoySlot: 1, decoyDataKey: maxKey,
            decoyUIN: 999_999_999, decoyNickname: maxNick, wipeSlot: 0
        )
        let candidates: [SlotPayload] = [
            SlotPayload(mode: .real, dataKey: maxKey, layout: layout),
            SlotPayload(mode: .decoy, dataKey: maxKey, layout: nil,
                        decoyUIN: 999_999_999, decoyNickname: maxNick),
            SlotPayload(mode: .wipe, dataKey: nil, layout: nil, wipeDeleteServer: true),
        ]
        var worst = 0
        for p in candidates {
            guard let json = try? JSONEncoder().encode(p) else { return nil }
            worst = max(worst, json.count + 2)
        }
        return worst <= payloadLen ? worst : nil
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

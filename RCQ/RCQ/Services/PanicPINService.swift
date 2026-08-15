import CryptoKit
import Foundation
import SwiftUI

@MainActor
final class PanicPINService: ObservableObject {
    static let shared = PanicPINService()

    enum LockState { case unlocked, locked }
    enum SessionMode { case none, real, decoy }

    /// `.wipe` carries the wipe slot's own server-erase flag. It is read out of
    /// the slot the entered PIN just opened — never from prefs — so the choice
    /// cannot be flipped by anyone who has the phone but not the real PIN.
    enum SubmitResult {
        case unlockedReal
        case unlockedDecoy
        case wipe(deleteServerAccount: Bool)
        case wrong
        case lockedOut(until: Date)
    }

    static func lockoutDuration(forFailedCount n: Int) -> TimeInterval {
        switch n {
        case ..<5:  return 0
        case 5:     return 30
        case 6:     return 60
        case 7:     return 300
        case 8:     return 900
        default:    return 3600
        }
    }

    enum PINError: LocalizedError {
        case notRealSession
        case pinInUse
        case pinTooShort
        case noFreeSlot
        case vaultMissing
        case biometricConflict
        case biometricFailed

        var errorDescription: String? {
            switch self {
            case .notRealSession:    return "Not in a real session."
            case .pinInUse:          return "panic_pin.error.in_use".localized
            case .pinTooShort:       return "panic_pin.error.too_short".localized
            case .noFreeSlot:        return "No free PIN slot."
            case .vaultMissing:      return "PIN vault missing."
            case .biometricConflict: return "panic_pin.error.biometric_conflict".localized
            case .biometricFailed:   return "panic_pin.error.biometric_failed".localized
            }
        }
    }

    static let minPINLength = 4

    @Published private(set) var lockState: LockState
    @Published private(set) var mode: SessionMode = .none
    @Published private(set) var biometricEnabled: Bool
    @Published private(set) var lockoutUntil: Date?

    /// Re-lock grace in SECONDS (#10): how long the app can sit backgrounded
    /// before it asks for the PIN again on return. 0 = immediately. Default 30
    /// preserves the old hardcoded behaviour; user-configurable in PIN settings.
    @Published var lockTimeout: Int {
        didSet { UserDefaults.standard.set(lockTimeout, forKey: Self.lockTimeoutKey) }
    }
    private static let lockTimeoutKey = "rcq.pin.lock_timeout"

    var biometricAvailable: Bool { BiometricUnlock.isAvailable }

    var isConfigured: Bool { PINVault.isConfigured }
    var isDecoy: Bool { mode == .decoy }
    var isLocked: Bool { lockState == .locked }

    var hasDecoyPIN: Bool { realPayload?.layout?.decoySlot != nil }
    var hasWipePIN: Bool { realPayload?.layout?.wipeSlot != nil }

    private(set) var dataKey: SymmetricKey?

    @Published private var realPayload: PINVault.SlotPayload?
    private var realSlotKey: SymmetricKey?

    // Decoy session custody (report #237): while unlocked into the decoy view
    // we keep the decoy slot's payload + derived key so a "change PIN" from
    // that view re-seals the DECOY slot only — never the real one, whose key we
    // deliberately do not hold in a decoy session. Both nil in a real session.
    private var decoyPayload: PINVault.SlotPayload?
    private var decoySlotKey: SymmetricKey?

    private init() {
        lockState = PINVault.isConfigured ? .locked : .unlocked
        biometricEnabled = BiometricUnlock.isEnabled
        let until = PINVault.loadAttemptState().lockoutUntil
        lockoutUntil = (until ?? .distantPast) > Date() ? until : nil
        // Default 30s = the old hardcoded grace; absent key → 30.
        lockTimeout = UserDefaults.standard.object(forKey: Self.lockTimeoutKey) as? Int ?? 30
    }

    // MARK: - unlock / lock

    func submit(pin: String) async -> SubmitResult {
        if let until = lockoutUntil, until > Date() {
            return .lockedOut(until: until)
        }

        let unlock = await Task.detached(priority: .userInitiated) {
            PINVault.unlock(pin: pin)
        }.value
        guard let unlock else {
            var state = PINVault.loadAttemptState()
            state.failedCount += 1
            let delay = Self.lockoutDuration(forFailedCount: state.failedCount)
            state.lockoutUntil = delay > 0 ? Date().addingTimeInterval(delay) : nil
            PINVault.saveAttemptState(state)
            lockoutUntil = state.lockoutUntil
            return .wrong
        }
        PINVault.clearAttemptState()
        lockoutUntil = nil

        switch unlock.payload.mode {
        case .real:
            realPayload = unlock.payload
            realSlotKey = unlock.slotKey
            guard let keyData = unlock.payload.dataKey else { return .wrong }
            dataKey = SymmetricKey(data: keyData)
            mode = .real
            MessageDB.shared.configure(decoy: false, dataKey: dataKey)
            MessageStore.shared.reloadFromDB()
            lockState = .unlocked
            return .unlockedReal

        case .decoy:
            realPayload = nil
            realSlotKey = nil
            decoyPayload = unlock.payload
            decoySlotKey = unlock.slotKey
            guard let keyData = unlock.payload.dataKey else { return .wrong }
            dataKey = SymmetricKey(data: keyData)
            mode = .decoy
            let decoyUIN = unlock.payload.decoyUIN ?? Self.randomDecoyUIN()
            let decoyNick = unlock.payload.decoyNickname ?? Self.randomDecoyNickname()
            AuthService.shared.applyDecoyIdentity(uin: decoyUIN, nickname: decoyNick)
            PresenceService.shared.status = .online
            PresenceService.shared.statusMessage = nil
            MessageDB.shared.configure(decoy: true, dataKey: dataKey)
            MessageStore.shared.reloadFromDB()
            // Roster first, then the seeded rows it names. An unseeded decoy
            // loads an empty list, exactly as before.
            let seeded = dataKey.map { DecoySeedStore.load(key: $0) } ?? []
            if seeded.isEmpty {
                ContactService.shared.clearForDecoy()
            } else {
                ContactService.shared.applyDecoySeed(seeded)
            }
            GroupService.shared.clearForDecoy()
            lockState = .unlocked
            return .unlockedDecoy

        case .wipe:
            // Absent flag (slot written before the option existed) → false,
            // which is what every locale's wipe copy has always promised.
            return .wipe(deleteServerAccount: unlock.payload.wipeDeleteServer ?? false)
        }
    }

    func verifyRealPIN(_ pin: String) async -> Bool {
        let unlock = await Task.detached(priority: .userInitiated) {
            PINVault.unlock(pin: pin)
        }.value
        return unlock?.payload.mode == .real
    }

    /// Verify the pin for the CURRENT session: the real pin in a real session,
    /// the decoy pin in a decoy session. Used to re-gate PIN settings so a
    /// coercer in the decoy view can re-enter their (decoy) pin plausibly
    /// instead of it failing as "wrong" — which would betray a second pin.
    func verifySessionPIN(_ pin: String) async -> Bool {
        let unlock = await Task.detached(priority: .userInitiated) {
            PINVault.unlock(pin: pin)
        }.value
        guard let unlock else { return false }
        return mode == .decoy ? unlock.payload.mode == .decoy : unlock.payload.mode == .real
    }

    /// True while unlocked into the decoy (duress) view.
    var inDecoySession: Bool { mode == .decoy }

    /// Change the PIN from within a decoy session: re-seal the DECOY slot under
    /// `pin`. The real slot is untouched, so the hidden real identity stays
    /// hidden and its pin unchanged. Rejects a `pin` that collides with another
    /// slot. Report #237: a coercer given the decoy pin can change "their" pin
    /// without it ever exposing — or hinting at — the real account.
    func changeDecoyPIN(_ pin: String) async throws {
        guard pin.count >= Self.minPINLength else { throw PINError.pinTooShort }
        guard mode == .decoy, let payload = decoyPayload, let oldKey = decoySlotKey else {
            throw PINError.notRealSession
        }
        let newKey = await Task.detached(priority: .userInitiated) {
            PINVault.reSealUnderNewPIN(oldKey: oldKey, payload: payload, newPIN: pin)
        }.value
        guard let newKey else { throw PINError.pinInUse }
        decoySlotKey = newKey
    }

    func unlockWithBiometrics() async -> Bool {
        guard biometricEnabled else { return false }
        // Second line of defence behind PINVault.destroy() deleting the
        // biometric item: never configure the store from a payload whose vault
        // no longer exists. Its dataKey would be a dead key.
        guard PINVault.isConfigured else {
            BiometricUnlock.disable()
            biometricEnabled = false
            return false
        }
        guard let blob = await BiometricUnlock.read(
                  reason: "panic_pin.biometric.reason".localized),
              let payload = try? JSONDecoder().decode(PINVault.SlotPayload.self, from: blob),
              payload.mode == .real,
              let keyData = payload.dataKey else { return false }
        realPayload = payload
        realSlotKey = nil   // no PIN entered — Settings re-derives if needed
        dataKey = SymmetricKey(data: keyData)
        mode = .real
        PINVault.clearAttemptState()
        lockoutUntil = nil
        MessageDB.shared.configure(decoy: false, dataKey: dataKey)
        MessageStore.shared.reloadFromDB()
        lockState = .unlocked
        return true
    }

    func lock() {
        guard isConfigured, lockState == .unlocked else { return }
        WebSocketService.shared.disconnect()
        dataKey = nil
        realPayload = nil
        realSlotKey = nil
        decoyPayload = nil
        decoySlotKey = nil
        mode = .none
        AuthService.shared.restoreRealIdentity()
        MessageDB.shared.configure(decoy: false, dataKey: nil)
        MessageStore.shared.clearInMemory()
        lockState = .locked
    }

    func finishWipe() {
        BiometricUnlock.disable()
        biometricEnabled = false
        dataKey = nil
        realPayload = nil
        realSlotKey = nil
        decoyPayload = nil
        decoySlotKey = nil
        mode = .none
        lockState = .unlocked
    }

    // MARK: - configuration (real session only)

    func setRealPIN(_ pin: String) async throws {
        guard pin.count >= Self.minPINLength else { throw PINError.pinTooShort }

        if !PINVault.isConfigured {
            let unlock = try await Task.detached(priority: .userInitiated) {
                try PINVault.createWithRealPIN(pin)
            }.value
            realPayload = unlock.payload
            realSlotKey = unlock.slotKey
            guard let keyData = unlock.payload.dataKey else { throw PINError.vaultMissing }
            dataKey = SymmetricKey(data: keyData)
            mode = .real
            lockState = .unlocked
            MessageDB.shared.configure(decoy: false, dataKey: dataKey)
            await MessageDB.shared.reencryptAllRows()
            return
        }

        guard mode == .real, var payload = realPayload,
              let realSlot = payload.layout?.realSlot,
              let salt = PINVault.vaultSalt() else { throw PINError.notRealSession }
        try await ensureNotInUse(pin)
        let newKey = await deriveOffMain(pin: pin, salt: salt)
        payload.mode = .real
        try PINVault.writeSlot(index: realSlot, payload: payload, key: newKey)
        realPayload = payload
        realSlotKey = newKey
    }

    func setDecoyPIN(_ pin: String) async throws {
        guard pin.count >= Self.minPINLength else { throw PINError.pinTooShort }
        guard mode == .real, var payload = realPayload,
              var layout = payload.layout,
              let salt = PINVault.vaultSalt(), let realSlotKey else {
            throw PINError.notRealSession
        }
        guard !biometricEnabled else { throw PINError.biometricConflict }
        let realSlot = layout.realSlot
        try await ensureNotInUse(pin, ignoringSlot: layout.decoySlot)

        let decoyKeyData = layout.decoyDataKey ?? randomKeyData()
        let decoyUIN = layout.decoyUIN ?? Self.randomDecoyUIN()
        let decoyNick = layout.decoyNickname ?? Self.randomDecoyNickname()
        let slotIndex = layout.decoySlot ?? PINVault.freeSlotIndex(layout: layout)
        guard let slotIndex else { throw PINError.noFreeSlot }

        let decoyKey = await deriveOffMain(pin: pin, salt: salt)
        let decoyPayload = PINVault.SlotPayload(
            mode: .decoy, dataKey: decoyKeyData, layout: nil,
            decoyUIN: decoyUIN, decoyNickname: decoyNick
        )
        try PINVault.writeSlot(index: slotIndex, payload: decoyPayload, key: decoyKey)

        layout.decoySlot = slotIndex
        layout.decoyDataKey = decoyKeyData
        layout.decoyUIN = decoyUIN
        layout.decoyNickname = decoyNick
        payload.layout = layout
        try PINVault.writeSlot(index: realSlot, payload: payload, key: realSlotKey)
        realPayload = payload
    }

    func removeDecoyPIN() throws {
        guard mode == .real, var payload = realPayload,
              var layout = payload.layout,
              let realSlotKey else { throw PINError.notRealSession }
        let realSlot = layout.realSlot
        guard let decoySlot = layout.decoySlot else { return }
        try PINVault.writeSlot(index: decoySlot, payload: nil, key: nil)
        layout.decoySlot = nil
        layout.decoyDataKey = nil
        payload.layout = layout
        try PINVault.writeSlot(index: realSlot, payload: payload, key: realSlotKey)
        realPayload = payload
        MessageDB.destroyDecoyStore()
        DecoySeedStore.destroy()
    }

    // MARK: - decoy seeding (real session only)

    /// Conversations the user can pick from to fill the decoy. Real session
    /// only — this reads the real history, which is the whole point of gating
    /// the picker behind the real PIN.
    func decoySeedCandidates() -> [DecoySeeder.Selection] {
        guard mode == .real else { return [] }
        return DecoySeeder.availableThreads()
    }

    /// Rebuild the decoy store from the picked conversations. Replaces any
    /// previous seed. The decoy's OWN dataKey is used — the real one never
    /// leaves this object and the real store is only ever READ.
    @discardableResult
    func seedDecoy(with selections: [DecoySeeder.Selection]) throws -> Int {
        guard mode == .real, let layout = realPayload?.layout else {
            throw PINError.notRealSession
        }
        guard layout.decoySlot != nil, let decoyKeyData = layout.decoyDataKey else {
            throw PINError.vaultMissing
        }
        let decoyUIN = layout.decoyUIN ?? Self.randomDecoyUIN()
        return DecoySeeder.seed(
            selections,
            decoyUIN: decoyUIN,
            decoyKey: SymmetricKey(data: decoyKeyData),
            realOwnUIN: AuthService.shared.ownUIN
        )
    }

    /// The flag lives ONLY in the wipe slot, which a real session cannot open
    /// (it is sealed under the wipe PIN's key, and holding the real PIN does
    /// not give you the wipe PIN). So the setting genuinely cannot be read back
    /// — it is chosen each time the wipe PIN is set, and the UI says so.
    ///
    /// The obvious fix, mirroring it in the real slot's Layout, does not fit:
    /// see the size note on `PINVault.Layout`. Mirroring it anywhere a real
    /// session CAN read without a PIN (prefs, a plain file) is exactly what
    /// this feature must not do.
    ///
    /// `deleteServerAccount` DEFAULTS OFF at every call site.
    func setWipePIN(_ pin: String, deleteServerAccount: Bool = false) async throws {
        guard pin.count >= Self.minPINLength else { throw PINError.pinTooShort }
        guard mode == .real, var payload = realPayload,
              var layout = payload.layout,
              let salt = PINVault.vaultSalt(), let realSlotKey else {
            throw PINError.notRealSession
        }
        guard !biometricEnabled else { throw PINError.biometricConflict }
        let realSlot = layout.realSlot
        try await ensureNotInUse(pin, ignoringSlot: layout.wipeSlot)

        let slotIndex = layout.wipeSlot ?? PINVault.freeSlotIndex(layout: layout)
        guard let slotIndex else { throw PINError.noFreeSlot }

        let wipeKey = await deriveOffMain(pin: pin, salt: salt)
        let wipePayload = PINVault.SlotPayload(
            mode: .wipe, dataKey: nil, layout: nil,
            wipeDeleteServer: deleteServerAccount
        )
        try PINVault.writeSlot(index: slotIndex, payload: wipePayload, key: wipeKey)

        layout.wipeSlot = slotIndex
        payload.layout = layout
        try PINVault.writeSlot(index: realSlot, payload: payload, key: realSlotKey)
        realPayload = payload
    }

    func removeWipePIN() throws {
        guard mode == .real, var payload = realPayload,
              var layout = payload.layout,
              let realSlotKey else { throw PINError.notRealSession }
        let realSlot = layout.realSlot
        guard let wipeSlot = layout.wipeSlot else { return }
        try PINVault.writeSlot(index: wipeSlot, payload: nil, key: nil)
        layout.wipeSlot = nil
        payload.layout = layout
        try PINVault.writeSlot(index: realSlot, payload: payload, key: realSlotKey)
        realPayload = payload
    }

    // MARK: - biometric add-on

    func enableBiometric() throws {
        guard mode == .real, let realPayload else { throw PINError.notRealSession }
        guard !hasDecoyPIN, !hasWipePIN else { throw PINError.biometricConflict }
        let blob = try JSONEncoder().encode(realPayload)
        guard BiometricUnlock.enable(payload: blob) else { throw PINError.biometricFailed }
        biometricEnabled = true
    }

    func disableBiometric() {
        BiometricUnlock.disable()
        biometricEnabled = false
    }

    func removeAllPINs() async throws {
        guard mode == .real else { throw PINError.notRealSession }
        await MessageDB.shared.reencryptAllRows(toPlaintext: true)
        MessageDB.destroyDecoyStore()
        DecoySeedStore.destroy()
        PINVault.destroy()
        BiometricUnlock.disable()
        biometricEnabled = false
        realPayload = nil
        realSlotKey = nil
        decoyPayload = nil
        decoySlotKey = nil
        dataKey = nil
        mode = .none
        lockState = .unlocked
        MessageDB.shared.configure(decoy: false, dataKey: nil)
    }

    // MARK: - helpers

    private func ensureNotInUse(_ pin: String, ignoringSlot: Int? = nil) async throws {
        let unlock = await Task.detached(priority: .userInitiated) {
            PINVault.unlock(pin: pin)
        }.value
        guard let unlock else { return }
        if let layout = realPayload?.layout {
            let openedSlot: Int?
            switch unlock.payload.mode {
            case .real:  openedSlot = layout.realSlot
            case .decoy: openedSlot = layout.decoySlot
            case .wipe:  openedSlot = layout.wipeSlot
            }
            if openedSlot != nil, openedSlot == ignoringSlot { return }
        }
        throw PINError.pinInUse
    }

    private func deriveOffMain(pin: String, salt: Data) async -> SymmetricKey {
        await Task.detached(priority: .userInitiated) {
            PINVault.deriveKey(pin: pin, salt: salt)
        }.value
    }

    private func randomKeyData() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    private static func randomDecoyUIN() -> Int {
        Int.random(in: 100_000_000...999_999_999)
    }

    private static func randomDecoyNickname() -> String {
        "user-\(Int.random(in: 1000...9999))"
    }
}

import CryptoKit
import Foundation
import SwiftUI

@MainActor
final class PanicPINService: ObservableObject {
    static let shared = PanicPINService()

    enum LockState { case unlocked, locked }
    enum SessionMode { case none, real, decoy }

    enum SubmitResult { case unlockedReal, unlockedDecoy, wipe, wrong, lockedOut(until: Date) }

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

    var biometricAvailable: Bool { BiometricUnlock.isAvailable }

    var isConfigured: Bool { PINVault.isConfigured }
    var isDecoy: Bool { mode == .decoy }
    var isLocked: Bool { lockState == .locked }

    var hasDecoyPIN: Bool { realPayload?.layout?.decoySlot != nil }
    var hasWipePIN: Bool { realPayload?.layout?.wipeSlot != nil }

    private(set) var dataKey: SymmetricKey?

    @Published private var realPayload: PINVault.SlotPayload?
    private var realSlotKey: SymmetricKey?

    private init() {
        lockState = PINVault.isConfigured ? .locked : .unlocked
        biometricEnabled = BiometricUnlock.isEnabled
        let until = PINVault.loadAttemptState().lockoutUntil
        lockoutUntil = (until ?? .distantPast) > Date() ? until : nil
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
            ContactService.shared.clearForDecoy()
            GroupService.shared.clearForDecoy()
            lockState = .unlocked
            return .unlockedDecoy

        case .wipe:
            return .wipe
        }
    }

    func verifyRealPIN(_ pin: String) async -> Bool {
        let unlock = await Task.detached(priority: .userInitiated) {
            PINVault.unlock(pin: pin)
        }.value
        return unlock?.payload.mode == .real
    }

    func unlockWithBiometrics() async -> Bool {
        guard biometricEnabled else { return false }
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
    }

    func setWipePIN(_ pin: String) async throws {
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
        let wipePayload = PINVault.SlotPayload(mode: .wipe, dataKey: nil, layout: nil)
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
        PINVault.destroy()
        BiometricUnlock.disable()
        biometricEnabled = false
        realPayload = nil
        realSlotKey = nil
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

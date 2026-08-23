import CryptoKit
import Foundation
import SwiftUI
import UserNotifications

/// One process-wide latch: "a duress session is up, no request may leave this
/// device carrying the real identity".
///
/// It exists because clearing screens is not enough. A decoy session inherits a
/// fully warmed-up app: `APIClient` still holds the REAL account's bearer token
/// from the boot that happened before the lock, `KeychainStore` still answers
/// with the real per-account credentials, and the cross-island paths sign with
/// the real Ed25519 key. Every screen that fetches — the profile header, linked
/// devices, my numbers, my reports, the UIN shop, an avatar upload. Every one
/// of them would answer with the REAL account's data inside the duress view,
/// no matter how carefully the local stores were rebound.
///
/// So the gate sits at the two chokepoints every outbound call goes through
/// (`APIClient.rawRequest` and `IslandHTTP.data`) and refuses. A refusal reads
/// as "no connection", which is what an offline account looks like and what the
/// duress view already claims to be.
///
/// `nonisolated` + a lock because the readers are an actor (`APIClient`) and
/// arbitrary background queues, while the writer is `PanicPINService` on the
/// main actor.
enum DuressGate {
    private static let lock = NSLock()
    private static var _active = false

    /// True while a decoy session is up.
    static var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return _active
    }

    static func set(_ active: Bool) {
        lock.lock(); _active = active; lock.unlock()
    }

    /// Thrown instead of performing a request. Surfaces through the same
    /// `catch` every network path already has, so callers degrade to their
    /// existing offline behaviour rather than needing new handling.
    struct Blocked: Error, LocalizedError {
        var errorDescription: String? { "offline" }
    }

    /// `try DuressGate.check()` at the top of a request path.
    static func check() throws {
        if isActive { throw Blocked() }
    }
}

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
        // A cold launch onto the PIN screen never calls `lock()`, so the flag
        // has to be established here or the extension keeps rendering names and
        // bodies on the lock screen of a locked app.
        AppGroup.setPushQuiet(lockState == .locked)
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
            // Idempotent, and belt-and-braces: a decoy session that was killed
            // rather than locked must never leave the real session reading the
            // decoy namespace.
            Self.leaveDecoySession()
            MessageDB.shared.configure(decoy: false, dataKey: dataKey)
            MessageStore.shared.reloadFromDB()
            lockState = .unlocked
            syncPushPrivacy()
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
            // ⚠ BEFORE a single frame of the duress view is drawn. Everything
            // that outlives the lock and names a real person has to go first —
            // see `enterDecoySession`.
            Self.enterDecoySession()
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
            syncPushPrivacy()
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

    // MARK: - decoy session isolation

    /// The account id every per-account store is re-pointed at for the duration
    /// of a decoy session. Fixed, and deliberately the SAME uuid Android uses
    /// for `DecoyStore.STORE_ID`: nothing outside the vault may record that a
    /// decoy exists, so it cannot be a per-install value that has to be
    /// persisted somewhere to be found again.
    ///
    /// Re-pointing rather than wiping is the whole trick. These stores hold
    /// real state that must survive the duress session intact, so a decoy
    /// session reads and writes an EMPTY namespace and the real slots are
    /// untouched on disk. `leaveDecoySession` puts them back.
    private static let decoyNamespace = UUID(uuidString: "8F3C1A64-2D5B-4E07-9A18-C6B0D7E42F95")!

    /// Everything a decoy session must not be able to show, done before the
    /// duress view is drawn.
    ///
    /// `MessageDB` and `ContactService` are handled by the caller — those are
    /// the two the decoy REPLACES with seeded content. This is the long tail
    /// that nothing replaced: App-Group-persisted, account-bound stores that
    /// the chat list reads STRAIGHT out of (bypassing `ContactService`), plus
    /// the in-memory services whose contents outlive `lock()`.
    ///
    /// Report: the duress view opened on the real "Other islands" section —
    /// name, uin@host and all — because `ContactService.clearForDecoy()` only
    /// clears the published roster, and `ContactListView` renders cross-island
    /// peers from `CrossIslandStore` directly.
    private static func enterDecoySession() {
        // ⚠ FIRST. Everything below clears what is already on screen; this is
        // what stops the app FETCHING the real account's data back over the
        // wire the moment any duress-view screen appears. `APIClient` still
        // holds the real bearer token from the pre-lock boot, so without this a
        // decoy session could read the real profile, the real linked devices,
        // the real numbers and the real reports, and could WRITE too (an avatar
        // upload, a rename, a web-link approval) as the real account.
        DuressGate.set(true)
        // Belt-and-braces behind the gate: with no token in the client, a
        // request built somewhere the gate does not cover still cannot
        // authenticate as the real user. Stashed rather than re-derived,
        // because working out WHICH token to put back (legacy unprefixed slot
        // vs per-account slot) is exactly the kind of guess that hands a decoy
        // session the wrong account's credentials — see `AuthService.bootstrap`.
        Task {
            stashedAPIToken = await APIClient.shared.currentToken()
            await APIClient.shared.setToken(nil)
        }
        // The notification EXTENSION is a separate process that cannot see any
        // of this. Tell it, through the App Group, to stop rendering sender
        // names and message bodies — a push landing while the coercer holds the
        // phone is otherwise a real person's name and a line of their text.
        AppGroup.setPushQuiet(true)
        // ⚠ AND THE ONES ALREADY DELIVERED. Suppressing new pushes does nothing
        // about the banners sitting in Notification Center from BEFORE the
        // phone changed hands — real names, real message previews, one pull of
        // the shade away, and the app never has to be touched at all. The app
        // only cleared the tray on foregrounding a REAL unlocked session
        // (`RCQApp.handleScenePhase`), which is precisely the path a coerced
        // phone does not take.
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()

        // Persisted + account-bound: re-point at the empty decoy namespace.
        // Nothing is deleted; the real account's rows stay on disk.
        CrossIslandStore.shared.bind(accountID: decoyNamespace)
        CrossIslandRequestsStore.shared.bind(accountID: decoyNamespace)
        StrangerQuarantine.shared.bind(accountID: decoyNamespace)
        VisitedIslandsStore.shared.bind(accountID: decoyNamespace)
        // The sections tree names the user's own buckets and every chat filed
        // into them, including the one they gated behind this very PIN. A decoy
        // session gets the empty namespace like every other per-account store.
        SectionsStore.shared.bind(accountID: decoyNamespace)
        // The fold state goes with the tree. Left on the real account's slot it
        // would fold the decoy's own sections by the real user's habits.
        SectionCollapseStore.shared.bind(accountID: decoyNamespace)

        // The App-Group uin → nickname map is what the NOTIFICATION EXTENSION
        // titles a push with. It has no idea a decoy session is up, so leaving
        // the real map in place means a push arriving while the coercer holds
        // the phone is titled with a real person's name. It is a cache:
        // `ContactService.refresh()` rebuilds it on the next real session.
        NicknameCache.wipe()
        GroupNameCache.wipe()
        AvatarThumbCache.wipe()

        // The account's OWN profile picture. It is held here (not in a screen's
        // @State) and mirrored into plain UserDefaults, so it survived the lock
        // and the duress view drew the REAL person's face — on the home header
        // and again at the top of Settings — over a synthetic nickname and a
        // synthetic UIN. In memory only: `leaveDecoySession` reads it back.
        PresenceService.shared.clearForDecoy()

        // In-memory services. `lock()` does not clear these, so a real session
        // that was locked and then opened with the duress PIN handed over its
        // profile visitors, its call history, its nearby people and its
        // random chat.
        VisitStore.shared.clearForDecoy()
        NearbyService.shared.wipe()
        RandomChatService.shared.wipe()
        CallService.shared.wipe()
        AudioRoomService.shared.wipe()
        NotificationService.shared.wipe()
        ReactionInboxStore.shared.wipe()
        MentionInboxStore.shared.wipe()
        // Bluetooth/Wi-Fi mesh. Not just a list on screen — an ACTIVE radio
        // advertising this device's callsign to everyone in range, with the
        // discovered peers' names and the session transcript in memory.
        RadioService.shared.wipeForDecoy()
        // The floating in-app banner lives in its own UIWindow above every
        // sheet and cover, and nothing cleared it on lock: one already up when
        // the phone was taken is a real contact's name plus a line of their
        // message, drawn on top of the duress view.
        MessageBannerService.shared.clearForDecoy()
        // Per-account notification prefs: muted peers and muted groups, both
        // keyed by the real uin/group id. The account-switch path wipes them
        // for the same reason.
        NotificationPrefsService.shared.wipe()
    }

    /// Put the per-account stores back on the real account. Called from
    /// `lock()` and from both real-unlock paths, so a decoy session can never
    /// leave the app pointed at the decoy namespace.
    private static func leaveDecoySession() {
        let id = AccountManager.shared.activeAccountID
        CrossIslandStore.shared.bind(accountID: id)
        CrossIslandRequestsStore.shared.bind(accountID: id)
        StrangerQuarantine.shared.bind(accountID: id)
        VisitedIslandsStore.shared.bind(accountID: id)
        SectionsStore.shared.bind(accountID: id)
        SectionCollapseStore.shared.bind(accountID: id)
        VisitStore.shared.reloadFromDisk()
        PresenceService.shared.reloadOwnAvatarFromDisk()
        DuressGate.set(false)
        // Put back exactly what was there. `resumeAfterUnlock` re-dials the
        // socket from the Keychain but never touches APIClient, so without this
        // every REST call after a duress session would go out unauthenticated
        // until the next full boot.
        if let token = stashedAPIToken {
            stashedAPIToken = nil
            Task { await APIClient.shared.setToken(token) }
        }
    }

    /// The real session's bearer token while a decoy session holds the app.
    /// Static because `enterDecoySession`/`leaveDecoySession` are; nil at every
    /// other moment.
    private static var stashedAPIToken: String?

    /// Mirror "the app is locked or under duress" into the App Group so the
    /// notification extension — a separate process with no view of any of this
    /// — stops rendering sender names and message bodies.
    ///
    /// Called on every state transition rather than only on lock, because a
    /// cold launch onto the PIN screen never calls `lock()`.
    private func syncPushPrivacy() {
        AppGroup.setPushQuiet(lockState == .locked || mode == .decoy)
    }

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
        Self.leaveDecoySession()
        MessageDB.shared.configure(decoy: false, dataKey: dataKey)
        MessageStore.shared.reloadFromDB()
        lockState = .unlocked
        syncPushPrivacy()
        return true
    }

    func lock() {
        guard isConfigured, lockState == .unlocked else { return }
        WebSocketService.shared.disconnect()
        // Leaving a decoy session: the per-account stores go back to the real
        // account. Harmless in a real session (it rebinds to the same id).
        Self.leaveDecoySession()
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
        syncPushPrivacy()
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
        syncPushPrivacy()
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
            syncPushPrivacy()
            MessageDB.shared.configure(decoy: false, dataKey: dataKey)
            await MessageDB.shared.reencryptAllRows()
            RosterSnapshot.resealAll()
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
        // Rethrows `DecoySeeder.SeedError`. A seed that did not land must reach
        // the user: a decoy they believe is populated and is not is worse than
        // one they know is empty.
        return try DecoySeeder.seed(
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
        syncPushPrivacy()
        MessageDB.shared.configure(decoy: false, dataKey: nil)
        RosterSnapshot.resealAll()
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

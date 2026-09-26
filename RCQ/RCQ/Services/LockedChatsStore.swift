import Combine
import Foundation
import UIKit

/// Chats the user locked behind the app PIN, per local account. Opening a
/// locked chat prompts for the PIN that opened this session first
/// (PanicPINService.verifyThrottled — never the wipe PIN, so it never wipes).
/// Only meaningful when a PIN is configured; the lock toggle is only offered
/// then.
///
/// ⚠ Turning a lock OFF goes through the PIN (#1045), turning it ON does not.
/// Callers use `set(_:locked:)` for the off half, after the PIN sheet.
///
/// ⚠ PER ACCOUNT, not per device. The set used to be one device-wide list of
/// "peer:<uin>" / "group:<id>", so the burn of ANY account (which asks for no
/// PIN, and which an island can also order with `account_burned`) had a
/// choice between leaving a dead account's locks behind and taking every
/// other account's off with it; the first cut of #1045 did the second. Each
/// account now owns its slot, and a burn empties only its own.
@MainActor
final class LockedChatsStore: ObservableObject {
    static let shared = LockedChatsStore()

    enum Entry: Hashable, Codable, Identifiable {
        case peer(uin: Int)
        case group(id: Int)

        var id: String { key }

        var key: String {
            switch self {
            case .peer(let uin): return "peer:\(uin)"
            case .group(let id): return "group:\(id)"
            }
        }

        static func decode(_ key: String) -> Entry? {
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let n = Int(parts[1]) else { return nil }
            switch parts[0] {
            case "peer": return .peer(uin: n)
            case "group": return .group(id: n)
            default: return nil
            }
        }
    }

    /// Every account's locks, keyed by account id (`uuidString`).
    @Published private var byAccount: [String: Set<Entry>] = [:]

    /// The active account's locks. Read through the account pointer at every
    /// call rather than bound on switch, so no switch path can leave the
    /// outgoing account's set standing in front of the incoming one's chats.
    var entries: Set<Entry> { byAccount[Self.activeKey] ?? [] }

    private static let storageKey = "rcq.locked_chats.v2"
    /// One device-wide list, before locks were per account.
    private static let legacyKey = "rcq.locked_chats"

    /// ⚠ The decoy session has a slot of its own (the same fixed namespace
    /// SectionsStore and the other per-account stores move to). The active
    /// account id stays the REAL one during duress, so a lock set there was
    /// filed beside the real account's, tying the decoy's invented number to
    /// the real slot, and a real lock on a colliding number could be taken
    /// off with the decoy PIN.
    private static var activeKey: String {
        if PanicPINService.shared.isDecoy { return PanicPINService.decoyNamespace.uuidString }
        return AccountManager.shared.activeAccountID?.uuidString ?? "none"
    }

    private init() {
        load()
        // Brings the extension's copy in line on every launch, including the
        // first launch of a build that introduced it (#1045).
        syncExtensionMirror()
        // A process woken before the first unlock after a reboot reads empty
        // prefs, and would hold "nothing is locked" for the rest of its life.
        // Read again once the phone has been unlocked.
        NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                let store = LockedChatsStore.shared
                store.load()
                store.syncExtensionMirror()
            }
        }
    }

    func contains(peer uin: Int) -> Bool { entries.contains(.peer(uin: uin)) }
    func contains(group id: Int) -> Bool { entries.contains(.group(id: id)) }

    /// Whether `thread`'s lock is in force: the flag is set AND there is a PIN
    /// to ask for. The same two conditions ChatView's gate checks, so what the
    /// gate hides, the long-press preview, search and the banners do not show
    /// (#1045).
    ///
    /// ⚠ A PIN state that cannot be read counts as a PIN. A process started
    /// while the device is locked cannot open the vault file (it is written
    /// with complete protection), and reading that as "no PIN" took every
    /// gate down for the life of the process.
    func holds(_ thread: ThreadID) -> Bool {
        let flagged: Bool
        switch thread {
        case .peer(let uin): flagged = contains(peer: uin)
        case .group(let id): flagged = contains(group: id)
        }
        return flagged && PINVault.configuredState != false
    }

    /// Set, not flip. There used to be a `toggle` here, and a toggle was what
    /// let anyone holding the unlocked phone take a lock off in one tap
    /// (#1045). The "off" half now runs after a PIN sheet, and a flip there
    /// would lock the chat again if anything had already unlocked it while the
    /// sheet was up.
    func set(_ entry: Entry, locked: Bool) {
        let key = Self.activeKey
        var set = byAccount[key] ?? []
        guard set.contains(entry) != locked else { return }
        if locked { set.insert(entry) } else { set.remove(entry) }
        byAccount[key] = set.isEmpty ? nil : set
        save()
    }

    /// Burn hook: the active account's locks and nobody else's. A burn mints
    /// a fresh identity under the same account id, and the chats these locks
    /// named are gone with the burned one.
    func wipeActiveAccount() {
        guard byAccount.removeValue(forKey: Self.activeKey) != nil else { return }
        save()
    }

    /// An account that left the device takes its locks with it.
    func forget(accountID: UUID) {
        guard byAccount.removeValue(forKey: accountID.uuidString) != nil else { return }
        save()
    }

    /// Every account's locks. Only where the PIN itself goes (removing it,
    /// the wipe PIN): a lock with no PIN to ask for is not enforced, and left
    /// in place it would come back without a word the day a new PIN is set.
    func wipe() {
        byAccount.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
        UserDefaults.standard.removeObject(forKey: Self.legacyKey)
        syncExtensionMirror()
    }

    /// Hand the notification extension the locks that are in force (#1045),
    /// every account's, so a push for an account that is not the active one
    /// is judged by that account's locks. Also called from `PanicPINService`
    /// on every PIN state change, because "in force" depends on a PIN existing.
    ///
    /// ⚠ Leaves the file alone when the PIN state cannot be read (see
    /// `holds`): deleting it on a guess is how a locked chat's words reached
    /// the lock screen after a background launch.
    func syncExtensionMirror() {
        switch PINVault.configuredState {
        case true?:
            AppGroup.setLockedChats(byAccount.mapValues { Set($0.map(\.key)) })
        case false?:
            AppGroup.setLockedChats([:])
        case nil:
            return
        }
    }

    // MARK: - persistence

    private func load() {
        var out: [String: Set<Entry>] = [:]
        if let raw = UserDefaults.standard.dictionary(forKey: Self.storageKey) as? [String: [String]] {
            for (account, keys) in raw {
                let set = Set(keys.compactMap(Entry.decode))
                if !set.isEmpty { out[account] = set }
            }
        }
        // The device-wide list goes to EVERY account on the device: it was in
        // force on whichever account was active, so this loses no lock. Left
        // where it is while there is no account to give it to, or while it
        // cannot be told whether a PIN exists.
        //
        // ⚠ With no PIN it is dropped, not carried: an older build did not clear
        // it when the PIN was removed, so it can hold locks nobody has seen in
        // months, and copied over they would all come back, on every account,
        // the day a new PIN is set.
        let accounts = AccountManager.shared.accounts.map(\.id.uuidString)
        if UserDefaults.standard.object(forKey: Self.legacyKey) != nil,
           PINVault.configuredState == false {
            UserDefaults.standard.removeObject(forKey: Self.legacyKey)
        }
        if let legacy = UserDefaults.standard.array(forKey: Self.legacyKey) as? [String],
           !accounts.isEmpty, PINVault.configuredState == true {
            let set = Set(legacy.compactMap(Entry.decode))
            if !set.isEmpty {
                for account in accounts { out[account, default: []].formUnion(set) }
            }
            byAccount = out
            save()
            UserDefaults.standard.removeObject(forKey: Self.legacyKey)
            return
        }
        byAccount = out
    }

    private func save() {
        let raw = byAccount.mapValues { $0.map(\.key) }
        if raw.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.storageKey)
        } else {
            UserDefaults.standard.set(raw, forKey: Self.storageKey)
        }
        syncExtensionMirror()
    }
}

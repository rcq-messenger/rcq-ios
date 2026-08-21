import Foundation

/// Same-island stranger quarantine (Privacy -> "Strangers go to requests").
/// OPT-IN per account and local to this device: the mailbox itself stays open
/// by default (UIN culture - anyone may write first), and whoever wants a
/// contact-only inbox flips the switch. Mirrors web-chat's
/// stranger-requests.ts rule for rule.
///
/// Held rows ride the SAME store as cross-island requests
/// (CrossIslandRequestsStore), with `host: ""` marking a same-island entry:
/// the pending banner, the requests sheet and the held-message plumbing all
/// come for free.
final class StrangerQuarantine {
    static let shared = StrangerQuarantine()

    private static let appGroup = "group.app.rcq.shared"
    private static let settingPrefix = "rcq.strangers.quarantine."
    private static let allowedPrefix = "rcq.strangers.allowed."

    private let defaults: UserDefaults
    private var settingKey: String
    private var allowedKey: String
    private var allowed: Set<Int>

    private init() {
        defaults = UserDefaults(suiteName: Self.appGroup) ?? .standard
        let id = AppGroup.readActiveAccountID()
        settingKey = Self.settingPrefix + (id?.uuidString ?? "none")
        allowedKey = Self.allowedPrefix + (id?.uuidString ?? "none")
        allowed = Set((defaults.array(forKey: allowedKey) as? [Int]) ?? [])
    }

    /// Re-point at the active account on launch + every account switch, and at
    /// the decoy namespace for a duress session. Same contract as
    /// CrossIslandRequestsStore.bind - the two stores must move together, or
    /// an allowance granted on one account would leak into another.
    func bind(accountID: UUID?) {
        settingKey = Self.settingPrefix + (accountID?.uuidString ?? "none")
        allowedKey = Self.allowedPrefix + (accountID?.uuidString ?? "none")
        allowed = Set((defaults.array(forKey: allowedKey) as? [Int]) ?? [])
    }

    /// The Privacy toggle. Default OFF - `bool(forKey:)` reads false for a
    /// key that was never set, which is exactly the default we want.
    var enabled: Bool {
        get { defaults.bool(forKey: settingKey) }
        set { defaults.set(newValue, forKey: settingKey) }
    }

    /// Accepting a stranger's request means their FUTURE messages flow too.
    func allow(_ uin: Int) {
        guard allowed.insert(uin).inserted else { return }
        defaults.set(Array(allowed), forKey: allowedKey)
    }

    func isAllowed(_ uin: Int) -> Bool { allowed.contains(uin) }

    /// Envelope kinds the quarantine holds. Control traffic (reactions,
    /// receipts, edits, visits and the rest) from an unknown sender is never
    /// held - there is no message for it to belong to; it follows the normal
    /// path, where it no-ops against messages that do not exist.
    static func isContentKind(_ env: Envelope) -> Bool {
        switch env {
        case .text, .photo, .video, .voice, .file, .location: return true
        default: return false
        }
    }

    /// Should this decrypted same-island 1:1 envelope go to the requests list
    /// instead of the chat? Synchronous - called inside the receive path.
    ///
    /// Never quarantines: self, an allowed stranger, a contact (the live
    /// merged list, so an accepted request takes effect immediately), or a
    /// peer this account ever WROTE to ("I wrote first - their reply is
    /// invited", checked against the database so it sees past the in-memory
    /// window). With no roster at all (offline boot before the first
    /// successful /contacts fetch) it fails OPEN - never eat messages blind.
    @MainActor
    func shouldQuarantine(myUIN: Int, senderUIN: Int, envelope: Envelope) -> Bool {
        guard enabled else { return false }
        guard senderUIN != myUIN else { return false }
        guard Self.isContentKind(envelope) else { return false }
        guard !isAllowed(senderUIN) else { return false }
        guard ContactService.shared.rosterLoaded else { return false }
        if ContactService.shared.contacts.contains(where: { $0.uin == senderUIN }) { return false }
        if MessageDB.shared.hasOutgoing(thread: .peer(uin: senderUIN)) { return false }
        return true
    }
}

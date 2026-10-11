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
    /// The namespace the keys above are under: an account, or the decoy's.
    private var boundID: UUID?

    private init() {
        defaults = UserDefaults(suiteName: Self.appGroup) ?? .standard
        let id = AppGroup.readActiveAccountID()
        boundID = id
        settingKey = Self.settingPrefix + (id?.uuidString ?? "none")
        allowedKey = Self.allowedPrefix + (id?.uuidString ?? "none")
        allowed = Set((defaults.array(forKey: allowedKey) as? [Int]) ?? [])
    }

    /// Re-point at the active account on launch + every account switch, and at
    /// the decoy namespace for a duress session. Same contract as
    /// CrossIslandRequestsStore.bind - the two stores must move together, or
    /// an allowance granted on one account would leak into another.
    func bind(accountID: UUID?) {
        mirrorTicket &+= 1
        boundID = accountID
        settingKey = Self.settingPrefix + (accountID?.uuidString ?? "none")
        allowedKey = Self.allowedPrefix + (accountID?.uuidString ?? "none")
        allowed = Set((defaults.array(forKey: allowedKey) as? [Int]) ?? [])
    }

    /// Forget who the burned identity had let through (burn only).
    ///
    /// ⚠ The allowances go, the TOGGLE stays. They are not the same thing: the
    /// allowance list names people the old identity trusted and has no meaning
    /// under the new one, while the toggle is a standing privacy choice, and
    /// clearing it would quietly turn the quarantine OFF for someone who had
    /// switched it on and would never be told. Erase the data, keep the guard.
    func wipe() {
        mirrorTicket &+= 1
        defaults.removeObject(forKey: allowedKey)
        allowed = []
        // The extension's copy forgets them too, and whom the old identity
        // knew: until the new one has a roster, it holds nobody.
        if let id = boundID, AppGroup.strangerQuarantine(accountID: id) != nil {
            AppGroup.setStrangerQuarantine(.init(allowed: [], known: nil), accountID: id)
        }
    }

    /// The Privacy toggle. Default OFF - `bool(forKey:)` reads false for a
    /// key that was never set, which is exactly the default we want.
    var enabled: Bool {
        get { defaults.bool(forKey: settingKey) }
        set { defaults.set(newValue, forKey: settingKey) }
    }

    /// Accepting a stranger's request means their FUTURE messages flow too,
    /// onto the lock screen as well (`syncExtensionMirror`). Only an account's
    /// entry is touched there; the decoy namespace never has one.
    func allow(_ uin: Int) {
        guard allowed.insert(uin).inserted else { return }
        defaults.set(Array(allowed), forKey: allowedKey)
        if let id = boundID, var mirror = AppGroup.strangerQuarantine(accountID: id) {
            mirror.allowed = allowed.sorted()
            AppGroup.setStrangerQuarantine(mirror, accountID: id)
        }
    }

    /// Hand the notification extension this rule for the active account
    /// (`AppGroup.strangerQuarantine`), so a message the app files under
    /// Requests is announced as a request there too and never with its words.
    /// Called when the switch moves, after each roster read, and when the app
    /// goes to the background (by then every peer written to this session is
    /// in the store). Whom the account lets through is taken only from a live
    /// roster and a readable history; without them the last copy stands.
    ///
    /// Never from a decoy session, and never for an account that is not the
    /// active one: the roster and the history in memory are the active
    /// account's.
    ///
    /// The peers written to are read off the main thread the first time for a
    /// store (`MessageDB.peersWrittenTo`) and kept after that. Until that
    /// first read is in, the last copy stands with the current allowances,
    /// and the read writes the rest unless a later call, a switch of account
    /// or the switch going off overtook it.
    @MainActor
    func syncExtensionMirror() {
        mirrorTicket &+= 1
        let ticket = mirrorTicket
        guard let id = mirrorAccountID() else { return }
        guard enabled else {
            AppGroup.setStrangerQuarantine(nil, accountID: id)
            return
        }
        let wroteTo = MessageDB.shared.peersWrittenToIfKnown
        writeMirror(accountID: id, wroteTo: wroteTo)
        guard wroteTo == nil, ContactService.shared.rosterLoaded, MessageDB.shared.isReadable else { return }
        Task { @MainActor in
            let read = await MessageDB.shared.peersWrittenTo()
            guard let read, ticket == self.mirrorTicket, self.mirrorAccountID() == id, self.enabled
            else { return }
            self.writeMirror(accountID: id, wroteTo: read)
        }
    }

    /// Moves with every sync and every wipe: a read that finishes after
    /// either writes nothing.
    private var mirrorTicket = 0

    /// The account whose mirror this process may write now, if any.
    @MainActor
    private func mirrorAccountID() -> UUID? {
        guard let id = boundID, id == AccountManager.shared.activeAccountID,
              !PanicPINService.shared.isDecoy, !PanicPINService.shared.isLocked
        else { return nil }
        return id
    }

    @MainActor
    private func writeMirror(accountID id: UUID, wroteTo: Set<Int>?) {
        var known = AppGroup.strangerQuarantine(accountID: id)?.known
        if ContactService.shared.rosterLoaded, let wroteTo {
            known = Set(ContactService.shared.contacts.map(\.uin)).union(wroteTo).sorted()
        }
        AppGroup.setStrangerQuarantine(.init(allowed: allowed.sorted(), known: known), accountID: id)
    }

    func isAllowed(_ uin: Int) -> Bool { allowed.contains(uin) }

    /// Envelope kinds the quarantine holds. Control traffic (reactions,
    /// receipts, edits, visits and the rest) from an unknown sender is never
    /// held - there is no message for it to belong to; it follows the normal
    /// path, where it no-ops against messages that do not exist. ⚠ The
    /// notification extension keeps a copy (`isQuarantinedKind`);
    /// `Tools/StrangerQuarantineCheck` holds the two together.
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

    /// `shouldQuarantine` for a message announced before it can be kept
    /// (`MessageService.announceWithoutKeeping`, mostly with the phone
    /// locked): will `ingest` file it under Requests once it can?
    ///
    /// With the history readable this IS `shouldQuarantine`. With the phone
    /// locked it is not readable (complete file protection), so "wrote to
    /// them" read as no, and a person this account had written to was
    /// announced as a "New message request" whose tap opened an empty
    /// Requests list. Then the rule the notification extension uses is the
    /// one asked (`AppGroup.strangerQuarantine`, written by
    /// `syncExtensionMirror` with every contact and every peer written to),
    /// and without it nobody is held, as the extension does.
    @MainActor
    func holdsUnkept(myUIN: Int, senderUIN: Int, envelope: Envelope) -> Bool {
        if MessageDB.shared.isReadable {
            return shouldQuarantine(myUIN: myUIN, senderUIN: senderUIN, envelope: envelope)
        }
        guard enabled else { return false }
        guard senderUIN != myUIN else { return false }
        guard Self.isContentKind(envelope) else { return false }
        guard !isAllowed(senderUIN) else { return false }
        // The copy is the real account's, and only the active one's.
        guard let id = boundID, id == AccountManager.shared.activeAccountID,
              !PanicPINService.shared.isDecoy
        else { return false }
        // A contact in memory is let through whatever the copy says.
        if ContactService.shared.contacts.contains(where: { $0.uin == senderUIN }) { return false }
        return AppGroup.strangerQuarantine(accountID: id)?.holds(senderUIN) == true
    }
}

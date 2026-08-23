import CryptoKit
import Foundation
import os.log

/// The roster on disk, so a cold start paints the chat list from what was
/// last seen and the network catches up behind it.
///
/// Before this existed nothing of the roster was on disk: `ContactService`,
/// `GroupService` and `AudioRoomService` all started empty, and `booted` (the
/// flag that lets the chat list replace the splash) waited on ten to twelve
/// serial round trips: the reachability probe chain, the identity bootstrap,
/// `/server/info`, the own profile, `/contacts`, `/contacts/pending`,
/// `/contacts/outgoing`. One second on a good network, three to five through a
/// relay, and after fifteen seconds the watchdog surrendered to an EMPTY list.
/// The founder's words: "everything loads from scratch, the main screen
/// freezes, Telegram solved this". This is the web client's
/// `contacts-cache.ts` (paint from the snapshot, refresh behind) for the phone.
///
/// One file per account and per roster (`contacts`, `groups`, `rooms`) under
/// the app's own Application Support, never the App Group: the notification
/// extension has no use for the roster and the rows carry contact keys.
/// When a panic PIN is set, the file is sealed under the same data key that
/// seals message fields in `MessageDB` (AES-GCM), so the roster is no more
/// readable at rest than the history is; without a PIN it is plain JSON,
/// like the history, and re-sealed the moment a PIN is set or removed
/// (`resealAll`). Files are `.complete`, the class the history's SQLite
/// store uses; a background launch before the first unlock finds nothing
/// and boots the old way.
///
/// What a restored roster is NOT: evidence of presence (every contact comes
/// back `.offline` until the socket says otherwise; `lastSeen` is kept), and
/// not `rosterLoaded` (the stranger quarantine keys on a LIVE roster and
/// must fail open on a stale one). Nothing in a decoy session reads or writes
/// these files.
///
/// Account switch: files are per account id and survive a switch the way the
/// Keychain rows and the SQLite history do; `wipe()` on the services clears
/// memory only. A burn and a UIN migration delete the files explicitly.
@MainActor
enum RosterSnapshot {
    private static let log = OSLog(subsystem: "app.rcq.client", category: "RosterSnapshot")
    private static let sealedMagic = Data("RCQS1".utf8)

    enum Kind: String { case contacts, groups, rooms }

    private static func url(_ kind: Kind, accountID: UUID) -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        let dir = base.appendingPathComponent("roster", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(kind.rawValue)-\(accountID.uuidString).json")
    }

    /// The data key a panic PIN unlocked, or nil when no PIN is set. Read at
    /// call time: the boot runs after the unlock, so the key is already there
    /// when the first restore happens.
    private static var dataKey: SymmetricKey? { PanicPINService.shared.dataKey }

    /// `accountID` is the account the data BELONGS to, not whichever one is
    /// active when the write happens: an account switch flips the active id
    /// before the in-flight fetch of the previous account lands, and a write
    /// resolved at that moment would put one account's roster in another
    /// account's file.
    static func save<T: Encodable>(_ value: T, as kind: Kind, accountID: UUID?) {
        if PanicPINService.shared.isDecoy { return }
        // A PIN is configured but not unlocked in this process (the app was
        // locked with a fetch still in the air): nothing may be written in
        // the clear. The drain refuses to touch the history in this state
        // for the same reason.
        if PanicPINService.shared.isConfigured, dataKey == nil { return }
        guard let id = accountID, id == AppGroup.readActiveAccountID(), let url = url(kind, accountID: id) else { return }
        do {
            var data = try JSONEncoder().encode(value)
            if let key = dataKey {
                data = sealedMagic + (try AES.GCM.seal(data, using: key)).combined!
            }
            try data.write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            os_log("save %{public}@: %{public}@", log: log, type: .error, kind.rawValue, "\(error)")
        }
    }

    static func load<T: Decodable>(_ kind: Kind, as type: T.Type) -> T? {
        if PanicPINService.shared.isDecoy { return nil }
        guard let id = AppGroup.readActiveAccountID(), let url = url(kind, accountID: id),
              var data = try? Data(contentsOf: url) else { return nil }
        if data.starts(with: sealedMagic) {
            // Sealed under a PIN that is not unlocked in this process (no key),
            // or under a PIN since changed: not ours to read. The network
            // refresh rewrites it.
            guard let key = dataKey,
                  let box = try? AES.GCM.SealedBox(combined: data.dropFirst(sealedMagic.count)),
                  let plain = try? AES.GCM.open(box, using: key) else { return nil }
            data = plain
        }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Forget one account's roster, for a burn or a UIN migration.
    static func delete(accountID: UUID) {
        for kind in [Kind.contacts, .groups, .rooms] {
            if let url = url(kind, accountID: accountID) { try? FileManager.default.removeItem(at: url) }
        }
    }

    static func deleteActive() {
        if let id = AppGroup.readActiveAccountID() { delete(accountID: id) }
    }

    /// Rewrite every roster file under the current sealing: a PIN was just
    /// set (the files were plaintext) or removed (they would be sealed under
    /// a key that no longer exists).
    static func resealAll() {
        ContactService.shared.saveSnapshot()
        GroupService.shared.saveSnapshot()
        AudioRoomService.shared.saveSnapshot()
    }
}

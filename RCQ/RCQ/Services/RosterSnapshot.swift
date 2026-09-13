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
    // `Data` is Sendable, so a `let` needs no unsafe opt-out to be read from
    // the detached decode (30.08). Kept nonisolated so it still is.
    nonisolated private static let sealedMagic = Data("RCQS1".utf8)

    /// `memberNames` is `GroupMemberNameStore`: the last nickname of every
    /// group member ever seen, which is what names the people who left.
    enum Kind: String, CaseIterable { case contacts, groups, rooms, memberNames = "member-names" }

    nonisolated private static func url(_ kind: Kind, accountID: UUID) -> URL? {
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
        guard let gate = writeGate(accountID: accountID) else { return }
        saveOffMain(value, as: kind, accountID: gate.accountID, dataKey: gate.dataKey)
    }

    /// The main-actor half of `save`: may this account's file be written now,
    /// and under which key. For a writer whose map is big enough that the
    /// encode and the write belong off the main thread (`GroupMemberNameStore`).
    static func writeGate(accountID: UUID?) -> (accountID: UUID, dataKey: SymmetricKey?)? {
        if PanicPINService.shared.isDecoy { return nil }
        // A PIN is configured but not unlocked in this process (the app was
        // locked with a fetch still in the air): nothing may be written in
        // the clear. The drain refuses to touch the history in this state
        // for the same reason.
        if PanicPINService.shared.isConfigured, dataKey == nil { return nil }
        guard let id = accountID, id == AppGroup.readActiveAccountID() else { return nil }
        return (id, dataKey)
    }

    /// The encode, the seal and the write, with the gate already passed.
    nonisolated static func saveOffMain<T: Encodable>(
        _ value: T, as kind: Kind, accountID: UUID, dataKey: SymmetricKey?
    ) {
        guard let url = url(kind, accountID: accountID) else { return }
        do {
            var data = try JSONEncoder().encode(value)
            if let key = dataKey {
                data = sealedMagic + (try AES.GCM.seal(data, using: key)).combined!
            }
            try data.write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            os_log("save %{public}@: %{public}@",
                   log: OSLog(subsystem: "app.rcq.client", category: "RosterSnapshot"),
                   type: .error, kind.rawValue, "\(error)")
        }
    }

    static func load<T: Decodable>(_ kind: Kind, as type: T.Type) -> T? {
        if PanicPINService.shared.isDecoy { return nil }
        return loadOffMain(kind, as: type, dataKey: dataKey, accountID: AppGroup.readActiveAccountID())
    }

    /// The load with every main-actor fact passed IN, so the file read, the
    /// AES open and the JSON decode - the actual milliseconds - can run on a
    /// detached task. The founder's 31.08 stall photo showed
    /// `hydrateFromSnapshot` holding the main thread ~4s on a large roster
    /// (decode plus first-use Swift metadata churn); the boot now gathers
    /// decoy/key/account on the main actor in microseconds and does the rest
    /// off it. Callers are responsible for the decoy check.
    nonisolated static func loadOffMain<T: Decodable>(
        _ kind: Kind, as type: T.Type, dataKey: SymmetricKey?, accountID: UUID?
    ) -> T? {
        guard let id = accountID, let url = url(kind, accountID: id),
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
    static func delete(accountID: UUID, kinds: [Kind] = Kind.allCases) {
        for kind in kinds {
            if let url = url(kind, accountID: accountID) { try? FileManager.default.removeItem(at: url) }
        }
    }

    static func deleteActive(kinds: [Kind] = Kind.allCases) {
        if let id = AppGroup.readActiveAccountID() { delete(accountID: id, kinds: kinds) }
    }

    /// Rewrite every roster file under the current sealing: a PIN was just
    /// set (the files were plaintext) or removed (they would be sealed under
    /// a key that no longer exists).
    static func resealAll() {
        ContactService.shared.saveSnapshot()
        GroupService.shared.saveSnapshot()
        AudioRoomService.shared.saveSnapshot()
        GroupMemberNameStore.shared.saveSnapshot()
    }
}

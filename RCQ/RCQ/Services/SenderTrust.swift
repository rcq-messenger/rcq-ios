import Foundation

/// Who sent an envelope, as far as this device can prove it.
///
/// ⚠⚠ `from` and `from_host` sit OUTSIDE the v=1 signature (it covers
/// `ek || env` and nothing else), and the deposit is anonymous. The one thing
/// an envelope proves is the key that signed it (`spub`). A person is a number
/// AND the key we hold for that number; the island is only where the number
/// lives. Until this decision existed, only a sender who honestly stamped
/// another island was ever checked against a key: anybody who read a
/// recipient's open key card could seal "from" any contact of the recipient's
/// own island, into that contact's thread, under that contact's name, and do
/// the same in a room as any member or its owner.
///
/// Made ONCE per envelope, right after it is opened and before any branch
/// reads `from`: the key hand-offs, the sender-key plumbing, carbons, calls,
/// receipts, edits, deletes, reactions, everything. The app (`MessageService`)
/// and the notification extension run the same rule, so a banner never names
/// somebody the app would not file the message under.
///
/// Pure on purpose: the facts come from the caller, and
/// `Tools/SenderTrustCheck` drives every branch.
enum SenderTrust: Equatable {
    /// Our own number under our own key: a carbon, a reaction echo, a copy of
    /// our own post. All installs of an account share its signing key.
    case ownKey
    /// Our own number over a v=2 session, with no key in the envelope. Only
    /// a pre-0.194 Android carbon looks like this. Transitional: it may file
    /// a row of ours, never pin, edit or delete anything.
    case ownSession
    /// A number we hold a key for, signed by that key. `host` is the island
    /// of the row that proved it (nil = ours), never the unsigned `from_host`.
    case pinned(host: String?)
    /// A number of our island whose pin is older than the key the island now
    /// serves, signed by the new key: a reissue, or an island swapping keys.
    /// Either way the pin moves AND the user is told (`Message.keyChangedSentinel`).
    case repinned
    /// Nobody we hold a key for: stranger rules. Content goes where a
    /// stranger's goes, controls are dropped.
    case unpinned
    /// A number we hold a key for, signed by another key. Content is filed as
    /// a request marked "key changed", controls are dropped.
    case forged

    /// Proven to be who `from` says: the only outcomes that may apply a
    /// control (an edit, a delete, a receipt, a key hand-off).
    var isAuthentic: Bool {
        switch self {
        case .ownKey, .pinned, .repinned: return true
        case .ownSession, .unpinned, .forged: return false
        }
    }
}

/// One number's key as a list we hold names it: a contact row, a room member,
/// an accepted contact on another island.
struct SenderKeyRow: Equatable {
    let uin: Int
    /// The row's island in canonical form; nil for our own island.
    let host: String?
    /// Base64 Ed25519 key; "" when the row carries none.
    let key: String
}

/// What the decision is made from. Every key is base64, compared as bytes.
struct SenderTrustFacts {
    /// `from`, unsigned.
    var from: Int
    /// The key that signed it: v=1 `spub`, or the key a sender-key chain was
    /// bound to. nil for v=2.
    var spub: String?
    /// Our number in this context: our home number, or our guest number in a
    /// room on another island.
    var me: Int
    var myKey: String?
    /// A v=2 envelope opened through a libsignal session whose identity the
    /// decrypt checked against what the island publishes (`CryptoError.identityUnverified`).
    var viaSession: Bool = false
    /// `from_host` in canonical form, nil when absent or one of our own names.
    var claimedHost: String? = nil
    /// The room's roster for a room frame (nil for 1:1). Rows of other numbers
    /// may be in it; the decision picks `from`'s.
    var room: [SenderKeyRow]? = nil
    /// The room's island (nil = ours). Ignored without `room`.
    var roomHost: String? = nil
    /// The key this device pinned for `from` on our island.
    var pin: String? = nil
    /// The key our island serves for `from` now (a roster row, a card).
    var islandKey: String? = nil
    /// Accepted contacts on other islands holding `from`'s number.
    var crossIsland: [SenderKeyRow] = []
}

extension SenderTrust {
    static func decide(_ f: SenderTrustFacts) -> SenderTrust {
        let key = f.spub.flatMap(rawKey)
        let mine = f.myKey.flatMap(rawKey)
        // Our number under our key, wherever it says it is from: the key is us.
        if f.from == f.me, let key, let mine, key == mine { return .ownKey }
        let ownContext: Bool = f.room != nil ? true : f.claimedHost == nil
        if f.from == f.me, ownContext {
            // Our number on our island (or in this room) under any other key
            // is never us, and never anybody else either.
            if key != nil { return .forged }
            return f.viaSession ? .ownSession : .unpinned
        }
        if let room = f.room {
            // A room frame comes from a member of THIS room or from nobody.
            guard let row = room.first(where: { $0.uin == f.from }) else {
                // Not on the roster (left, or never in) is nobody in the room, but
                // never under another key than the one we hold for the number: a
                // chain bound before chains were bound to members would otherwise
                // be promoted to them (admitSender, gmsg). In a room of our island
                // the pin decides that. It can only make this .forged, never
                // .pinned: a non-member stays nobody here (roomMembership, gskey,
                // the non-member drop).
                if f.roomHost == nil {
                    var own = f
                    own.crossIsland = []
                    if ownIsland(own, key: key) == .forged { return .forged }
                }
                return .unpinned
            }
            if let roomHost = f.roomHost {
                // Another island's room: its roster is the only list we hold.
                guard let key, let rowKey = rawKey(row.key) else { return .unpinned }
                return key == rowKey ? .pinned(host: roomHost) : .forged
            }
            // A room of our island: its members are numbers of our island,
            // pinned like any other. The row is the island's word, newest of
            // what we hold when it carries a key.
            var own = f
            if rawKey(row.key) != nil { own.islandKey = row.key }
            own.crossIsland = []
            return ownIsland(own, key: key)
        }
        if let host = f.claimedHost {
            // Another island, as the sender says. Cross-island traffic is v=1.
            guard let key else { return .unpinned }
            let rows = f.crossIsland.filter { $0.uin == f.from }
            if let exact = rows.first(where: { $0.host == host }) {
                return rawKey(exact.key) == key ? .pinned(host: exact.host) : .forged
            }
            // The same person writing from another of their islands: the key
            // is who they are, the address only where the row came from.
            if let same = rows.first(where: { rawKey($0.key) == key }) { return .pinned(host: same.host) }
            return .unpinned
        }
        return ownIsland(f, key: key)
    }

    /// A number of our island (or one that names no island at all).
    private static func ownIsland(_ f: SenderTrustFacts, key: Data?) -> SenderTrust {
        guard let key else { return f.viaSession ? .pinned(host: nil) : .unpinned }
        let pin = f.pin.flatMap(rawKey)
        let island = f.islandKey.flatMap(rawKey)
        if let pin {
            if key == pin { return .pinned(host: nil) }
            if key == island { return .repinned }
        } else if key == island {
            return .pinned(host: nil)
        }
        // A contact on another island who holds the same number and left
        // `from_host` off (a backup island made primary writes from its new
        // home): the key proves which row it is, and the row says where.
        if let row = f.crossIsland.first(where: { $0.uin == f.from && rawKey($0.key) == key }) {
            return .pinned(host: row.host)
        }
        return (pin != nil || island != nil) ? .forged : .unpinned
    }

    /// Raw bytes of a base64 key, nil for "", undecodable or empty.
    static func rawKey(_ b64: String) -> Data? {
        guard let d = Data(base64Encoded: b64), !d.isEmpty else { return nil }
        return d
    }

    /// Two base64 keys, as bytes. A nil, empty or undecodable one matches nothing.
    static func sameKey(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b, let x = rawKey(a), let y = rawKey(b) else { return false }
        return x == y
    }
}

/// Who may change a row that is already in a chat (sender-auth, finding 5).
///
/// ⚠ An edit, a delete or a reaction names its target by id alone, and an id
/// is no secret: everybody in a room has seen every id in it. So a control is
/// judged by WHERE its target lives as much as by who sent it: inside the
/// thread the authenticated sender's envelope belongs to, and nowhere else.
/// A 1:1 envelope never reaches a room's row, one room never reaches
/// another's, and a moderator's power ends at the walls of the room it was
/// granted in. Generic over the thread type so the check drives it with plain
/// values.
enum ControlAuthority {
    /// The row a control names, as the store holds it.
    struct Target<Thread: Equatable> {
        let thread: Thread
        let senderUIN: Int
        let isFromMe: Bool
    }

    /// An edit: only the author, only their own row, only in this thread. Our
    /// own edits arrive as carbons (`ownCarbon`) and edit our outgoing rows.
    static func mayEdit<Thread: Equatable>(
        _ target: Target<Thread>?, in thread: Thread, by sender: Int, ownCarbon: Bool = false
    ) -> Bool {
        guard let target, target.thread == thread else { return false }
        if ownCarbon { return target.isFromMe }
        return !target.isFromMe && target.senderUIN == sender
    }

    /// A delete for everyone: the author of the row, or a moderator of the
    /// room the row is in, and only inside the thread the envelope belongs to.
    /// Our own carbon deletes whatever we deleted in that thread (our posts,
    /// or other people's when we moderate there).
    static func mayDelete<Thread: Equatable>(
        _ target: Target<Thread>?, in thread: Thread, by sender: Int,
        senderModerates: Bool = false, ownCarbon: Bool = false
    ) -> Bool {
        guard let target, target.thread == thread else { return false }
        if ownCarbon { return true }
        if !target.isFromMe && target.senderUIN == sender { return true }
        return senderModerates
    }

    /// Where a reaction applies: the thread its target lives in when that is
    /// the envelope's thread, or anywhere for our own echo (a reaction made on
    /// another of our devices, sealed to ourselves, names no thread). nil =
    /// apply nowhere.
    static func reactionThread<Thread: Equatable>(
        targetThread: Thread?, envelopeThread: Thread, ownEcho: Bool
    ) -> Thread? {
        guard let targetThread else { return nil }
        if ownEcho { return targetThread }
        return targetThread == envelopeThread ? targetThread : nil
    }
}

/// Binding of a sender-key chain (SKDM) to a room and to a member's key
/// (sender-auth, finding 3).
enum SkdmRule {
    enum Verdict: Equatable {
        /// A chain we do not hold yet: take it.
        case store
        /// The same chain from the same member under the same key: nothing new
        /// (a re-send, or a recovery answer at an index we passed).
        case known
        /// A chain held for another member, or for this member under another
        /// key, or a chain of another room: refused.
        case refuse
    }

    /// The chain this device already holds for the kid, as far as the rule
    /// needs it.
    struct Held: Equatable {
        let gid: Int
        let senderUIN: Int
        let spub: String
    }

    /// `frameRoom`: is the SKDM's own `gid` the room the frame came in on?
    /// `senderAuthentic`: the sender is a pinned member of that room.
    ///
    /// ⚠⚠ An existing chain's key is never replaced. It used to be, on any
    /// re-send at an index we had passed: a member who held another member's
    /// chain (every member does) could re-send it under their own key, and
    /// from then on sign posts as that member while the real ones failed.
    static func verdict(
        held: Held?, gid: Int, senderUIN: Int, spub: String,
        frameRoom: Bool, senderAuthentic: Bool
    ) -> Verdict {
        guard frameRoom, senderAuthentic, SenderTrust.rawKey(spub) != nil else { return .refuse }
        guard let held else { return .store }
        guard held.gid == gid, held.senderUIN == senderUIN, SenderTrust.sameKey(held.spub, spub) else { return .refuse }
        return .known
    }
}

/// How far a room key (`gskey`) may move the version this device holds, and
/// from whom (sender-auth, finding 7).
///
/// The store is monotonic, so one envelope naming an enormous version used to
/// wedge a room for good: every later, honest key had a lower number and was
/// refused. A key that opens the room's sealed blob proves itself, whoever
/// hands it over. Anything else is a mint or a rotation: only those who may
/// mint send one, and at most one generation past the newest of what we hold
/// and what the island's sealed blob says it was sealed under. A plain member
/// at +1 with a key that opens nothing used to be taken, and the owner's
/// honest answer, one version lower, was then refused until the next rotation.
enum RoomKeyRule {
    /// opensBlob: the key opens the room's current sealed blob.
    /// mayMint: our own key, the owner, an admin, or a member with the
    /// `info` cap (first seal) or the `members` cap (rotation on a kick).
    static func accepts(_ ver: Int64, held: Int64?, sealed: Int64?, opensBlob: Bool, mayMint: Bool) -> Bool {
        guard ver >= 0 else { return false }
        // The room's own blob is the proof, whoever handed the key over.
        if opensBlob { return sealed.map { ver == $0 } ?? true }
        // Anything else is a mint or a rotation. Only those who mint may send
        // one, and only one generation ahead.
        guard mayMint else { return false }
        return ver <= max(held ?? 0, sealed ?? 0) + 1
    }
}

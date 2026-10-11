import Foundation
import os.log

/// An envelope whose sender cannot be judged YET: the island's word on the
/// key (a card, a room's roster) is being read again, and the row is worth
/// holding until it lands. Surfaced through `ingest`'s `decryptError`, so the
/// queue drain leaves the row for the drain that follows the read, and the
/// room-log drain strikes it like any row that did not open.
struct SenderTrustPending: Error {}

/// A v=2 row whose sender identity the island was asked about and does not
/// publish: no later drain opens it differently, and holding it would pin the
/// queue's cursor in front of everything behind it.
struct SenderTrustRefused: Error {}

/// The app half of `SenderTrust`: the one re-read of the island's word per
/// sender, and what came of it.
///
/// Each read is asked at most once per window, and a row is held only while
/// its read is in flight or was just started. A row that comes back after
/// the read landed is decided for good on what the island said then, so no
/// row is held twice for the same reason, and nothing here can loop.
@MainActor
final class SenderTrustLedger {
    static let shared = SenderTrustLedger()

    /// A card is read again at most this often per number.
    static let cardWindow: TimeInterval = 10 * 60
    /// A card read stands for the island's current key this long.
    static let cardLife: TimeInterval = 60 * 60
    /// A room's roster is read again at most this often.
    static let rosterWindow: TimeInterval = 2 * 60
    /// A device's published identity is read again at most this often.
    static let identityWindow: TimeInterval = 5 * 60

    private static let log = OSLog(subsystem: "app.rcq.client", category: "SenderTrust")

    private var cardKeys: [Int: (key: String, at: Date)] = [:]
    private var cardAsked: [Int: Date] = [:]
    private var cardInFlight: Set<Int> = []
    private var rosterAsked: [Int: Date] = [:]
    private var rosterInFlight: Set<Int> = []
    private var identityAsked: [String: Date] = [:]
    private var identityInFlight: Set<String> = []
    /// Devices whose published identity was read successfully, and when.
    private var identityRead: [String: Date] = [:]
    private var unverifiedNoticeAt: [Int: Date] = [:]
    private var redrainQueued = false

    private init() {}

    /// Everything is per account and per island: a switch or a burn starts over.
    func reset() {
        cardKeys = [:]
        cardAsked = [:]
        cardInFlight = []
        rosterAsked = [:]
        rosterInFlight = []
        identityAsked = [:]
        identityInFlight = []
        identityRead = [:]
        unverifiedNoticeAt = [:]
    }

    /// The key the island's card served for [uin] on a recent read.
    func freshCardKey(_ uin: Int, now: Date = Date()) -> String? {
        guard let entry = cardKeys[uin], now.timeIntervalSince(entry.at) < Self.cardLife else { return nil }
        return entry.key
    }

    /// Ask the island for [uin]'s card, at most once per window. True while
    /// a read is in flight (just started or already running): the caller may
    /// hold its row for it. False once the window's read has landed.
    func askCard(uin: Int) -> Bool {
        if cardInFlight.contains(uin) { return true }
        let now = Date()
        if let at = cardAsked[uin], now.timeIntervalSince(at) < Self.cardWindow { return false }
        cardAsked[uin] = now
        cardInFlight.insert(uin)
        let accountID = AccountManager.shared.activeAccountID
        Task { @MainActor in
            defer {
                self.cardInFlight.remove(uin)
                self.redrain()
            }
            // On a closed island the card is served only to somebody holding
            // the guest card its owner handed out; the one we kept for them
            // is the one to show (the same as `upsertStranger`).
            let guestCard = GuestCardStore.shared.card(for: uin)
            guard let p: UserProfile = try? await APIClient.shared.request(
                "GET", "/users/\(uin)/info",
                headers: guestCard.map { ["X-RCQ-Guest-Card": $0] } ?? [:]
            ), AccountManager.shared.activeAccountID == accountID,
                  SenderTrust.rawKey(p.signingKey) != nil
            else { return }
            self.cardKeys[uin] = (p.signingKey, Date())
            // First sight of this number's key, when nothing is pinned yet.
            SignalProtocolStores.shared.pinSenderIfAbsent(uin: uin, keyB64: p.signingKey)
        }
        return true
    }

    /// Read a room's roster again, at most once per window. Same answer as
    /// `askCard`.
    func askRoster(gid: Int) -> Bool {
        if rosterInFlight.contains(gid) { return true }
        let now = Date()
        if let at = rosterAsked[gid], now.timeIntervalSince(at) < Self.rosterWindow { return false }
        rosterAsked[gid] = now
        rosterInFlight.insert(gid)
        Task { @MainActor in
            // A room the list has not brought yet (a boot still loading it, a
            // room joined on another device) has no row to hang a roster on.
            if GroupService.shared.find(gid) == nil { await GroupService.shared.refresh() }
            _ = await GroupService.shared.ensureRoster(gid, refresh: true)
            self.rosterInFlight.remove(gid)
            self.redrain()
        }
        return true
    }

    /// Read again what the island publishes for [uin]'s device [deviceId], for
    /// a v=2 session the decrypt refused, at most once per window.
    func askIdentity(uin: Int, deviceId: Int) {
        let k = "\(uin):\(deviceId)"
        if identityInFlight.contains(k) { return }
        let now = Date()
        if let at = identityAsked[k], now.timeIntervalSince(at) < Self.identityWindow { return }
        identityAsked[k] = now
        identityInFlight.insert(k)
        let accountID = AccountManager.shared.activeAccountID
        Task { @MainActor in
            let read = await SignalCryptoService.refreshPublishedIdentity(uin: uin, deviceId: deviceId)
            self.identityInFlight.remove(k)
            guard AccountManager.shared.activeAccountID == accountID else { return }
            if read { self.identityRead[k] = Date() }
            self.redrain()
        }
    }

    /// The island was asked within the window, answered, and still does not
    /// publish the identity the row carries: refused for good.
    func identityRefuted(uin: Int, deviceId: Int, now: Date = Date()) -> Bool {
        let k = "\(uin):\(deviceId)"
        guard !identityInFlight.contains(k), let at = identityRead[k] else { return false }
        return now.timeIntervalSince(at) < Self.identityWindow
    }

    /// At most one "could not be verified" line per number a day.
    func mayNoteUnverified(_ uin: Int, now: Date = Date()) -> Bool {
        if let at = unverifiedNoticeAt[uin], now.timeIntervalSince(at) < 24 * 3600 { return false }
        unverifiedNoticeAt[uin] = now
        return true
    }

    /// One drain after a read lands, coalesced: the rows held for it are in
    /// the queue (or the room's log) and come back through `ingest`.
    private func redrain() {
        guard !redrainQueued else { return }
        redrainQueued = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            self.redrainQueued = false
            await MessageService.shared.fetchOfflineQueue()
        }
    }

    /// First sight of our island's numbers in a list the island served (the
    /// roster, a room's members): pinned unless pinned already. Never moves a
    /// pin; the notification extension judges pushes by these.
    static func seedPins<S: Sequence>(_ rows: S) where S.Element == (uin: Int, key: String) {
        let stores = SignalProtocolStores.shared
        for row in rows where SenderTrust.rawKey(row.key) != nil {
            stores.pinSenderIfAbsent(uin: row.uin, keyB64: row.key)
        }
    }
}

extension MessageService {
    /// A host in the one spelling every rule compares, nil for our own.
    static func trustHost(_ host: String?) -> String? {
        guard let host, !host.isEmpty, !Multihome.isOwnHost(host) else { return nil }
        return Multihome.normalizeHost(host) ?? host.lowercased()
    }

    /// The key our island serves for [uin] now, freshest first: a card just
    /// read, the roster row, a room's member row, the stranger of an open
    /// random chat.
    func islandKey(for uin: Int) -> String? {
        if let card = SenderTrustLedger.shared.freshCardKey(uin) { return card }
        if let c = ContactService.shared.contacts.first(where: { $0.uin == uin && $0.host == nil }),
           SenderTrust.rawKey(c.signingKey) != nil {
            return c.signingKey
        }
        for g in GroupService.shared.groups where g.host == nil {
            if let m = g.members.first(where: { $0.uin == uin }), SenderTrust.rawKey(m.signingKey) != nil {
                return m.signingKey
            }
        }
        if let peer = RandomChatService.shared.activePeer, peer.uin == uin,
           SenderTrust.rawKey(peer.signingKey) != nil {
            return peer.signingKey
        }
        return nil
    }

    /// Our signing key, base64.
    var ownSigningKey: String? { (try? crypto?.bootstrapIdentity())?.signingKey }

    /// Opened through a v=2 session: no `spub`, a device id, and not a v=1
    /// seal on the wire. A cache entry an older extension wrote without the
    /// key reads as nothing here.
    static func openedViaSession(_ d: DecryptedEnvelope, payload: String, isGmsg: Bool) -> Bool {
        !isGmsg && d.senderSigningKey == nil && d.senderDeviceID != nil && !isStatelessSeal(payload)
    }

    /// The facts `SenderTrust.decide` reads, for a row as it came in. `room`
    /// is filled only for a room whose roster is in hand; the caller is told
    /// whether it was.
    func senderTrustFacts(
        _ d: DecryptedEnvelope, groupID: Int?, payload: String, isGmsg: Bool
    ) -> (facts: SenderTrustFacts, rosterKnown: Bool) {
        var me = ownUIN
        var roomHost: String?
        var room: [SenderKeyRow]?
        var rosterKnown = false
        if let gid = groupID, let g = GroupService.shared.find(gid) {
            roomHost = Self.trustHost(g.host)
            if g.host != nil, let creds = CrossIslandGroups.foreignCreds(host: g.host!, ownUIN: ownUIN) {
                // Our number in a room on another island is our copy there.
                me = creds.uin
            }
            if !g.members.isEmpty {
                rosterKnown = true
                room = g.members.map { SenderKeyRow(uin: $0.uin, host: roomHost, key: $0.signingKey) }
            }
        }
        var facts = SenderTrustFacts(
            from: d.senderUIN, spub: d.senderSigningKey, me: me, myKey: ownSigningKey
        )
        facts.viaSession = Self.openedViaSession(d, payload: payload, isGmsg: isGmsg)
        facts.room = room
        facts.roomHost = roomHost
        // A room frame is numbered by its room's island, whatever it stamps.
        facts.claimedHost = groupID != nil ? roomHost : Self.trustHost(d.senderHost)
        facts.pin = SignalProtocolStores.shared.senderPin(uin: d.senderUIN)
        facts.islandKey = islandKey(for: d.senderUIN)
        facts.crossIsland = CrossIslandStore.shared.all()
            .filter { $0.uin == d.senderUIN }
            .map { SenderKeyRow(uin: $0.uin, host: Self.trustHost($0.host), key: $0.signingKey) }
        return (facts, rosterKnown)
    }

    /// Whether [gid]'s room counts the sender of `d` as a member under the key
    /// it signed with, for a hand-off that names its room inside the envelope
    /// (`gskey`, which travels 1:1).
    enum RoomMembership { case member, rosterUnknown, notMember }

    func roomMembership(gid: Int, _ d: DecryptedEnvelope) -> RoomMembership {
        guard let g = GroupService.shared.find(gid) else { return .notMember }
        guard !g.members.isEmpty else { return .rosterUnknown }
        let (facts, _) = senderTrustFacts(d, groupID: gid, payload: "", isGmsg: false)
        switch SenderTrust.decide(facts) {
        case .pinned, .repinned: return .member
        case .ownKey: return g.contains(d.senderUIN) ? .member : .notMember
        case .ownSession, .unpinned, .forged: return .notMember
        }
    }

    /// Is `innerGid` (the room an SKDM or a chain names) the room the frame
    /// came in on? Ours by id; another island's by its alias here.
    static func innerRoomMatches(innerGid: Int, frameGid: Int) -> Bool {
        if innerGid == frameGid { return true }
        guard frameGid < 0, let ref = VisitedIslandsStore.shared.refByAlias(frameGid) else { return false }
        return ref.remoteId == innerGid
    }
}

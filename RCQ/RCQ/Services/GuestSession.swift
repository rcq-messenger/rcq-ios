import Foundation

/// The app's OWN session is a guest copy (spec 2026-09-15, 12.1 "Copy signed in
/// as an account"; decision D6).
///
/// It happens the moment somebody signs in by phrase onto a row that a room on
/// this island minted for them: a self-join through `/auth/guest`, or a seat an
/// owner added from another island. The row takes part in rooms and nothing
/// else, so every surface the island would refuse is hidden here rather than
/// offered and then refused, and no push token is handed over at all: a guest
/// mailbox never wakes a phone (spec 6.2), and a token on one would be a device
/// the island could be asked about for an account that is not even from here.
///
/// ⚠ Per account, and read before any network answer lands: the chat list and
/// Settings draw on the first frame, and a flat key would paint account A's
/// verdict over account B for that frame. The island is the source of truth and
/// this is only what it last said (`record`), re-asked on every boot, recover
/// and refresh.
@MainActor
final class GuestSession: ObservableObject {
    static let shared = GuestSession()

    /// The island said this session's row is a guest copy. False for every
    /// native account, and for every island too old to have the field.
    @Published private(set) var isPrimaryGuestCopy: Bool = false

    /// The island this copy lives on, for the `%@` of every sentence.
    var host: String { Multihome.ownHost() }

    private init() {
        // Seeded from the last answer rather than from nothing: the chat list
        // and Settings draw before any request lands, and a copy whose
        // surfaces flash into view for one frame has told the room what the
        // account is.
        isPrimaryGuestCopy = GuestSession.stored
    }

    nonisolated private static let legacyKey = "rcq.guest.primaryCopy"

    /// The active account's slot, the flat one before any account exists.
    ///
    /// ⚠ `nonisolated`: `record` is called from the recover and refresh
    /// handshakes, which run off the main actor, and the stored value has to be
    /// written there and then rather than a hop later.
    nonisolated private static var defaultsKey: String {
        guard let id = AppGroup.readActiveAccountID() else { return legacyKey }
        return "\(legacyKey).\(id.uuidString)"
    }

    nonisolated private static var stored: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    /// What the island answered about OUR row, from `/users/{uin}/info` on the
    /// own card, from `/auth/recover`, `/auth/refresh` or `/auth/guest`.
    ///
    /// ⚠ Nil is not news. An island older than guest copies sends nothing, and
    /// reading that as "native" would clear the flag for an account that is a
    /// copy on an island which simply did not answer this time.
    ///
    /// Callable from anywhere (the recover handshake runs off the main actor);
    /// the stored value is written at once so the next read is right, and the
    /// published one follows on the main actor.
    nonisolated static func record(guest: Bool?) {
        guard let guest else { return }
        let key = defaultsKey
        guard UserDefaults.standard.bool(forKey: key) != guest else { return }
        UserDefaults.standard.set(guest, forKey: key)
        Task { @MainActor in shared.isPrimaryGuestCopy = guest }
    }

    /// An account switch: re-read the incoming account's own answer instead of
    /// leaving the outgoing one's on screen.
    func bind() { isPrimaryGuestCopy = Self.stored }

    /// A settle (spec 9.1) or a burn: this row is not a guest any more.
    func clear() {
        UserDefaults.standard.set(false, forKey: Self.defaultsKey)
        isPrimaryGuestCopy = false
    }

    /// `POST /auth/guest/settle` on our OWN island (spec 9.1). `code` is a
    /// voucher or an invite; an open island settles with none. Throws
    /// `APIError`, which `GuestSettleSheet` turns into a sentence.
    func settle(code: String?) async throws {
        struct Body: Encodable { let code: String? }
        struct Out: Decodable { let uin: Int }
        let trimmed = code?.trimmingCharacters(in: .whitespacesAndNewlines)
        let _: Out = try await APIClient.shared.request(
            "POST", "/auth/guest/settle",
            body: Body(code: (trimmed?.isEmpty == false) ? trimmed : nil)
        )
        clear()
        // The row kept its number and its token (guestness is never in the
        // token), so there is nothing to re-authenticate: what changed is the
        // badge and what this island now lets the account do.
        await AppState.shared.refreshServerInfo()
        await GroupService.shared.refresh()
    }
}

/// The roster answers that decide what a member row may offer (decision D5),
/// and which of our copies is a guest where.
@MainActor
enum GuestRoster {
    /// The guest flags of `uin` in the room `groupID`, as the last roster read
    /// left them. (false, false) when the room or the row is not held: that is
    /// what every island older than the field serves, and it is the direction
    /// that shows a person the actions they had before.
    static func flags(uin: Int, groupID: Int?) -> (guest: Bool, invited: Bool) {
        guard let gid = groupID,
              let m = GroupService.shared.find(gid)?.members.first(where: { $0.uin == uin })
        else { return (false, false) }
        return (m.guest, m.invited)
    }

    /// Is OUR account a guest in this room? On another island that is what the
    /// copy's own island called it; on ours it is the primary session.
    static func weAreGuest(in group: RCQGroup) -> Bool {
        guard let h = group.host, !h.isEmpty, !Multihome.isOwnHost(h) else {
            return GuestSession.shared.isPrimaryGuestCopy
        }
        return VisitedIslandsStore.shared.get(host: h)?.guest == true
    }

    /// The room's island, as a sentence's `%@`.
    static func host(of group: RCQGroup) -> String {
        if let h = group.host, !h.isEmpty { return h }
        return Multihome.ownHost()
    }

    /// Spec 8.1 through the roster this client holds (decision D8): leaving
    /// would leave the room with no member who lives on its island, and the
    /// island deletes a room in that state. The warning is shown before the
    /// leave, never after it.
    ///
    /// ⚠ Answers on the roster this client happens to hold. `leaveWarning` is
    /// what the surfaces call, because a roster that cannot answer is fetched
    /// rather than read as "nothing to warn about" (decision E4).
    static func leavingStrandsTheRoom(_ group: RCQGroup) -> Bool {
        check(group) == .warn
    }

    /// The question every leave surface asks, with the roster actually in hand
    /// (decision E4, 16.09).
    ///
    /// The places a room is left from often hold no roster: the chat list is
    /// fetched `?members=0`, the island sends the compact form for a room over
    /// a hundred people, and a room on another island can arrive without one
    /// too. A missing roster used to read as "nothing to warn about", so the
    /// last member who lives on the island walked out and the island deleted
    /// the room for everyone still in it with nothing said. So the roster is
    /// FETCHED first, once, and then the question is answered.
    ///
    /// ⚠ Only positive evidence clears a leave: one visible member who lives on
    /// that island, or our own row being the copy. Everything else warns after
    /// the one fetch, which is how Android decides it
    /// (`Session.lastResidentWarning`: anything that is not SAFE warns). That
    /// includes a roster that came back as only a PAGE of a bigger one and
    /// showed no resident in it, and a refetch that answered with the stale
    /// cached row, because a page says nothing about the members it does not
    /// show. One question nobody needed is the cheaper mistake.
    static func leaveWarning(for group: RCQGroup) async -> Bool {
        switch check(group) {
        case .safe: return false
        case .warn: return true
        case .needRoster:
            guard let fresh = await roster(for: group) else { return true }
            return check(fresh) != .safe
        }
    }

    /// The E4 question put to the roster this row currently carries.
    private static func check(_ group: RCQGroup) -> LastResidentRule.LeaveCheck {
        LastResidentRule.leaveCheck(
            members: group.members.map {
                RosterMemberFlags(uin: $0.uin, guest: $0.guest, invited: $0.invited)
            },
            // 0 is no number at all: we hold no copy on that island, so no row
            // in this roster can be ours and the rule has to ask for more.
            leaver: ownUIN(in: group) ?? 0,
            memberCount: group.memberCount
        )
    }

    /// The room with its roster: the one held here when it is WHOLE, otherwise
    /// one fetch. Our own island through `GroupService`, a room on another
    /// island through the copy's token there.
    ///
    /// ⚠ `refresh: true` is the whole point of the call (F7, 16.09). We are
    /// only here because the rows in hand could not answer the question, and
    /// `ensureRoster` without it hands back those very same rows for any room
    /// fetched once before: a page of a big room stayed a page, and the leave
    /// was then decided on the page that had already failed to decide it. The
    /// answer is re-checked for wholeness by the caller, so a roster that comes
    /// back as a page again counts as NOT known and asks.
    private static func roster(for group: RCQGroup) async -> RCQGroup? {
        if !group.members.isEmpty, group.memberCount <= group.members.count { return group }
        guard let h = group.host, !h.isEmpty, !Multihome.isOwnHost(h) else {
            return await GroupService.shared.ensureRoster(group.id, refresh: true)
        }
        return await CrossIslandGroups.foreignRoster(host: h, aliasID: group.id)
    }

    /// Our number IN that room: the copy's number on another island, the
    /// account's own number on ours.
    private static func ownUIN(in group: RCQGroup) -> Int? {
        guard let h = group.host, !h.isEmpty, !Multihome.isOwnHost(h) else {
            return AuthService.shared.ownUIN
        }
        return CrossIslandGroups.foreignCreds(host: h, ownUIN: AuthService.shared.ownUIN)?.uin
    }
}

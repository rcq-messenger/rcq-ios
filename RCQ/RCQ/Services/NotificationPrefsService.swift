import Foundation

/// Per-user push prefs. Mirror of backend `push_preferences` JSONB.
/// Backend is source of truth; this is an in-memory copy for snappy UI.
///
/// Sealed-sender messages (1:1 + group) keep always-push — server can't
/// see the sender to gate by contact/stranger. Controls here cover:
///   - contact-request push on/off
///   - per-UIN mute list
///   - per-group mute list
@MainActor
final class NotificationPrefsService: ObservableObject {
    static let shared = NotificationPrefsService()

    struct Prefs: Codable, Equatable {
        var contactRequests: Bool
        var mutedUINs: [Int]
        var mutedGroupIDs: [Int]

        static let defaults = Prefs(
            contactRequests: true,
            mutedUINs: [],
            mutedGroupIDs: []
        )

        enum CodingKeys: String, CodingKey {
            case contactRequests = "contact_requests"
            case mutedUINs = "muted_uins"
            case mutedGroupIDs = "muted_group_ids"
        }

        init(
            contactRequests: Bool,
            mutedUINs: [Int],
            mutedGroupIDs: [Int]
        ) {
            self.contactRequests = contactRequests
            self.mutedUINs = mutedUINs
            self.mutedGroupIDs = mutedGroupIDs
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            contactRequests = try c.decode(Bool.self, forKey: .contactRequests)
            mutedUINs = try c.decode([Int].self, forKey: .mutedUINs)
            // Older servers don't return the field; treat as empty.
            mutedGroupIDs = (try? c.decode([Int].self, forKey: .mutedGroupIDs)) ?? []
        }
    }

    @Published private(set) var prefs: Prefs = .defaults
    @Published private(set) var loaded: Bool = false
    /// The account whose island answered the GET that `prefs` holds. Until
    /// one has, `prefs` is `.defaults`, not the island's values, and nothing
    /// may be written from it: a mute tapped before the first sync used to PUT
    /// `contact_requests: true` and the empty lists, turning the request
    /// switch back on and dropping mutes set on other devices (report 1072).
    /// An account and not a flag: between an account switch and the `wipe()`
    /// that follows it, `prefs` is still the account just left, and a write
    /// made from it would land those lists on the other account's island.
    private var syncedFor: UUID?
    /// Bumped by `wipe()`, so an answer meant for the account we just left
    /// is dropped instead of landing in the next one.
    private var generation = 0
    /// The GET in flight. A second one answered after the first one's PUT
    /// would put the pre-PUT lists back, so callers share it.
    private var pulling: Task<Void, Never>?
    /// Bumped each time a PUT's answer lands. A GET answered after one may
    /// have been read on the island before that write. Its lists would undo
    /// the write, and the write already removed the pending entry that would
    /// have kept them out.
    private var writesLanded = 0

    /// One account and the route to its own island, captured when a read or
    /// a write starts. Everything after answers to it: the request goes out
    /// on that route even if the account changes while it waits, and what
    /// comes back is applied only while that account is still the active one
    /// and nothing was wiped since.
    private struct Bound {
        let account: UUID
        let generation: Int
        let route: APIClient.Route
    }

    /// Nil when `account` is not the active one, when the account changed
    /// while the route was read, or when the API client does not speak for it
    /// yet. That last one is the switch itself: the active pointer (and with
    /// it the island the client points at) moves at once, the bearer only when
    /// the next boot sets it, and in between a request carried the old
    /// account's token, and its lists, to the new account's island.
    private func bind(_ account: UUID?) async -> Bound? {
        guard let account, account == AccountManager.shared.activeAccountID,
              !PanicPINService.shared.isDecoy else { return nil }
        let gen = generation
        let route = await APIClient.shared.currentRoute()
        guard gen == generation, account == AccountManager.shared.activeAccountID,
              let bearer = route.bearer, bearer == Self.storedToken(of: account)
        else { return nil }
        return Bound(account: account, generation: gen, route: route)
    }

    /// The token the boot hands the client for `account` (AuthService's
    /// bootstrap rule): only the first account may fall back to the slot
    /// from before there were several.
    private static func storedToken(of account: UUID) -> String? {
        let am = AccountManager.shared
        let legacyOwner = am.accounts.count <= 1 || account == am.accounts.first?.id
        return legacyOwner
            ? KeychainStore.string(KeychainStore.Keys.token)
            : KeychainStore.string(KeychainStore.Keys.token, forAccount: account)
    }

    /// Still the account this was bound to, with nothing wiped since.
    private func holds(_ bound: Bound) -> Bool {
        bound.generation == generation && bound.account == AccountManager.shared.activeAccountID
    }

    /// Mute changes made here that the island has not confirmed yet ("peer:N",
    /// "group:N", `MuteKeys` spelling), per account and on disk. They are all
    /// the sync ever sends on its own, and only to the island of the account
    /// they were made in.
    ///
    /// It used to re-send whatever SoundService held muted. That list is one
    /// for the whole phone, so every account's sync put the other accounts'
    /// mutes on its own island, where the same numbers are other people and
    /// the same group ids other groups. It also undid an unmute made on
    /// another device, since the list here still said muted. An unmute whose
    /// PUT never landed had nothing at all, so the island's old mute came back
    /// into the extension's lists while the chat showed unmuted.
    private enum Pending: String {
        case mutes = "notif.pending_mutes."
        case unmutes = "notif.pending_unmutes."
    }

    private static func pending(_ kind: Pending, _ account: UUID) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: kind.rawValue + account.uuidString) ?? [])
    }

    private static func storePending(_ keys: Set<String>, _ kind: Pending, _ account: UUID) {
        let key = kind.rawValue + account.uuidString
        if keys.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(Array(keys).sorted(), forKey: key)
        }
    }

    private static func ids(_ keys: Set<String>, _ prefix: String) -> Set<Int> {
        Set(keys.compactMap { $0.hasPrefix(prefix) ? Int($0.dropFirst(prefix.count)) : nil })
    }

    /// A change waits here until the island confirms it, filed under the
    /// account it was made in; the later tap on the same chat wins. Never from
    /// a decoy session: the account on file is the real one, and nothing done
    /// there may reach it.
    private func notePending(_ key: String, muted: Bool, account: UUID) {
        guard !PanicPINService.shared.isDecoy else { return }
        var mutes = Self.pending(.mutes, account)
        var unmutes = Self.pending(.unmutes, account)
        if muted {
            mutes.insert(key)
            unmutes.remove(key)
        } else {
            unmutes.insert(key)
            mutes.remove(key)
        }
        Self.storePending(mutes, .mutes, account)
        Self.storePending(unmutes, .unmutes, account)
    }

    /// Every chat `account` has a change waiting for its island on, and the
    /// unmutes among them: what the hand-out of the old phone-wide lists takes
    /// as evidence that the account holds a chat (`SoundService`).
    static func pendingKeys(account: UUID) -> (all: Set<String>, unmutes: Set<String>) {
        let unmutes = pending(.unmutes, account)
        return (pending(.mutes, account).union(unmutes), unmutes)
    }

    /// Mutes the island of `account` must have, from the hand-out of the old
    /// phone-wide lists: sent on its next sync if it lacks them. Never over
    /// an unmute made here since.
    func notePendingMutes(_ keys: Set<String>, account: UUID) {
        guard !PanicPINService.shared.isDecoy else { return }
        let unmutes = Self.pending(.unmutes, account)
        let add = keys.filter { MuteKeys.isIslandKept($0) && !unmutes.contains($0) }
        guard !add.isEmpty else { return }
        Self.storePending(Self.pending(.mutes, account).union(add), .mutes, account)
    }

    /// Drop the changes the island's lists already agree with.
    private static func settlePending(against server: Prefs, account: UUID) {
        func mutedThere(_ key: String) -> Bool? {
            if let uin = ids([key], "peer:").first { return server.mutedUINs.contains(uin) }
            if let gid = ids([key], "group:").first { return server.mutedGroupIDs.contains(gid) }
            return nil
        }
        let mutes = pending(.mutes, account)
        let openMutes = mutes.filter { mutedThere($0) == false }
        if openMutes != mutes { storePending(openMutes, .mutes, account) }
        let unmutes = pending(.unmutes, account)
        let openUnmutes = unmutes.filter { mutedThere($0) == true }
        if openUnmutes != unmutes { storePending(openUnmutes, .unmutes, account) }
    }

    private init() {}

    /// Pull from server. Soft-fail keeps current state — don't reset
    /// to defaults on a network blip mid-session.
    func refresh() async {
        if let pulling { return await pulling.value }
        let task = Task { await pull() }
        pulling = task
        await task.value
        if pulling == task { pulling = nil }
    }

    private func pull() async {
        guard let bound = await bind(AccountManager.shared.activeAccountID) else { return }
        let landed = writesLanded
        do {
            let out: Prefs = try await APIClient.shared.request(
                "GET", "/users/me/push-preferences", route: bound.route
            )
            guard holds(bound) else { return }
            // A write landed while this was out. This answer may predate it,
            // and the write already settled its pending entry. Ask again
            // instead of putting the old lists back. A write only lands once
            // this account has synced, so `prefs` already holds it.
            if writesLanded != landed { return await pull() }
            self.prefs = out
            self.syncedFor = bound.account
            Self.settlePending(against: out, account: bound.account)
            // Self-heal lost changes. A mute or an unmute whose PUT failed
            // (offline, and until 2026-07 an expired token 401ing every call)
            // left the island behind the UI, and this read then overwrote the
            // extension's lists with the island's stale ones. What this
            // account changed here and the island still lacks is sent again,
            // to this account's island and nowhere else.
            let mutes = Self.pending(.mutes, bound.account)
            let unmutes = Self.pending(.unmutes, bound.account)
            // The chat list and the extension say what the island says, with
            // what this account changed here and the island has yet to hear
            // on top: a mute or an unmute made on another device shows here,
            // and a tap made here is never undone by this answer.
            SoundService.shared.adoptIslandMutes(
                uins: Set(out.mutedUINs).union(Self.ids(mutes, "peer:")).subtracting(Self.ids(unmutes, "peer:")),
                groupIDs: Set(out.mutedGroupIDs).union(Self.ids(mutes, "group:")).subtracting(Self.ids(unmutes, "group:")),
                account: bound.account
            )
            let muteGroups = Self.ids(mutes, "group:").subtracting(out.mutedGroupIDs)
            let muteUINs = Self.ids(mutes, "peer:").subtracting(out.mutedUINs)
            let unmuteGroups = Self.ids(unmutes, "group:").intersection(out.mutedGroupIDs)
            let unmuteUINs = Self.ids(unmutes, "peer:").intersection(out.mutedUINs)
            if !muteGroups.isEmpty || !muteUINs.isEmpty || !unmuteGroups.isEmpty || !unmuteUINs.isEmpty {
                await put(bound) { current in
                    current.mutedGroupIDs = Array(Set(current.mutedGroupIDs).union(muteGroups).subtracting(unmuteGroups)).sorted()
                    current.mutedUINs = Array(Set(current.mutedUINs).union(muteUINs).subtracting(unmuteUINs)).sorted()
                }
            }
        } catch {
            // Nothing adopted: before the first sync `prefs` is the defaults,
            // and taking those would unmute every chat of this account.
        }
        if holds(bound) { self.loaded = true }
    }

    /// Optimistic PUT of the fields the patch changed, for `account` (the
    /// account the change was made in, read when it was made) and only while
    /// it is the active one. UI flips first, server catches up async. Before
    /// this account's first successful GET the patch waits for one and lands
    /// on the island's values. With no answer, or no route that speaks for
    /// this account right now (its token is being swapped), nothing is sent
    /// (`prefs` is not this account's). A mute change is already on this
    /// account's lists in SoundService and the extension, so the chat rings
    /// or stays quiet now; the island hears it on the next sync, through
    /// `Pending`.
    func update(account: UUID?, _ patch: (inout Prefs) -> Void) async {
        guard let account, account == AccountManager.shared.activeAccountID else { return }
        let gen = generation
        if syncedFor != account {
            await refresh()
            guard gen == generation, account == AccountManager.shared.activeAccountID,
                  syncedFor == account else { return }
        }
        guard let bound = await bind(account), bound.generation == gen else { return }
        await put(bound, patch)
    }

    /// The write itself, onto the prefs `bound`'s account read from its own
    /// island and on the route captured for it.
    private func put(_ bound: Bound, _ patch: (inout Prefs) -> Void) async {
        guard holds(bound), syncedFor == bound.account else { return }
        var next = prefs
        patch(&next)
        guard next != prefs else { return }
        let before = prefs
        prefs = next
        do {
            struct Body: Encodable {
                let contact_requests: Bool?
                let muted_uins: [Int]?
                let muted_group_ids: [Int]?
            }
            // The island merges field by field (nil = keep), so a field
            // this change did not touch stays out: sent along unchanged it
            // would undo what another device set since our GET.
            let saved: Prefs = try await APIClient.shared.request(
                "PUT", "/users/me/push-preferences",
                body: Body(
                    contact_requests: next.contactRequests != before.contactRequests ? next.contactRequests : nil,
                    muted_uins: next.mutedUINs != before.mutedUINs ? next.mutedUINs : nil,
                    muted_group_ids: next.mutedGroupIDs != before.mutedGroupIDs ? next.mutedGroupIDs : nil
                ),
                route: bound.route
            )
            writesLanded += 1
            Self.settlePending(against: saved, account: bound.account)
        } catch {
            // Server keeps its old value; the next refresh() reconciles
            // through `Pending`.
        }
    }

    func setContactRequests(_ on: Bool) async {
        await update(account: AccountManager.shared.activeAccountID) { $0.contactRequests = on }
    }

    /// A chat whose mute the island keeps: one of its own numbers
    /// (`muted_uins`, which also gates the non-sealed pushes from that number)
    /// or one of its own groups (`muted_group_ids`, read by the server's
    /// `is_group_muted` to drop APNs alerts for offline group recipients;
    /// messages still queue). Somebody on another island and a room there are
    /// muted on the phone alone (`MuteKeys.isIslandKept`).
    enum IslandChat {
        case peer(Int)
        case group(Int)
    }

    /// A mute or an unmute made in `account` (SoundService reads it at the
    /// tap, the only caller). Filed as pending at once, before anything is
    /// awaited, so a sync answered in between keeps it (`pull`), then sent.
    func setMuted(_ chat: IslandChat, muted: Bool, account: UUID) {
        switch chat {
        case .peer(let uin):
            notePending(MuteKeys.peer(uin), muted: muted, account: account)
            Task {
                await update(account: account) { current in
                    var set = Set(current.mutedUINs)
                    if muted { set.insert(uin) } else { set.remove(uin) }
                    current.mutedUINs = Array(set).sorted()
                }
            }
        case .group(let id):
            notePending(MuteKeys.group(id), muted: muted, account: account)
            Task {
                await update(account: account) { current in
                    var set = Set(current.mutedGroupIDs)
                    if muted { set.insert(id) } else { set.remove(id) }
                    current.mutedGroupIDs = Array(set).sorted()
                }
            }
        }
    }

    /// For a burn: what the burned identity changed and never got to its
    /// island must not be sent to the identity that replaces it.
    func forgetPending(account: UUID?) {
        guard let account else { return }
        Self.storePending([], .mutes, account)
        Self.storePending([], .unmutes, account)
    }

    /// Memory only. The lists the extension reads are per account and stay
    /// (SoundService owns them): emptied on every switch, they left every
    /// other account's pushes judged by nobody's mutes.
    func wipe() {
        prefs = .defaults
        loaded = false
        syncedFor = nil
        generation += 1
        pulling = nil
    }
}

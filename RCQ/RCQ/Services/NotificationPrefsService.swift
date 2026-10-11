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
    /// True once a GET for this account has come back. Until then `prefs`
    /// is `.defaults`, not the island's values, and nothing may be written
    /// from it: a mute tapped before the first sync used to PUT
    /// `contact_requests: true` and the empty lists, turning the request
    /// switch back on and dropping mutes set on other devices (report 1072).
    private var synced = false
    /// Bumped by `wipe()`, so an answer meant for the account we just left
    /// is dropped instead of landing in the next one.
    private var generation = 0
    /// The GET in flight. A second one answered after the first one's PUT
    /// would put the pre-PUT lists back, so callers share it.
    private var pulling: Task<Void, Never>?

    /// Unmutes made here that the island has not confirmed yet ("peer:N",
    /// "group:N"), per account and on disk. A mute whose PUT never landed has
    /// SoundService to re-assert it on the next sync; an unmute had nothing,
    /// so that sync put the island's old mute back into the extension's lists
    /// while the chat showed unmuted, and its pushes stayed silent for good.
    private static let pendingPrefix = "notif.pending_unmutes."

    private static func pendingKey(_ account: UUID?) -> String {
        pendingPrefix + (account?.uuidString ?? "none")
    }

    private static func pendingUnmutes(_ account: UUID?) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: pendingKey(account)) ?? [])
    }

    private static func storePendingUnmutes(_ keys: Set<String>, _ account: UUID?) {
        if keys.isEmpty {
            UserDefaults.standard.removeObject(forKey: pendingKey(account))
        } else {
            UserDefaults.standard.set(Array(keys).sorted(), forKey: pendingKey(account))
        }
    }

    private static func ids(_ keys: Set<String>, _ prefix: String) -> Set<Int> {
        Set(keys.compactMap { $0.hasPrefix(prefix) ? Int($0.dropFirst(prefix.count)) : nil })
    }

    /// An unmute waits here until the island confirms it; a mute of the same
    /// chat cancels it (the later tap wins). Never from a decoy session: the
    /// account on file is the real one, and nothing done there may reach it.
    private func notePending(_ key: String, unmuted: Bool) {
        guard !PanicPINService.shared.isDecoy else { return }
        let account = AccountManager.shared.activeAccountID
        var keys = Self.pendingUnmutes(account)
        if unmuted { keys.insert(key) } else { keys.remove(key) }
        Self.storePendingUnmutes(keys, account)
    }

    /// Drop the unmutes the island's lists already agree with.
    private static func settlePending(against server: Prefs, account: UUID?) {
        let keys = pendingUnmutes(account)
        guard !keys.isEmpty else { return }
        let left = keys.filter { key in
            if let uin = ids([key], "peer:").first { return server.mutedUINs.contains(uin) }
            if let gid = ids([key], "group:").first { return server.mutedGroupIDs.contains(gid) }
            return false
        }
        if left != keys { storePendingUnmutes(left, account) }
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
        let gen = generation
        let account = AccountManager.shared.activeAccountID
        do {
            let out: Prefs = try await APIClient.shared.request("GET", "/users/me/push-preferences")
            guard gen == generation else { return }
            self.prefs = out
            self.synced = true
            mirrorMuteToAppGroup()
            Self.settlePending(against: out, account: account)
            // Self-heal lost mutes. Mute toggles PUT optimistically; a failed
            // PUT (offline, and until 2026-07 an expired token 401ing every
            // call) left the server behind the UI — and this refresh then
            // OVERWROTE the local mirror with the server's stale empty list,
            // so muted groups pushed again after every relaunch. The UI's
            // mute state persists in SoundService: re-assert anything it
            // holds muted that the server list is missing. Unmutes come from
            // `pendingUnmutes`: the ones made here that never reached it.
            let missingGroups = Set(SoundService.shared.mutedGroupIDsSnapshot()).subtracting(out.mutedGroupIDs)
            let missingUINs = Set(SoundService.shared.mutedUINsSnapshot()).subtracting(out.mutedUINs)
            let pending = PanicPINService.shared.isDecoy ? Set<String>() : Self.pendingUnmutes(account)
            let unmutedGroups = Self.ids(pending, "group:").intersection(out.mutedGroupIDs)
            let unmutedUINs = Self.ids(pending, "peer:").intersection(out.mutedUINs)
            if !missingGroups.isEmpty || !missingUINs.isEmpty || !unmutedGroups.isEmpty || !unmutedUINs.isEmpty {
                await update { current in
                    current.mutedGroupIDs = Array(Set(current.mutedGroupIDs).union(missingGroups).subtracting(unmutedGroups)).sorted()
                    current.mutedUINs = Array(Set(current.mutedUINs).union(missingUINs).subtracting(unmutedUINs)).sorted()
                }
            }
        } catch {
            // Nothing mirrored: before the first sync `prefs` is the
            // defaults, and writing those would empty the extension's mute
            // lists kept from the last launch.
        }
        self.loaded = true
    }

    private func mirrorMuteToAppGroup() {
        MutedStore.shared.setMuted(uins: prefs.mutedUINs, groupIDs: prefs.mutedGroupIDs)
    }

    /// Optimistic PUT of the fields the patch changed. UI flips first,
    /// server catches up async. Before the first successful GET the patch
    /// waits for one and lands on the island's values. With no answer
    /// nothing is sent (`prefs` is still the defaults), but a mute change
    /// goes onto the lists the extension kept from the last sync, so the
    /// chat rings or stays quiet now; the island hears it on the next sync
    /// (a mute through SoundService, an unmute through `pendingUnmutes`).
    func update(_ patch: (inout Prefs) -> Void) async {
        let gen = generation
        let account = AccountManager.shared.activeAccountID
        if !synced {
            await refresh()
            guard gen == generation else { return }
            guard synced else {
                guard !PanicPINService.shared.isDecoy else { return }
                let kept = MutedStore.shared.lists()
                var local = Prefs(contactRequests: prefs.contactRequests, mutedUINs: kept.uins, mutedGroupIDs: kept.groupIDs)
                patch(&local)
                MutedStore.shared.setMuted(uins: local.mutedUINs, groupIDs: local.mutedGroupIDs)
                return
            }
        }
        var next = prefs
        patch(&next)
        guard next != prefs else { return }
        let before = prefs
        prefs = next
        mirrorMuteToAppGroup()
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
                )
            )
            Self.settlePending(against: saved, account: account)
        } catch {
            // Server keeps its old value — next refresh() reconciles (a mute
            // through SoundService, an unmute through `pendingUnmutes`).
        }
    }

    func setContactRequests(_ on: Bool) async {
        await update { $0.contactRequests = on }
    }

    /// Per-contact mute also flips server-side push gating.
    func setMuted(_ uin: Int, muted: Bool) async {
        notePending("peer:\(uin)", unmuted: !muted)
        await update { current in
            var set = Set(current.mutedUINs)
            if muted { set.insert(uin) } else { set.remove(uin) }
            current.mutedUINs = Array(set).sorted()
        }
    }

    /// Per-group mute. Server's `is_group_muted` reads this list and
    /// suppresses APNs alerts for offline group recipients; messages
    /// still queue, so the user sees them on next /queue fetch.
    func setGroupMuted(_ groupID: Int, muted: Bool) async {
        notePending("group:\(groupID)", unmuted: !muted)
        await update { current in
            var set = Set(current.mutedGroupIDs)
            if muted { set.insert(groupID) } else { set.remove(groupID) }
            current.mutedGroupIDs = Array(set).sorted()
        }
    }

    func wipe() {
        prefs = .defaults
        loaded = false
        synced = false
        generation += 1
        pulling = nil
        MutedStore.shared.wipe()
    }
}

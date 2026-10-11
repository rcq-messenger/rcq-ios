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
        do {
            let out: Prefs = try await APIClient.shared.request("GET", "/users/me/push-preferences")
            guard gen == generation else { return }
            self.prefs = out
            self.synced = true
            mirrorMuteToAppGroup()
            // Self-heal lost mutes. Mute toggles PUT optimistically; a failed
            // PUT (offline, and until 2026-07 an expired token 401ing every
            // call) left the server behind the UI — and this refresh then
            // OVERWROTE the local mirror with the server's stale empty list,
            // so muted groups pushed again after every relaunch. The UI's
            // mute state persists in SoundService: re-assert anything it
            // holds muted that the server list is missing. Union-only —
            // unmutes still travel exclusively through their own PUT.
            let missingGroups = Set(SoundService.shared.mutedGroupIDsSnapshot()).subtracting(out.mutedGroupIDs)
            let missingUINs = Set(SoundService.shared.mutedUINsSnapshot()).subtracting(out.mutedUINs)
            if !missingGroups.isEmpty || !missingUINs.isEmpty {
                await update { current in
                    current.mutedGroupIDs = Array(Set(current.mutedGroupIDs).union(missingGroups)).sorted()
                    current.mutedUINs = Array(Set(current.mutedUINs).union(missingUINs)).sorted()
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
    /// waits for one and lands on the island's values; with no answer it is
    /// dropped (SoundService still holds a mute, and the next sync
    /// re-asserts it).
    func update(_ patch: (inout Prefs) -> Void) async {
        let gen = generation
        if !synced {
            await refresh()
            guard synced, gen == generation else { return }
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
            let _: Prefs = try await APIClient.shared.request(
                "PUT", "/users/me/push-preferences",
                body: Body(
                    contact_requests: next.contactRequests != before.contactRequests ? next.contactRequests : nil,
                    muted_uins: next.mutedUINs != before.mutedUINs ? next.mutedUINs : nil,
                    muted_group_ids: next.mutedGroupIDs != before.mutedGroupIDs ? next.mutedGroupIDs : nil
                )
            )
        } catch {
            // Server keeps its old value — next refresh() reconciles.
        }
    }

    func setContactRequests(_ on: Bool) async {
        await update { $0.contactRequests = on }
    }

    /// Per-contact mute also flips server-side push gating.
    func setMuted(_ uin: Int, muted: Bool) async {
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

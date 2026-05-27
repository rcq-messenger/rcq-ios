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

    private init() {}

    /// Pull from server. Soft-fail keeps current state — don't reset
    /// to defaults on a network blip mid-session.
    func refresh() async {
        do {
            let out: Prefs = try await APIClient.shared.request("GET", "/users/me/push-preferences")
            self.prefs = out
        } catch {
        }
        self.loaded = true
    }

    /// Optimistic full-map PUT. UI flips first, server catches up async.
    func update(_ patch: (inout Prefs) -> Void) async {
        var next = prefs
        patch(&next)
        guard next != prefs else { return }
        prefs = next
        do {
            struct Body: Encodable {
                let contact_requests: Bool?
                let muted_uins: [Int]?
                let muted_group_ids: [Int]?
            }
            let _: Prefs = try await APIClient.shared.request(
                "PUT", "/users/me/push-preferences",
                body: Body(
                    contact_requests: next.contactRequests,
                    muted_uins: next.mutedUINs,
                    muted_group_ids: next.mutedGroupIDs
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
    }
}

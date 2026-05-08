import Foundation

/// Per-user push prefs. Mirror of backend `push_preferences` JSONB.
/// Backend is source of truth; this is an in-memory copy for snappy UI.
///
/// Sealed-sender messages (1:1 + group) keep always-push — server can't
/// see the sender to gate by contact/stranger. Controls here cover:
///   - contact-request push on/off
///   - trade-offer push, split by contact / stranger
///   - per-UIN mute list (silences contact_request + trade pushes)
@MainActor
final class NotificationPrefsService: ObservableObject {
    static let shared = NotificationPrefsService()

    struct Prefs: Codable, Equatable {
        var contactRequests: Bool
        var tradesFromContacts: Bool
        var tradesFromStrangers: Bool
        var mutedUINs: [Int]

        static let defaults = Prefs(
            contactRequests: true,
            tradesFromContacts: true,
            tradesFromStrangers: false,
            mutedUINs: []
        )

        enum CodingKeys: String, CodingKey {
            case contactRequests = "contact_requests"
            case tradesFromContacts = "trades_from_contacts"
            case tradesFromStrangers = "trades_from_strangers"
            case mutedUINs = "muted_uins"
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
                let trades_from_contacts: Bool?
                let trades_from_strangers: Bool?
                let muted_uins: [Int]?
            }
            let _: Prefs = try await APIClient.shared.request(
                "PUT", "/users/me/push-preferences",
                body: Body(
                    contact_requests: next.contactRequests,
                    trades_from_contacts: next.tradesFromContacts,
                    trades_from_strangers: next.tradesFromStrangers,
                    muted_uins: next.mutedUINs
                )
            )
        } catch {
            // Server keeps its old value — next refresh() reconciles.
        }
    }

    func setContactRequests(_ on: Bool) async {
        await update { $0.contactRequests = on }
    }

    func setTradesFromContacts(_ on: Bool) async {
        await update { $0.tradesFromContacts = on }
    }

    func setTradesFromStrangers(_ on: Bool) async {
        await update { $0.tradesFromStrangers = on }
    }

    /// Per-contact mute also flips server-side push gating.
    func setMuted(_ uin: Int, muted: Bool) async {
        await update { current in
            var set = Set(current.mutedUINs)
            if muted { set.insert(uin) } else { set.remove(uin) }
            current.mutedUINs = Array(set).sorted()
        }
    }

    func wipe() {
        prefs = .defaults
        loaded = false
    }
}

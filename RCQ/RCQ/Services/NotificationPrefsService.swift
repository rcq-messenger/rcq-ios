import Foundation

/// Per-user push-notification preferences. Mirror of the backend's
/// `push_preferences` JSONB column on the User table — same shape,
/// same defaults. Backend is the source of truth (it's what
/// actually gates the APNs send), but the iOS Settings UI binds
/// against this in-memory copy for snappy toggle UX.
///
/// Sealed-sender messages (1:1 + group) keep their existing
/// always-push behaviour. The server never knows the sender of a
/// sealed payload, so a "from contacts only" toggle for messages
/// can't be enforced server-side without unwrapping the seal.
/// What we DO control here:
///   - contact-request push on/off
///   - trade-offer push, split by contact / stranger
///   - per-UIN mute list (silences contact_request + trade
///     pushes from those senders)
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

    /// Pull preferences from the server. Called from `AppState.boot`
    /// once auth is in place. Soft-fail to defaults on network
    /// error — UI falls back to "permissive" so the user isn't
    /// silently muted because /users/me/push-preferences 500'd.
    func refresh() async {
        do {
            let out: Prefs = try await APIClient.shared.request("GET", "/users/me/push-preferences")
            self.prefs = out
        } catch {
            // Keep current state — don't reset to defaults on a
            // network blip mid-session.
        }
        self.loaded = true
    }

    /// Replace `prefs` and ship the change. Single endpoint accepts
    /// partial updates, but it's simpler to ship the full map every
    /// toggle and let the server do its own field-by-field merge.
    /// Optimistic — UI flips immediately, server-side state catches
    /// up async.
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
            // Couldn't sync — server keeps its old value, ours has
            // already drifted. On next `refresh()` (boot or pull-
            // to-refresh) the server's authoritative state wins.
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

    /// Add or remove a UIN from the muted list. Used by the
    /// per-contact mute toggle in the contact list — the same
    /// action that toggles iOS-side sound mute also flips this so
    /// the server stops firing pushes from that sender.
    func setMuted(_ uin: Int, muted: Bool) async {
        await update { current in
            var set = Set(current.mutedUINs)
            if muted { set.insert(uin) } else { set.remove(uin) }
            current.mutedUINs = Array(set).sorted()
        }
    }

    /// Burn-flow reset. Called from `AppState.burnAccount`.
    func wipe() {
        prefs = .defaults
        loaded = false
    }
}

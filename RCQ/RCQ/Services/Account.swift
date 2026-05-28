import Foundation

/// One local identity tied to one RCQ server. The same device can hold
/// multiple of these — different servers, different UINs, fully
/// independent contact lists and chat history. All per-account
/// storage (Keychain, MessageDB, ContactService) is keyed off
/// `Account.id`.
///
/// Lifecycle: created when the user onboards onto a server, removed
/// when they explicitly burn that account. The "active" account is
/// the one every singleton currently talks to — switching active
/// account is a hot swap of which backing storage the running app
/// sees, no app restart needed.
///
/// Persisted by `AccountManager` as JSON in UserDefaults. Sensitive
/// fields (UIN, JWT, identity keys) DON'T live here — those stay in
/// the Keychain under per-account prefixes. `Account` itself is just
/// the metadata needed to route storage reads.
struct Account: Codable, Identifiable, Hashable {
    /// Stable local UUID. Used as a prefix for all per-account
    /// Keychain entries and SQLite filenames. Survives the lifetime
    /// of this account on this device. Generated locally, never
    /// shared with the server (the server-side identity is the UIN,
    /// which lives in Keychain under this account's prefix).
    let id: UUID

    /// Backend URL the iOS client talks to for this account.
    /// Equivalent to the old single-tenant `rcq.baseURL`
    /// UserDefaults key, lifted to a per-account property so each
    /// account can target a different backend independently.
    var serverURL: String

    /// Wall-clock time the account was added on this device. Used
    /// for stable ordering in the account switcher (oldest first
    /// matches the natural "primary identity first" intuition).
    let createdAt: Date

    /// Optional human display label for the switcher. If nil, the UI
    /// falls back to the hostname of `serverURL`. The actual
    /// per-account nickname on the server is stored in Keychain
    /// under the per-account prefix — this label is purely a local
    /// affordance for distinguishing accounts at a glance.
    var displayLabel: String?

    /// Pre-shared masquerade token, opt-in per server. When set, the
    /// iOS client sends `X-RCQ-Auth: <token>` on every request to this
    /// backend. The operator's Caddy frontend reads the header and
    /// either proxies to FastAPI (header matches) or serves a decoy
    /// static site (header missing/wrong). Defeats passive scanners
    /// (Shodan, Censys) that probe `/auth/register` or `/health` and
    /// otherwise see a stock RCQ backend.
    ///
    /// Stays nil on api.rcq.app and any other public-by-design
    /// backend. Operator distributes the token out of band (Signal /
    /// Telegram / face-to-face) — there's no value to a token a
    /// scanner can guess.
    var serverToken: String?

    /// Convenience for use in pickers / lists when `displayLabel`
    /// isn't set. Always non-empty.
    var displayHost: String {
        URL(string: serverURL)?.host ?? serverURL
    }

    init(
        id: UUID = UUID(),
        serverURL: String,
        createdAt: Date = Date(),
        displayLabel: String? = nil,
        serverToken: String? = nil
    ) {
        self.id = id
        self.serverURL = serverURL
        self.createdAt = createdAt
        self.displayLabel = displayLabel
        self.serverToken = serverToken
    }
}

import Foundation

/// Per-user economy snapshot. Single source of truth on the server —
/// the iOS client overwrites its local copy from every `WalletOut`
/// payload, no local arithmetic except for one defensive trick:
/// when refreshing, `max(local, server)` so an in-flight grant
/// (e.g. `/tokens/buy-pack` response that just landed) isn't clobbered
/// by a concurrent `GET /me/inventory` that hadn't seen the grant yet.
/// Mirrors the "max-policy" pattern from IX `refreshCurrentMember`.
struct Wallet: Codable, Equatable, Hashable {
    var tokens: Int
    var scrolls: Int
}

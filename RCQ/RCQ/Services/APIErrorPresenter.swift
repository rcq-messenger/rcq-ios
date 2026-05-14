import Foundation

/// Maps raw `APIError` / generic `Error` values to user-friendly,
/// localised strings. The default fallback is "connection hiccup"
/// rather than the raw server tag — we'd rather lose context detail
/// than show "round not running" to a player who has no idea what
/// that means.
///
/// Per-game services (Crash, HiLo, Limbo) layer specialised mappers
/// on top of this for their own response codes. This is the catch-
/// all for paths that don't need that granularity.
enum APIErrorPresenter {
    static func friendly(_ error: Error) -> String {
        if let apiErr = error as? APIError, case .http(let status, let body) = apiErr {
            let raw = body ?? ""
            // 402 is the wallet-debit gate (insufficient balance) used
            // everywhere a paid action would have spent jetons.
            if status == 402 {
                return "common.error.insufficient".localized
            }
            if status == 409 {
                if raw.contains("already") {
                    return "common.error.already_done".localized
                }
                if raw.contains("closed") || raw.contains("not active")
                    || raw.contains("not running") || raw.contains("not started") {
                    return "common.error.session_ended".localized
                }
                return "common.error.conflict".localized
            }
            if status == 404 {
                return "common.error.gone".localized
            }
            if status == 429 {
                return "common.error.rate_limited".localized
            }
            if status >= 500 {
                return "common.error.server".localized
            }
        }
        // Cancellation is not a user-facing error — caller should
        // filter, but if it slips through, show nothing rather than a
        // confusing "operation cancelled" toast.
        if (error as NSError).code == NSURLErrorCancelled { return "" }
        return "common.error.network".localized
    }
}

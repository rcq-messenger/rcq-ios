import Foundation

/// What the call machinery knows that the diagnostics screen needs.
///
/// Kept apart from `WebRTCManager` on purpose: that class is `@MainActor`, and
/// the network audit runs off it. Android parity: `call/CallDiagnostics.kt`.
enum CallDiagnostics {

    /// Host out of the TURN URL the island last handed out, or nil before the
    /// first credential fetch. The audit tests THIS host: it is the one machine
    /// every call depends on, and it was the one machine nothing tested — which
    /// is how a phone that could not place a single call reported that
    /// everything was fine (report #468).
    nonisolated(unsafe) static var turnHost: String?
}

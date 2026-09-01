import Foundation

/// What the island last refused a send with, kept where the composer can read
/// it, and said once.
///
/// ⚠⚠ Why a store and not a thrown error the call site catches: every send
/// path detaches (`Task { try? await ... }`) so a fan-out of N recipients does
/// not hang the composer, and the failure is painted onto the bubble from
/// inside that task. Nothing is left for a `catch` at the call site to read —
/// `ChatViewModel.send()` ends in a bare `catch { }` for exactly that reason.
/// So a room rule ("you are still in the newcomer waiting period", "slow mode
/// is on") reached the person as a red bubble and nothing else. Android had
/// the same shape, and closing it there is what #836 asked for.
///
/// Only refusals a person can DO something about get a sentence. A flaky
/// network keeps the red bubble it already has: "check your connection" in
/// answer to a room rule is worse than silence, and a toast per retry is worse
/// than both.
@MainActor
final class SendRefusalStore: ObservableObject {
    static let shared = SendRefusalStore()

    /// A localised sentence, or nil. Written by `note`, cleared by `take`.
    @Published private(set) var latest: String?

    private init() {}

    /// Record a send failure. A failure with nothing to say is dropped here, so
    /// callers can hand over everything they catch.
    func note(_ error: Error) {
        guard let sentence = Self.sentence(for: error) else { return }
        latest = sentence
    }

    /// Read and clear, so one refusal is spoken once.
    func take() -> String? {
        defer { latest = nil }
        return latest
    }

    static func sentence(for error: Error) -> String? {
        guard let api = error as? APIError, case .http(let status, let body) = api else { return nil }
        let raw = body ?? ""
        // 403 + `account_too_young`: the room makes newcomers wait
        // (`_enforce_group_age_floor` in messages.py). An island too old to
        // send the number still refuses with the code, so the sentence has to
        // work without one: "about 1 h" is the floor the island itself reports
        // (`max(1, ceil(...))`).
        if status == 403, raw.contains("account_too_young") {
            let hours = number(named: "hours_left", in: raw) ?? 1
            return String(format: "chat.age_gate.wait".localized, hours)
        }
        // ⚠ A 429 is not always slow mode. A fan-out budget refusal is one too,
        // and calling that "slow mode is on" in a room that has none is a lie.
        // Only the countdown form claims it; the rest stays a red bubble.
        if status == 429 {
            guard let sec = number(named: "retry_after", in: raw), sec > 0 else { return nil }
            return String(format: "chat.slowmode.wait".localized, sec)
        }
        return nil
    }

    /// Pull an integer field out of the island's error body. The body is
    /// `{"detail": {"code": ..., "hours_left": 3}}` today, but this has to
    /// survive an island that wraps it differently or sends it as a string, so
    /// the JSON walk falls back to a regex over the raw text.
    private static func number(named key: String, in body: String) -> Int? {
        if let data = body.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let scope = (root["detail"] as? [String: Any]) ?? root
            if let n = scope[key] as? Int { return n }
            if let d = scope[key] as? Double { return Int(d.rounded()) }
            if let s = scope[key] as? String, let n = Int(s) { return n }
        }
        guard let range = body.range(
            of: "\"\(key)\"\\s*:\\s*\"?(\\d+)", options: .regularExpression
        ) else { return nil }
        return Int(body[range].filter(\.isNumber))
    }
}

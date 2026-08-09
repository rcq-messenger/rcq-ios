import Foundation

/// What did the user just paste into "Add relay"?
///
/// One field takes two different things, because from the outside they are the
/// same act: somebody handed me a string and I want the app to use it. A
/// contact shares `rcq-relay://…`, which is ONE node; the cabinet hands out an
/// access key, which unlocks a SET. The cabinet's own instructions point at
/// this exact field, so refusing the key it just issued would be the product
/// contradicting itself.
///
/// Kept out of the view so the decision is testable, and deliberately mirrors
/// `net/RelayInput.kt` on Android — including the rule below, which is the part
/// worth getting identical on both.
enum RelayInput {
    case link(ContactRelayStore.Relay)
    /// A paid tenant key. Whether it is a GOOD key is not knowable here — only
    /// the broker can say — so this is about SHAPE, and the answer arrives with
    /// the refresh that follows.
    case accessKey(String)
    case unusable

    /// Shorter than this is a typo, not a secret. The console issues 32
    /// characters of base64url; 16 leaves room for another issuer without
    /// letting "abc" through.
    static let minKeyLength = 16

    nonisolated static func classify(_ raw: String) -> RelayInput {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return .unusable }
        // A link is tried FIRST and on its own terms. ⚠ A malformed
        // rcq-relay:// must NOT fall through and get stored as an access key,
        // or a typo in a shared node silently becomes a dead subscription the
        // user has no way to connect to what they did.
        if let r = ContactRelayStore.relayFromToken(s) { return .link(r) }
        if s.contains("://") { return .unusable }
        return s.count >= minKeyLength ? .accessKey(s) : .unusable
    }
}

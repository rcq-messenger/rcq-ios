import CryptoKit
import Foundation

/// The Ed25519 keys this build will accept a signature from, by what the
/// signature authorises. Mirrors Android `SigningKeys.kt`.
///
/// ## Why a set, and why it is compiled in
///
/// Every client used to pin exactly one key, written out in six places across
/// three codebases. That does not make rotation awkward, it makes it
/// impossible: a client that knows one key cannot be handed a payload signed by
/// any other, so the day that key has to change is the day every installed
/// client stops receiving relay updates and quietly runs on its bundled list
/// until the fleet moves out from under it.
///
/// Which matters, because the private half is not well kept. It lives on one
/// laptop, and a second copy of the relay key sits on the production droplet so
/// the canary can re-sign after a failover — so a droplet compromise hands over
/// the ability to point every user's traffic wherever the attacker likes.
///
/// Accepting a set fixes the part that matters: ship the successor, keep
/// signing with the incumbent, and switching becomes a signing-side decision
/// with no release and no flag day. Retiring the old key still needs a release,
/// but retiring is never the urgent direction.
///
/// The set deliberately does NOT come from the signed payload. Letting a config
/// carry its own future keys would make even introducing a key releaseless, and
/// would also let an attacker holding the current key sign a payload adding one
/// of their own — after which rotating away from the stolen key evicts nobody,
/// because theirs is pinned in every client's cache. Rotation would be theatre.
/// Compiled in, a compromise lasts until we sign with the successor and not one
/// payload longer.
///
/// ## Roles
///
/// Relay config and the island list authorise different things: where traffic
/// is tunnelled, versus which island an account is silently given a backup
/// mailbox on. One key covers both today, so a leak costs both at once; each
/// role also lists its own successor, which is what lets them be pulled apart
/// later without a release.
enum SigningKeys {

    enum Role {
        case relayConfig
        case islandList
    }

    /// In use since 2026-05. Signs relay-config AND auto-islands, which is the
    /// overlap the role split exists to end.
    private static let incumbent = "TY834OFcBvtUqHcnVw/QrPBOaEAZo7a1GAmABMhjkT8="

    /// Generated 2026-08-05, held offline, has never signed anything. Present
    /// so switching to it costs a signing decision rather than a release.
    private static let relaySuccessor = "sr0g2D8rXZiEdU8cA6gaIWKxA34QIsysUJQsEeloL1o="

    /// Generated 2026-08-05 for the island role alone, so the day the relay key
    /// is rotated or leaks, the island list does not have to move with it.
    private static let islandSuccessor = "YsA429yi8BeQKQVvi0HSykrK0SVsJlhNKhFwC+g7VWo="

    private static func accepted(_ role: Role) -> [Curve25519.Signing.PublicKey] {
        let b64: [String]
        switch role {
        case .relayConfig: b64 = [incumbent, relaySuccessor]
        case .islandList: b64 = [incumbent, islandSuccessor]
        }
        return b64.compactMap { encoded in
            guard let raw = Data(base64Encoded: encoded) else { return nil }
            return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
        }
    }

    /// True when `signature` is valid over `message` under ANY key this build
    /// accepts for `role`.
    ///
    /// Every candidate is tried even after one succeeds, so which key signed a
    /// payload is not observable from how long verification took.
    static func verify(_ role: Role, message: Data, signature: Data) -> Bool {
        var ok = false
        for key in accepted(role) where key.isValidSignature(signature, for: message) {
            ok = true
        }
        return ok
    }

    /// Convenience for callers holding a base64 signature.
    static func verify(_ role: Role, message: Data, signatureB64: String) -> Bool {
        guard let sig = Data(base64Encoded: signatureB64) else { return false }
        return verify(role, message: message, signature: sig)
    }

    /// Ed25519 under a key the CALLER hands in, for a payload that names its
    /// own signer. Used by `.rcq` site manifests (`SiteManifest`).
    ///
    /// ⚠⚠ Deliberately NOT a `Role`, and it must never become one. A Role is a
    /// key this BUILD accepts, compiled in for the reason the comment at the top
    /// of this file gives: so a stolen key can be retired by signing with its
    /// successor instead of by shipping a release. A site's key is the opposite
    /// kind of thing — it arrives inside the payload, anybody with an island
    /// account can mint one, and there are as many of them as there are sites.
    /// Adding one to the accepted set would let whoever published a site sign
    /// relay config and the island list, which is the whole fleet.
    ///
    /// What this function proves is only that ONE key signed these bytes. What
    /// binds that key to a site is the trust-on-first-use pin in `SitePins`, the
    /// same rule as safety numbers — never this call on its own.
    static func verify(publicKey: Data, message: Data, signature: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else {
            return false
        }
        return key.isValidSignature(signature, for: message)
    }
}

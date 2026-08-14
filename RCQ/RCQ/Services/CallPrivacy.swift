import Foundation

/// Whether calls must ride the relay, and why the default is on.
///
/// ⚠ WebRTC opens its own sockets, outside everything else this app routes. A
/// direct call therefore hands the other side your real address before a word
/// is spoken, and no privacy setting elsewhere can prevent it. Relaying costs
/// bandwidth and a little latency; being findable costs more.
///
/// ★ It is a SETTING because it was previously forced with no way out:
/// relay-only whenever a relay could be reached. Somebody on a good line who
/// would rather have the quality had no way to say so, and Android has had the
/// switch since 0.108 with this exact wording. Device-local, like there.
enum CallPrivacy {
    private static let key = "rcq.call.alwaysRelay"

    /// Route every call through the relay so the peer never learns your address.
    static var alwaysRelay: Bool {
        get {
            // Default ON: a fresh install is private before anyone opens
            // Settings. `object(forKey:)` rather than `bool(forKey:)` because
            // the latter cannot tell "off" from "never set".
            UserDefaults.standard.object(forKey: key) as? Bool ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

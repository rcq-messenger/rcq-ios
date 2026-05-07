import Foundation

/// Tracks how often each emoticon asset has been sent — drives the
/// "most-used first" ordering in the chat composer's emoji panel
/// default tab. Counts persist in UserDefaults so the user's
/// frequently-used set survives an app relaunch (and burn — same
/// rationale as the onboarding flag).
///
/// Bump points: every `MessageService.send` of a text message
/// runs the body through `Emoticons.tokenize` and bumps each
/// matched asset by one. The store is small (≤ a few hundred
/// asset names × Int — well under 10 KB even at full saturation),
/// so we don't bother trimming.
@MainActor
final class EmoticonUsageStore: ObservableObject {
    static let shared = EmoticonUsageStore()

    private let key = "rcq.emoticon_usage"
    @Published private(set) var counts: [String: Int]

    private init() {
        let dict = UserDefaults.standard.dictionary(forKey: key) as? [String: Int]
        self.counts = dict ?? [:]
    }

    /// Bump usage for one asset.
    func bump(_ asset: String) {
        counts[asset, default: 0] += 1
        persist()
    }

    /// Bump usage for every emoticon found inside a plain-text
    /// message — used at send time so the most-frequently-typed
    /// codes float to the top of the picker.
    func bump(forText text: String) {
        var changed = false
        for token in Emoticons.tokenize(text) {
            if case .emoticon(let asset, _) = token {
                counts[asset, default: 0] += 1
                changed = true
            }
        }
        if changed { persist() }
    }

    private func persist() {
        UserDefaults.standard.set(counts, forKey: key)
    }
}

import Foundation

/// Fire-and-forget auto-tick for Daily QA items.
///
/// `DailyQACard` shows a manual checklist a tester ticks by tap,
/// but for the most common actions we already know — sending a
/// message, opening a lootbox, reacting, replying — we just call
/// `tick(.X)` from the relevant code path so the box auto-checks
/// without bothering the tester. Manual tap remains as a fallback
/// for the catalog items we haven't instrumented yet.
///
/// In-memory dedupe per (slug, UTC-date) skips redundant network
/// hits when a user sends 10 messages in a row — we already ticked
/// `send_message_*` on the first one and the server idempotently
/// no-ops anyway, but the saved roundtrip keeps the chat fast.
@MainActor
final class SmokeTracker {
    static let shared = SmokeTracker()

    enum Item: String {
        case sendMessage1to1   = "send_message_1to1"
        case sendMessageGroup  = "send_message_group"
        case openLootbox       = "open_lootbox"
        case sendGif           = "send_gif"
        case sendSticker       = "send_sticker"
        case sendPhoto         = "send_photo"
        case sendVideo         = "send_video"
        case sendVoice         = "send_voice"
        case sendLocation      = "send_location"
        case placeCrashBet     = "place_crash_bet"
        case playHilo          = "play_hilo"
        case playLimbo         = "play_limbo"
        case visitHood         = "visit_hood"
        case dropHoodBanner    = "drop_hood_banner"
        case createAudioRoom   = "create_audio_room"
        case joinAudioRoom     = "join_audio_room"
        case petHunt           = "pet_hunt"
        case buyMarket         = "buy_market"
        case listMarket        = "list_market"
        case watchStory        = "watch_story"
        case postStory         = "post_story"
        case updateProfile     = "update_profile"
        case switchTheme       = "switch_theme"
        case openInventory     = "open_inventory"
        case sendReaction      = "send_reaction"
        case replyToMessage    = "reply_to_message"
    }

    private var dedupe: Set<String> = []
    private let dayFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()

    private init() {}

    /// Mark the catalog slug as completed for today. Cheap to call
    /// from hot paths — first call per (slug, day) hits the server,
    /// subsequent calls within the same UTC day are skipped.
    func tick(_ item: Item) {
        let key = item.rawValue + ":" + dayFormatter.string(from: Date())
        guard !dedupe.contains(key) else { return }
        dedupe.insert(key)

        struct Body: Encodable { let slug: String }
        struct Out: Decodable {
            let completed_count: Int
            let total: Int
            let bounty_minted: Bool
            let minted_amount: Int
        }
        Task { [weak self] in
            do {
                let _: Out = try await APIClient.shared.request(
                    "POST", "/smoke/tick", body: Body(slug: item.rawValue)
                )
            } catch {
                // Fire-and-forget: an offline tick is fine to drop —
                // the user can still manually tap the checkbox if
                // they care. Drop the dedupe entry so a retry can
                // land later.
                await MainActor.run {
                    _ = self?.dedupe.remove(key)
                }
            }
        }
    }
}

import Foundation

/// Daily QA gamification was removed in the 2026-05-27 pivot. The
/// tracker stays as a compile-time shim so the call sites scattered
/// across MessageService / ThemeManager keep building without
/// surgery; the `tick` method is now a no-op. Drop the helper
/// entirely if those call sites are cleaned up later.
@MainActor
final class SmokeTracker {
    static let shared = SmokeTracker()

    enum Item: String {
        case sendMessage1to1   = "send_message_1to1"
        case sendMessageGroup  = "send_message_group"
        case sendGif           = "send_gif"
        case sendSticker       = "send_sticker"
        case sendPhoto         = "send_photo"
        case sendVideo         = "send_video"
        case sendVoice         = "send_voice"
        case sendLocation      = "send_location"
        case createAudioRoom   = "create_audio_room"
        case joinAudioRoom     = "join_audio_room"
        case watchStory        = "watch_story"
        case postStory         = "post_story"
        case updateProfile     = "update_profile"
        case switchTheme       = "switch_theme"
        case sendReaction      = "send_reaction"
        case replyToMessage    = "reply_to_message"
    }

    private init() {}

    func tick(_ item: Item) {
        _ = item
    }
}

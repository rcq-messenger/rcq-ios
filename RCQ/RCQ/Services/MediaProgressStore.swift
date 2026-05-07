import Combine
import Foundation

/// Per-message upload-progress tracker. Lives outside the Message
/// model so bubble rendering can subscribe without touching the
/// rest of the chat state graph. Used by photo + video bubbles
/// to overlay a circular progress ring while the encrypted blob
/// is in-flight to `/media/upload`.
///
/// Keyed by message UUID so the same store works for regular chats
/// (MessageStore-backed) and ephemeral random chats
/// (RandomChatService-backed) — both buffer messages by the same
/// id space. Entries are cleared on upload completion (success or
/// failure) so a finished bubble doesn't keep showing 100% under
/// its photo.
@MainActor
final class MediaProgressStore: ObservableObject {
    static let shared = MediaProgressStore()

    @Published private(set) var progress: [UUID: Double] = [:]

    private init() {}

    /// Record the start of an upload at 0.0. The caller hands back
    /// the closure they pass to `MediaService.uploadImage` /
    /// `uploadFile`; that closure feeds tick updates into `set`.
    /// Pre-populating the dict on `begin` means the bubble overlay
    /// appears immediately, before the first KVO callback fires.
    func begin(_ id: UUID) {
        progress[id] = 0
    }

    func set(_ id: UUID, value: Double) {
        // Clamp to [0, 1] — `URLSessionTaskMetrics` occasionally
        // emits values slightly past 1.0 on completion.
        progress[id] = max(0, min(1, value))
    }

    /// Drop the entry. Called on upload success or failure so the
    /// overlay disappears once the bubble has its real content.
    func clear(_ id: UUID) {
        progress.removeValue(forKey: id)
    }

    func value(for id: UUID) -> Double? {
        progress[id]
    }
}

import Foundation

extension Message {
    /// Short, single-line description for surfaces that don't render the
    /// bubble itself — in-app message banner, push body fallback. Mirrors
    /// the in-chat reply-snippet shape so a forwarded preview reads
    /// the same in both places.
    var previewSnippet: String {
        if deletedForEveryone { return "chat.preview.deleted".localized }
        let raw: String
        switch kind {
        case .text:         raw = text
        case .photo:        raw = text.isEmpty ? "chat.preview.photo".localized : "📷 \(text)"
        case .video:        raw = text.isEmpty ? "chat.preview.video".localized : "🎬 \(text)"
        case .voice:        raw = "chat.preview.voice".localized
        case .file:         raw = "📎 \(fileName ?? "chat.preview.file".localized)"
        case .location:     raw = "📍 \("chat.preview.location".localized)"
        case .premiumPhoto: raw = "chat.preview.premium_photo".localized
        case .premiumVideo: raw = "chat.preview.premium_video".localized
        default:            raw = text.isEmpty ? "chat.preview.generic".localized : text
        }
        if raw.count <= 80 { return raw }
        return raw.prefix(80) + "…"
    }
}

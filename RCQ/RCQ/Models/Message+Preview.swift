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
        case .text:
            // Market / UIN share links land as `.text` kind with just
            // the URL in the body — render a friendly summary so the
            // chat list / in-app banner / push body don't display
            // `https://rcq.app/m/<id>` as the message preview.
            if Self.isMarketShareURL(text) {
                raw = "🛍️ \("chat.preview.market_item".localized)"
            } else if Self.isUinShareURL(text) {
                raw = "#️⃣ \("chat.preview.uin_listing".localized)"
            } else {
                raw = text
            }
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

    private static func isMarketShareURL(_ body: String) -> Bool {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return false }
        if url.scheme == "rcq" && url.host == "market" {
            return !(url.pathComponents.last ?? "").isEmpty
        }
        if (url.scheme == "https" || url.scheme == "http"),
           url.host == "rcq.app",
           url.pathComponents.count >= 3,
           url.pathComponents[1] == "m" {
            return true
        }
        return false
    }

    private static func isUinShareURL(_ body: String) -> Bool {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return false }
        if url.scheme == "rcq" && url.host == "uin-listing" {
            return !(url.pathComponents.last ?? "").isEmpty
        }
        if (url.scheme == "https" || url.scheme == "http"),
           url.host == "rcq.app",
           url.pathComponents.count >= 3,
           url.pathComponents[1] == "ul" {
            return true
        }
        return false
    }
}

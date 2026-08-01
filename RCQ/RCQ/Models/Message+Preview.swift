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
            // Market / UIN / group share links land as `.text` kind
            // with just the URL in the body — render a friendly
            // summary so the chat list / in-app banner / push body /
            // in-chat reply-strip don't display the raw URL.
            if Self.isMarketShareURL(text) {
                raw = "🛍️ \("chat.preview.market_item".localized)"
            } else if Self.isUinShareURL(text) {
                raw = "#️⃣ \("chat.preview.uin_listing".localized)"
            } else if Self.isGroupShareURL(text) {
                raw = "👥 \("chat.preview.group_invite".localized)"
            } else {
                raw = text
            }
        case .photo:        raw = text.isEmpty ? "chat.preview.photo".localized : "📷 \(text)"
        case .video:        raw = text.isEmpty ? "chat.preview.video".localized : "🎬 \(text)"
        case .voice:        raw = "chat.preview.voice".localized
        case .file:         raw = "📎 \(fileName ?? "chat.preview.file".localized)"
        case .location:     raw = "📍 \("chat.preview.location".localized)"
        case .poll:
            // `.poll` messages store the full PollPayload (question +
            // options + flags) as JSON in `text`. Pull out the
            // question for a humane preview — the JSON blob itself
            // was previously rendering as raw braces / quotes in
            // reply strips and chat-preview snippets.
            let question = PollPayload.decode(from: text)?.question
                ?? "chat.preview.poll".localized
            raw = "📊 \(question)"
        case .systemNotice:
            // A screenshot notice stores a control-char sentinel as its text so
            // the screenshotter's name can resolve at display time (see
            // Message.systemNoticeText). Previews run off the main actor and
            // cannot resolve the contact, but they must never fall through to
            // `raw = text` and print "\u{1}rcq.secscreen\u{1}" into a banner.
            // This became reachable when the live socket started accepting
            // "secscreen": before that the notice only arrived on the silent
            // queue drain, which never banners.
            raw = text == Message.screenshotSentinel
                ? "📸 \("secscreen.preview".localized)"
                : (text.isEmpty ? "chat.preview.generic".localized : text)
        case .relay:
            raw = "🛡️ \("chat.preview.relay".localized)"
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

    private static func isGroupShareURL(_ body: String) -> Bool {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return false }
        if url.scheme == "rcq" && url.host == "group" {
            return !(url.pathComponents.last ?? "").isEmpty
        }
        if (url.scheme == "https" || url.scheme == "http"),
           url.host == "rcq.app",
           url.pathComponents.count >= 3,
           url.pathComponents[1] == "g" {
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

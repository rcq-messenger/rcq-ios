import os.log
import UserNotifications

/// Notification Service Extension. Runs in its own process whenever an
/// APNs push lands with `mutable-content: 1` set. We have ~30s of
/// wallclock and 24MB of memory to:
///
///   1. Pull the encrypted envelope blob out of the push's `userInfo`.
///   2. Decrypt it locally using the X25519/Ed25519 private keys we
///      share with the main app via Keychain Sharing access group
///      `P29Q334JHX.app.rcq.shared`.
///   3. Replace the generic "New message" title/body with the real
///      sender (UIN string for now — contact-name lookup needs a
///      shared-group file we haven't built yet) and the actual message
///      preview.
///
/// If anything goes wrong (no key, malformed payload, decrypt failure)
/// we hand the push back unmodified so the user still sees *something*.
/// Better the generic alert than nothing at all.
///
/// Logs go through `os_log` so they show up in Console.app under the
/// `RCQ.NotificationService` subsystem — main-app `print` output goes to
/// a different log stream.
class NotificationService: UNNotificationServiceExtension {

    private static let log = OSLog(subsystem: "app.rcq.client.notification", category: "NSE")

    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttempt: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        self.bestAttempt = content

        os_log("didReceive: title=%{public}@ body=%{public}@",
               log: Self.log, type: .default,
               request.content.title, request.content.body)

        let userInfo = request.content.userInfo
        guard
            let envB64 = userInfo["env"] as? String,
            let envType = userInfo["envType"] as? String
        else {
            // No `env` field. This is either a non-sealed push
            // (contact_request, trade_received, contact_response_accepted)
            // that we still want to localize off `notif_kind`, or a
            // truly minimal push we just pass through.
            if let kind = userInfo["notif_kind"] as? String {
                applyLocalizedPushBody(kind: kind, to: content)
                os_log("non-env push localized: kind=%{public}@ body=%{public}@",
                       log: Self.log, type: .default, kind, content.body)
            } else {
                os_log("no env/envType/notif_kind in userInfo — passing through unmodified",
                       log: Self.log, type: .default)
            }
            contentHandler(content)
            return
        }
        os_log("env present (len=%d), envType=%{public}@",
               log: Self.log, type: .default, envB64.count, envType)

        guard let crypto = SignalCryptoService.loadFromKeychain(ownUIN: 0) else {
            os_log("no identity in keychain (shared group missing?) — passing through",
                   log: Self.log, type: .error)
            contentHandler(content)
            return
        }

        // Full decrypt is safe to do here as long as we hand the
        // resulting plaintext off to `PushDecryptCache` — the main
        // app's `MessageService.ingest` consults the cache before
        // calling `crypto.decrypt`, so the v=2 libsignal ratchet
        // only advances ONCE (here in the NSE) instead of being
        // double-stepped by NSE + main app and breaking the second
        // decrypt. v=1 envelopes are stateless so the cache is
        // optional for them, but populating it uniformly keeps the
        // ingest-side code path the same for both versions.
        do {
            let decrypted = try crypto.decrypt(envelopeB64: envB64)
            os_log("decrypted OK: from=%d kind=%{public}@",
                   log: Self.log, type: .default,
                   decrypted.senderUIN, envelopeKind(decrypted.envelope))
            // ICQ-style mutual remove: if the user previously dropped this
            // contact, silently suppress the push. PushDecryptCache stays
            // un-touched so the main app's MessageService.ingest can also
            // re-evaluate (and double-drop) when it sees the envelope.
            if RemovedContactsStore.shared.contains(decrypted.senderUIN) {
                contentHandler(UNNotificationContent())
                return
            }
            PushDecryptCache.store(
                ciphertextB64: envB64,
                senderUIN: decrypted.senderUIN,
                envelope: decrypted.envelope
            )
            apply(decrypted: decrypted, to: content)
            os_log("modified: title=%{public}@ body=%{public}@",
                   log: Self.log, type: .default,
                   content.title, content.body)
            contentHandler(content)
        } catch {
            os_log("decrypt failed: %{public}@",
                   log: Self.log, type: .error,
                   String(describing: error))
            contentHandler(content)
        }
    }

    /// Sender's name → title; envelope type → body. Falls back to a
    /// non-empty placeholder for any case where the inner content is
    /// empty so iOS doesn't render a notification with a blank body.
    private func apply(decrypted: DecryptedEnvelope, to content: UNMutableNotificationContent) {
        // Sender's name. The main app pushes a `uin → nickname` cache
        // into the App Group on every contact-list refresh, so we have
        // a recent value here in most cases. Falls back to a `#UIN`
        // tag when the sender isn't in our contacts (e.g. an open
        // random-chat session, or a contact added on another device).
        if let nick = NicknameCache.nickname(for: decrypted.senderUIN) {
            content.title = nick
        } else {
            content.title = "#\(decrypted.senderUIN)"
        }
        // Group threading by sender so iOS stacks multiple messages
        // from the same UIN into a single notification group AND
        // gives the main app's `didReceive` handler a deterministic
        // `peer-<UIN>` token to parse for tap-routing.
        let threadKey = "peer-\(decrypted.senderUIN)"
        content.threadIdentifier = threadKey

        // User-visible envelopes bump the unread counter so the icon
        // gets a badge. Read receipts / reactions / bounces / edits /
        // delete-for-everyone do NOT bump — they're plumbing the main
        // app handles silently. Setting `content.badge` here is what
        // makes iOS update the icon's red dot; without it iOS leaves
        // the previous value alone (typically 0).
        if Self.envelopeIsUserVisible(decrypted.envelope) {
            let total = BadgeCounter.increment(threadKey: threadKey)
            content.badge = NSNumber(value: total)
        }

        switch decrypted.envelope {
        case .text(_, let text, _, _, _):
            if text.isEmpty {
                content.body = "Message"
            } else if Self.isMarketShareURL(text) {
                content.body = "🛍️ Shared a marketplace item"
            } else if Self.isUinShareURL(text) {
                content.body = "#️⃣ Shared a UIN listing"
            } else {
                content.body = text
            }
        case .photo(_, _, _, let caption, _, _, _, _):
            let cap = caption?.trimmingCharacters(in: .whitespaces) ?? ""
            content.body = cap.isEmpty ? "📷 Photo" : "📷 \(cap)"
        case .video(_, _, _, _, _, let caption, _, _, _, _):
            let cap = caption?.trimmingCharacters(in: .whitespaces) ?? ""
            content.body = cap.isEmpty ? "🎬 Video" : "🎬 \(cap)"
        case .voice:
            content.body = "🎤 Voice message"
        case .file(_, _, _, let fname, _, _, let caption, _, _, _):
            let cap = caption?.trimmingCharacters(in: .whitespaces) ?? ""
            content.body = cap.isEmpty ? "📎 \(fname)" : "📎 \(fname) — \(cap)"
        case .location(_, _, _, let caption, _, _, _):
            let cap = caption?.trimmingCharacters(in: .whitespaces) ?? ""
            content.body = cap.isEmpty ? "📍 Location" : "📍 Location — \(cap)"
        case .premiumPhoto(_, _, let price, _, let caption, _, _, _, _):
            // Always include the price so the recipient sees the
            // tap-cost up front in the notification surface — same
            // as Telegram's "Premium content (X stars)" preview.
            let cap = caption?.trimmingCharacters(in: .whitespaces) ?? ""
            let label = cap.isEmpty ? "Premium photo" : "Premium photo: \(cap)"
            content.body = "🔒 \(label) — \(price)"
        case .premiumVideo(_, _, let price, _, _, let caption, _, _, _, _):
            let cap = caption?.trimmingCharacters(in: .whitespaces) ?? ""
            let label = cap.isEmpty ? "Premium video" : "Premium video: \(cap)"
            content.body = "🔒 \(label) — \(price)"
        case .systemNotice(_, let text):
            content.body = text.isEmpty ? "System notice" : text
        case .poll(_, _, let question, _, _, _):
            let q = question.trimmingCharacters(in: .whitespaces)
            content.body = q.isEmpty ? "📊 New poll" : "📊 \(q)"
        case .deleteForEveryone, .readReceipt, .reaction, .bounce, .visit, .edit:
            content.body = "Message"
        }
    }

    /// Replace `content.body` with a localized string matching the
    /// `notif_kind` the backend stamped on this push. Reads the
    /// active language from the App Group UserDefaults (mirror of
    /// `LanguageManager.current` written by the main app), then
    /// loads the corresponding lproj from the NSE's own bundle.
    /// Falls back to the development language (en) for any kind we
    /// don't recognise — the original body the backend sent stays
    /// in place as the ultimate fallback if even the en bundle
    /// lookup misses, so the user always sees readable text.
    private func applyLocalizedPushBody(kind: String, to content: UNMutableNotificationContent) {
        let key: String
        // Outbid pushes localize both title + body — every other kind
        // keeps the server-set sender nickname as title.
        var titleKey: String? = nil
        switch kind {
        case "contact_request":           key = "push.contact_request.body"
        case "contact_response_accepted": key = "push.contact_response_accepted.body"
        case "trade_received_gift":       key = "push.trade_received.gift.body"
        case "trade_received_offer":      key = "push.trade_received.offer.body"
        case "uin_auction_outbid":
            key = "push.uin_auction_outbid.body"
            titleKey = "push.uin_auction_outbid.title"
        default: return
        }
        let localized = Self.pushLocalized(key)
        if !localized.isEmpty && localized != key {
            content.body = localized
        }
        if let titleKey {
            let localizedTitle = Self.pushLocalized(titleKey)
            if !localizedTitle.isEmpty && localizedTitle != titleKey {
                content.title = localizedTitle
            }
        }
    }

    /// Look up `key` in NSE's bundled Localizable.strings, using
    /// the language the user picked in the main app (mirrored to
    /// the App Group).
    ///
    /// Resolution order, first hit wins:
    ///   1. `AppGroup.languageFileURL` — flat file the main app's
    ///      `LanguageManager` writes on every set. This is the
    ///      authoritative source. Files are reliable; App Group
    ///      `UserDefaults` is not (cfprefsd "detaches" routinely).
    ///   2. App Group `UserDefaults` mirror — secondary, kept for
    ///      back-compat with already-installed app builds that
    ///      wrote here before we switched to the file mirror.
    ///   3. `Locale.preferredLanguages` — iterate through the
    ///      system's preferred languages until we find one whose
    ///      lproj exists in the NSE bundle. Catches a Russian
    ///      speaker on an English-set iPhone whose Russian sits
    ///      second in the system list (we'd otherwise pick "en"
    ///      from `first` and miss them).
    ///   4. Hardcoded "en" — final fallback.
    ///
    /// Diagnostic logs go through `os_log` at `.default` level so
    /// they show up in Console.app *without* "Include Info Messages"
    /// being toggled on — which is normally off for first-time
    /// debuggers and made the previous `.info` logs invisible in
    /// the user's troubleshooting dump.
    private static func pushLocalized(_ key: String) -> String {
        let stored = readAppGroupLanguage()
        let preferred = Locale.preferredLanguages
        let nseBundle = Bundle(for: NotificationService.self)

        let candidates: [String] = {
            var seen = Set<String>()
            var ordered: [String] = []
            func add(_ raw: String?) {
                guard let raw, !raw.isEmpty else { return }
                let stripped = String(raw.split(separator: "-").first ?? "")
                guard !stripped.isEmpty, !seen.contains(stripped) else { return }
                seen.insert(stripped)
                ordered.append(stripped)
            }
            add(stored)
            for lang in preferred { add(lang) }
            add("en")
            return ordered
        }()

        os_log("pushLocalized: stored=%{public}@ preferred=%{public}@ candidates=%{public}@ key=%{public}@",
               log: Self.log, type: .default,
               stored ?? "nil",
               preferred.joined(separator: ","),
               candidates.joined(separator: ","),
               key)

        for lang in candidates {
            guard let path = nseBundle.path(forResource: lang, ofType: "lproj"),
                  let bundle = Bundle(path: path) else {
                os_log("pushLocalized: %{public}@.lproj not in NSE bundle, skipping",
                       log: Self.log, type: .default, lang)
                continue
            }
            let s = bundle.localizedString(forKey: key, value: "", table: nil)
            os_log("pushLocalized: tried %{public}@.lproj value=%{public}@",
                   log: Self.log, type: .default, lang, s)
            if !s.isEmpty && s != key {
                return s
            }
        }

        os_log("pushLocalized: no lproj resolved key, returning raw",
               log: Self.log, type: .error)
        return key
    }

    /// Read the active language code from the App Group. Tries the
    /// flat file first (reliable across processes), then the
    /// `UserDefaults(suiteName:)` mirror (cfprefsd-backed, often
    /// stale). Returns nil if the main app has never written
    /// either — caller falls through to the system locale.
    private static func readAppGroupLanguage() -> String? {
        if let data = try? Data(contentsOf: AppGroup.languageFileURL),
           let text = String(data: data, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        let shared = UserDefaults(suiteName: AppGroup.identifier)
        return shared?.string(forKey: "rcq.app_language")
    }

    /// User-visible envelopes drive the badge counter. Silent envelopes
    /// (read receipts, reactions, bounces, edits, delete-for-everyone)
    /// are plumbing — they still come through NSE so the ratchet
    /// advances in the right process, but they must not inflate the
    /// unread count.
    private static func envelopeIsUserVisible(_ envelope: Envelope) -> Bool {
        switch envelope {
        case .text, .photo, .video, .voice, .file, .location,
             .premiumPhoto, .premiumVideo, .systemNotice, .poll:
            return true
        case .deleteForEveryone, .readReceipt, .reaction, .bounce, .visit, .edit:
            return false
        }
    }

    private func envelopeKind(_ envelope: Envelope) -> String {
        switch envelope {
        case .text:             return "text"
        case .photo:            return "photo"
        case .video:            return "video"
        case .voice:            return "voice"
        case .file:             return "file"
        case .location:         return "location"
        case .deleteForEveryone: return "delete"
        case .systemNotice:     return "system"
        case .readReceipt:      return "read"
        case .reaction:         return "reaction"
        case .bounce:           return "bounce"
        case .visit:            return "visit"
        case .edit:             return "edit"
        case .premiumPhoto:     return "premium_photo"
        case .premiumVideo:     return "premium_video"
        case .poll:             return "poll"
        }
    }

    /// Inline mirror of the in-app `MarketLinkParser` — NSE is a
    /// separate target and can't import the main app's view code, so
    /// the URL-shape check is duplicated here. Both `rcq://market/<id>`
    /// (deep link) and `https://rcq.app/m/<id>` (web link) qualify.
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

    /// Inline mirror of `UinLinkParser` — see note above.
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

    override func serviceExtensionTimeWillExpire() {
        // 30-second wall-clock is up. Hand back whatever we managed to
        // build — the original (generic) content is fine if decryption
        // didn't finish.
        os_log("serviceExtensionTimeWillExpire — handing back best-attempt",
               log: Self.log, type: .error)
        if let handler = contentHandler, let content = bestAttempt {
            handler(content)
        }
    }
}

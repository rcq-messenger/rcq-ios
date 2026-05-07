import Combine
import Foundation
import UIKit

@MainActor
final class ChatViewModel: ObservableObject {
    let target: ChatTarget

    @Published var messages: [Message] = []
    @Published var input: String = ""
    @Published var isPeerTyping: Bool = false
    /// Mirror of `MessageStore.fadingOutIDs` so SwiftUI rows can
    /// observe their own fade-out flag without the row each
    /// directly subscribing to MessageStore. Powers the smooth
    /// receive-side delete-for-everyone animation.
    @Published var fadingOutIDs: Set<UUID> = []
    /// The message we're currently composing a reply to. Set by
    /// swipe-right on a bubble; cleared by tap on the X button in
    /// the compose preview, or by `send()` after a successful send.
    /// ChatView reads this to render the quote-block strip above the
    /// input bar.
    @Published var replyTarget: Message?
    /// The message we're currently editing. Mutually exclusive with
    /// `replyTarget` — entering edit mode clears any pending reply
    /// and vice versa, since the composer can only do one job at a
    /// time. Set by the long-press → Edit action on an own text
    /// bubble; cleared by `send()` after a successful edit, or by
    /// the user tapping × in the edit strip.
    @Published var editingTarget: Message?
    /// Cache of in-place translations keyed by message id. Populated
    /// by `ChatView`'s translation task on first long-press →
    /// Translate; mutating the dict swaps the bubble's rendered text
    /// straight from the cache (no modal sheet, no Apple translate
    /// modal, no Google hand-off). Long-press → Translate again
    /// removes the entry to revert to the original.
    @Published var translatedTexts: [UUID: String] = [:]
    /// Set when the user long-press → Translate'd a message that
    /// isn't in `translatedTexts` yet. ChatView observes this to
    /// kick off the actual `TranslationSession.translate(...)` call;
    /// reset to nil once the result has been written into
    /// `translatedTexts` (or the call failed).
    @Published var pendingTranslationMessage: Message?

    private var cancellables = Set<AnyCancellable>()
    private var typingDebounce: Task<Void, Never>?
    /// Last time we shipped an `active=true` typing event to the peer.
    /// Used to throttle the outbound WS chatter — every keystroke
    /// pushing a new event made the peer's indicator flicker and
    /// occasionally desync. We only re-fire `active=true` once per
    /// `typingThrottle` seconds while the user keeps typing.
    private var lastTypingActiveAt: Date?

    init(target: ChatTarget) {
        self.target = target

        // Restore the last unsent draft for this thread. UserDefaults
        // is enough — drafts are local-device convenience; we don't
        // want them syncing or surviving a re-install. Random-chat
        // sessions don't persist drafts (the session is anonymous /
        // ephemeral by design).
        if case .randomPeer = target {
            // Skip restore for random.
        } else if let draft = UserDefaults.standard.string(forKey: Self.draftKey(for: target)),
                  !draft.isEmpty {
            self.input = draft
        }
        // Watch `input` and persist on debounce so quick typing doesn't
        // hammer UserDefaults. Save immediately on empty so a sent /
        // cleared draft doesn't reappear on re-open.
        $input
            .removeDuplicates()
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] text in
                guard let self else { return }
                if case .randomPeer = self.target { return }
                let key = Self.draftKey(for: self.target)
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    UserDefaults.standard.removeObject(forKey: key)
                } else {
                    UserDefaults.standard.set(text, forKey: key)
                }
            }
            .store(in: &cancellables)

        switch target {
        case .randomPeer:
            // Random sessions read from RandomChatService's in-memory buffer,
            // not from MessageStore — those messages never persist.
            // Seed `messages` synchronously from the current buffer so
            // ChatView's first paint already has the live list.
            // No `.receive(on:)` — the source publisher is already on
            // MainActor, and the extra runloop hop swallows the
            // `withAnimation` transactions wrapping store mutations
            // (delete-for-everyone in particular looked abrupt for the
            // *observing* side of a chat — the deleter saw the bubble
            // fade because their tap path also flipped a separate
            // animatable state, the observer had no such accompanying
            // change to ride and the implicit count-watch animation
            // wasn't enough on its own).
            self.messages = RandomChatService.shared.messages
            RandomChatService.shared.$messages
                .assign(to: &$messages)
        default:
            let thread = target.thread
            // Same seed-then-subscribe pattern — without the explicit
            // initial value, opening a chat with persisted history
            // briefly shows the "Say hi" empty-state CTA between init
            // and Combine's first emission.
            self.messages = MessageStore.shared.threads[thread] ?? []
            MessageStore.shared.$threads
                .map { $0[thread] ?? [] }
                .assign(to: &$messages)
            // Track soft-delete flags so each row can fade itself
            // out when MessageStore stages a delete-for-everyone /
            // delete-for-me. Same store across all threads — set
            // membership is cheap and the dictionary is bounded by
            // active deletions in flight (~1 at a time).
            self.fadingOutIDs = MessageStore.shared.fadingOutIDs
            MessageStore.shared.$fadingOutIDs
                .assign(to: &$fadingOutIDs)
        }

        if case .peer(let contact) = target {
            AppState.shared.$typingByUIN
                .receive(on: DispatchQueue.main)
                .map { $0[contact.uin] ?? false }
                .assign(to: &$isPeerTyping)
        }
    }

    /// Per-thread UserDefaults key for the draft text. Local-only —
    /// drafts don't sync to other devices and don't survive a
    /// reinstall (intentional).
    private static func draftKey(for target: ChatTarget) -> String {
        switch target {
        case .peer(let c):       return "rcq.draft.peer.\(c.uin)"
        case .group(let g):      return "rcq.draft.group.\(g.id)"
        case .randomPeer(let p): return "rcq.draft.random.\(p.uin)"  // unused — random skips
        }
    }

    func onAppear() {
        switch target {
        case .peer(let contact): ContactService.shared.clearUnread(for: contact.uin)
        case .group(let group):  GroupService.shared.clearUnread(group.id)
        case .randomPeer: break  // ephemeral — no persisted unread to clear
        }
        // Read receipts on random sessions don't make sense (and we don't want
        // to leak read state on an "anonymous" chat anyway). Skip there.
        if case .randomPeer = target { return }
        Task { await MessageService.shared.markRead(messages: messages, in: target) }
    }

    /// Called when a new message arrives while we're in the chat — keep the read
    /// receipts flowing so the peer's UI doesn't get stuck on `delivered`.
    func ackIfVisible(_ message: Message) {
        guard !message.isFromMe, message.deliveryState != .read else { return }
        Task { await MessageService.shared.markRead(messages: [message], in: target) }
    }

    func toggleReaction(_ asset: String, on message: Message) {
        Task { await MessageService.shared.toggleReaction(on: message, asset: asset, in: target) }
    }

    /// Long-press → Translate dispatcher. If the message already has
    /// a stored translation, REVERT (drop the cache entry → bubble
    /// renders the original again). Otherwise queue the message for
    /// `ChatView`'s `.translationTask` to pick up and translate.
    func toggleTranslate(_ message: Message) {
        if translatedTexts[message.id] != nil {
            translatedTexts.removeValue(forKey: message.id)
            return
        }
        // Empty / whitespace-only bodies — nothing to translate.
        let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingTranslationMessage = message
    }

    /// Returns the rendered body text for a bubble — translated if
    /// present in the cache, original otherwise. Bubble views call
    /// this in their text branch instead of reading `message.text`
    /// directly so the in-place toggle is a single point of swap.
    func displayText(for message: Message) -> String {
        translatedTexts[message.id] ?? message.text
    }

    /// Whether a message has a stored translation currently being
    /// shown (i.e. the long-press menu's Translate row should read
    /// "Show original").
    func isTranslated(_ message: Message) -> Bool {
        translatedTexts[message.id] != nil
    }

    func send() async {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // Stranger-Mode safety: strip URLs and phone numbers from
        // outgoing text. The pair is anonymous and time-limited, so
        // the user has no legitimate reason to share off-platform
        // contact info — and a malicious sender's first move is
        // usually exactly that ("DM me on Telegram @..."). Strip
        // both, leaving the message body intact otherwise.
        if case .randomPeer = target {
            text = ChatViewModel.scrubbedForStrangerMode(text)
        }
        guard !text.isEmpty else { return }
        // Edit-mode short-circuit: if the composer is currently
        // editing a previously-sent bubble, swap the body text via
        // the edit envelope path instead of appending a brand-new
        // message. Empty edits are blocked above.
        if let editing = editingTarget {
            // Skip wire round-trip if the text didn't actually
            // change — saves the recipient an unnecessary mutation
            // and keeps `editedAt` honest.
            if text != editing.text {
                EmoticonUsageStore.shared.bump(forText: text)
                do {
                    switch target {
                    case .peer(let c):       try await MessageService.shared.edit(message: editing, newText: text, to: c)
                    case .group(let g):      try await MessageService.shared.edit(message: editing, newText: text, in: g)
                    case .randomPeer(let p): try await MessageService.shared.edit(message: editing, newText: text, toRandom: p)
                    }
                } catch { }
            }
            editingTarget = nil
            input = ""
            return
        }
        input = ""
        // Bump frequency counters for every emoticon token in the
        // sent body so the picker's default tab can float them
        // to the top on next open.
        EmoticonUsageStore.shared.bump(forText: text)
        let reply = consumeReplyContext()
        do {
            switch target {
            case .peer(let c):       try await MessageService.shared.send(text: text, to: c, replyTo: reply)
            case .group(let g):      try await MessageService.shared.send(text: text, to: g, replyTo: reply)
            case .randomPeer(let p): try await MessageService.shared.send(text: text, toRandom: p, replyTo: reply)
            }
        } catch { }
    }

    /// Enter edit-mode for a previously-sent text bubble. Pre-fills
    /// the composer with the original text and clears any pending
    /// reply (composer can only do one job at a time). Caller is
    /// expected to have already filtered for `message.isFromMe &&
    /// message.kind == .text` — gating UX-side avoids a misleading
    /// edit affordance on bubbles that can't actually be edited.
    func startEdit(_ message: Message) {
        replyTarget = nil
        editingTarget = message
        input = message.text
    }

    func cancelEdit() {
        editingTarget = nil
        input = ""
    }

    /// Returns a user-facing error string on failure (matching the
    /// `sendVideo` shape) so ChatView can surface it in an alert.
    /// Returns nil on success. The most common failure surfaced here
    /// is `MediaService.Failure.tooLarge` from the 25 MB pre-flight,
    /// which the user can act on (pick a smaller image / lower-res
    /// capture).
    @discardableResult
    func sendPhoto(_ image: UIImage) async -> String? {
        let reply = consumeReplyContext()
        do {
            switch target {
            case .peer(let c):       try await MessageService.shared.sendPhoto(image, to: c, replyTo: reply)
            case .group(let g):      try await MessageService.shared.sendPhoto(image, to: g, replyTo: reply)
            case .randomPeer(let p): try await MessageService.shared.sendPhoto(image, toRandom: p, replyTo: reply)
            }
            return nil
        } catch let err as MediaService.Failure {
            return err.errorDescription
        } catch {
            return nil
        }
    }

    /// Premium photo send. Same return contract as `sendPhoto` (nil on
    /// success, friendly error string on failure). Random chat is
    /// excluded — premium content needs a wallet identity to charge,
    /// and the ephemeral random session doesn't have one.
    func sendPremiumPhoto(_ image: UIImage, price: Int) async -> String? {
        let reply = consumeReplyContext()
        do {
            try await MessageService.shared.sendPremiumPhoto(image, in: target, price: price, replyTo: reply)
            return nil
        } catch let err as MediaService.Failure {
            return err.errorDescription
        } catch {
            return nil
        }
    }

    /// Premium video send — wraps the standard VideoProcessor pipeline,
    /// then routes to `MessageService.sendPremiumVideo` instead of the
    /// regular video send.
    func sendPremiumVideo(from sourceURL: URL, price: Int) async -> String? {
        let reply = consumeReplyContext()
        do {
            let processed = try await VideoProcessor.process(sourceURL: sourceURL)
            try? FileManager.default.removeItem(at: sourceURL)
            try await MessageService.shared.sendPremiumVideo(processed: processed, in: target, price: price, replyTo: reply)
            return nil
        } catch let err as VideoProcessor.Failure {
            try? FileManager.default.removeItem(at: sourceURL)
            return err.errorDescription
        } catch {
            try? FileManager.default.removeItem(at: sourceURL)
            return nil
        }
    }

    /// Build a `ReplyContext` from the current `replyTarget` and
    /// clear it. Returns nil if no reply is in flight. Snippet caps
    /// at 80 chars; for media bubbles we synthesize a "📷 Photo" /
    /// "🎬 Video" preview from the kind + caption since the bubble
    /// itself doesn't store a text preview.
    private func consumeReplyContext() -> ReplyContext? {
        guard let target = replyTarget else { return nil }
        replyTarget = nil
        let snippet = Self.snippet(for: target)
        let author = senderNickname(target.senderUIN)
        return ReplyContext(id: target.id, snippet: snippet, authorName: author)
    }

    private static func snippet(for message: Message) -> String {
        if message.deletedForEveryone { return "Message deleted" }
        let raw: String
        switch message.kind {
        case .text:  raw = message.text
        case .photo: raw = message.text.isEmpty ? "📷 Photo" : "📷 \(message.text)"
        case .video: raw = message.text.isEmpty ? "🎬 Video" : "🎬 \(message.text)"
        case .voice: raw = "🎤 Voice"
        case .premiumPhoto: raw = "🔒 Premium photo"
        case .premiumVideo: raw = "🔒 Premium video"
        default:     raw = message.text.isEmpty ? "Message" : message.text
        }
        if raw.count <= 80 { return raw }
        return raw.prefix(80) + "…"
    }

    /// Send a recorded voice message. `fileURL` is consumed (deleted on
    /// success or failure). Returns nil on success or a user-facing
    /// error string for the alert.
    func sendVoice(fileURL: URL, durationSec: Double) async -> String? {
        let reply = consumeReplyContext()
        do {
            switch target {
            case .peer(let c):       try await MessageService.shared.sendVoice(fileURL: fileURL, durationSec: durationSec, to: c, replyTo: reply)
            case .group(let g):      try await MessageService.shared.sendVoice(fileURL: fileURL, durationSec: durationSec, to: g, replyTo: reply)
            case .randomPeer(let p): try await MessageService.shared.sendVoice(fileURL: fileURL, durationSec: durationSec, toRandom: p, replyTo: reply)
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Returns a user-friendly error string on failure (so ChatView can surface it
    /// via an alert), nil on success.
    func sendVideo(from sourceURL: URL) async -> String? {
        let reply = consumeReplyContext()
        do {
            let processed = try await VideoProcessor.process(sourceURL: sourceURL)
            try? FileManager.default.removeItem(at: sourceURL)
            switch target {
            case .peer(let c):       try await MessageService.shared.sendVideo(processed: processed, to: c, replyTo: reply)
            case .group(let g):      try await MessageService.shared.sendVideo(processed: processed, to: g, replyTo: reply)
            case .randomPeer(let p): try await MessageService.shared.sendVideo(processed: processed, toRandom: p, replyTo: reply)
            }
            return nil
        } catch let err as VideoProcessor.Failure {
            try? FileManager.default.removeItem(at: sourceURL)
            return err.errorDescription
        } catch {
            try? FileManager.default.removeItem(at: sourceURL)
            return error.localizedDescription
        }
    }

    /// Update disappearing-message TTL for this thread. Local-only — see
    /// `ChatSettingsStore` comment on the asymmetric model — and drops a
    /// system notice in the thread so the user has a visible audit trail of
    /// when they flipped it.
    func setTTL(_ ttl: Int?) {
        // Random chat is ephemeral by design; TTL toggle would be redundant.
        if case .randomPeer = target { return }
        let thread = target.thread
        ChatSettingsStore.shared.setTTL(ttl, for: thread)

        let label = ChatSettingsStore.label(for: ttl)
        let body: String = (ttl == nil)
            ? "chat.system.ttl_off".localized
            : String(format: "chat.system.ttl_set".localized, label)
        let notice = Message(
            thread: thread,
            senderUIN: AuthService.shared.ownUIN ?? 0,
            isFromMe: false,
            kind: .systemNotice,
            text: body,
            deliveryState: .delivered
        )
        MessageStore.shared.append(notice)
    }

    func deleteForMe(_ message: Message) {
        if case .randomPeer = target {
            // Random buffer is in-memory; "delete for me" just
            // pops the row out of the local list. Messages will
                                // vanish wholesale at session end too.
            RandomChatService.shared.deleteMessage(id: message.id)
            return
        }
        MessageStore.shared.deleteLocal(messageID: message.id, thread: target.thread)
    }

    func deleteForEveryone(_ message: Message) async {
        do {
            switch target {
            case .peer(let c):       try await MessageService.shared.deleteForEveryone(message: message, to: c)
            case .group(let g):      try await MessageService.shared.deleteForEveryone(message: message, in: g)
            case .randomPeer(let p): try await MessageService.shared.deleteForEveryone(message: message, toRandom: p)
            }
        } catch { }
    }

    /// Forward `message` from this thread into another chat. The
    /// destination is one of: a regular contact, a group, or our own
    /// Saved Messages thread (modeled as a synthetic Contact). The
    /// forwarded copy carries the original author's nickname inside
    /// the encrypted envelope so the recipient sees a "Forwarded
    /// from X" attribution — UIN is intentionally not propagated.
    func forward(_ message: Message, toContact contact: Contact) async {
        let originalAuthor = senderNickname(message.senderUIN)
        do {
            try await MessageService.shared.forward(
                message: message,
                authorName: originalAuthor,
                toContact: contact
            )
        } catch { }
    }

    func forward(_ message: Message, toGroup group: RCQGroup) async {
        let originalAuthor = senderNickname(message.senderUIN)
        do {
            try await MessageService.shared.forward(
                message: message,
                authorName: originalAuthor,
                toGroup: group
            )
        } catch { }
    }

    /// Throttled "typing" relay over WS — 1:1 only.
    ///
    /// Two timing knobs, both tuned for "feels stable":
    ///   - `typingThrottle` (3s) — we re-fire `active=true` at most
    ///     once per this interval. Stops a long burst of keystrokes
    ///     from spamming the WS and avoids the flicker the user saw
    ///     when every keypress raced its own debounce.
    ///   - `typingIdleTimeout` (4s) — after the last keystroke, we
    ///     wait this long before sending `active=false`. A short
    ///     pause (mid-sentence breath) keeps the indicator on; only
    ///     a real stop clears it. Receiver-side
    ///     `AppState.typingTimers` has a 5s safety net on top so the
    ///     indicator can't get stuck even if our `false` event drops.
    private static let typingThrottle: TimeInterval = 3.0
    private static let typingIdleTimeout: UInt64 = 4_000_000_000  // 4s

    func notifyTyping() {
        guard case .peer(let contact) = target else { return }
        // Saved Messages — sending typing events to ourselves is
        // pointless and the WS round-trip would loop back into our
        // own thread state. Skip for the self-thread.
        if contact.uin == AuthService.shared.ownUIN { return }

        let now = Date()
        if lastTypingActiveAt == nil || now.timeIntervalSince(lastTypingActiveAt!) >= Self.typingThrottle {
            WebSocketService.shared.sendTyping(to: contact.uin, active: true)
            lastTypingActiveAt = now
        }

        typingDebounce?.cancel()
        typingDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.typingIdleTimeout)
            // Bail if the task was cancelled (user kept typing).
            // `try? await Task.sleep` swallows the CancellationError
            // and lets the next line run, which is exactly what was
            // making the previous version send `active=false` even
            // when the user was still typing — fix is the explicit
            // cancellation check.
            if Task.isCancelled { return }
            guard let self else { return }
            WebSocketService.shared.sendTyping(to: contact.uin, active: false)
            self.lastTypingActiveAt = nil
        }
    }

    /// Group messages by calendar day for date dividers.
    func grouped() -> [(label: String, items: [Message])] {
        let groups = Dictionary(grouping: messages, by: { DayKey.from($0.sentAt) })
        let sorted = groups.sorted { lhs, rhs in
            let l = lhs.value.first?.sentAt ?? .distantPast
            let r = rhs.value.first?.sentAt ?? .distantPast
            return l < r
        }
        return sorted.map { _, items in
            let label = items.first.map { DateFormatters.dayDivider.string(from: $0.sentAt) } ?? ""
            return (label, items.sorted { $0.sentAt < $1.sentAt })
        }
    }

    func senderNickname(_ uin: Int) -> String {
        // Anonymous random sessions: never surface the real
        // account nickname, not even for the local user. If we
        // returned `AuthService.shared.nickname` here, replying
        // to one of our own bubbles would embed our real handle
        // in the quote that ships to the stranger — defeating
        // the whole "they don't know who I am" property of
        // random chat. "You" / "Stranger" stays anonymous on
        // both ends of the wire.
        if case .randomPeer = target {
            if uin == AuthService.shared.ownUIN { return "chat.random.you".localized }
            return "chat.random.stranger".localized
        }
        if uin == AuthService.shared.ownUIN { return AuthService.shared.nickname }
        if case .group(let g) = target, let m = g.members.first(where: { $0.uin == uin }) { return m.nickname }
        if let c = ContactService.shared.contacts.first(where: { $0.uin == uin }) { return c.nickname }
        return String(uin)
    }

    /// Strips URLs and obvious phone-number strings from outbound
    /// stranger-mode text. Replacements substitute the offending
    /// substring with a `[hidden]` placeholder so the receiver can
    /// see the message was modified rather than silently mangled.
    ///
    /// This is a client-side enforcement — sealed-sender means the
    /// server can't see the plaintext. A determined sender can
    /// trivially obfuscate ("dot com" / spaced digits / etc), so
    /// this isn't an absolute filter, just enough friction to make
    /// "drop your handle, message me there" infeasible without
    /// effort. Pairs with the age gate + the no-media composer
    /// strip + the Block + Report shortcut to give Apple's UGC
    /// reviewer a reasonable defence-in-depth story.
    static func scrubbedForStrangerMode(_ text: String) -> String {
        let placeholder = "[hidden]"
        var out = text

        // 1. URLs — let NSDataDetector do the heavy lifting (handles
        // http(s)://, bare domains, schemes like t.me/, etc).
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let nsText = out as NSString
            let fullRange = NSRange(location: 0, length: nsText.length)
            let matches = detector.matches(in: out, options: [], range: fullRange).reversed()
            for m in matches {
                if m.range.location + m.range.length <= (out as NSString).length {
                    out = (out as NSString).replacingCharacters(in: m.range, with: placeholder)
                }
            }
        }

        // 2. Phone numbers — same NSDataDetector trick. Catches the
        // common "+7 (123) 456-78-90" / "+1-234-567-8900" / bare
        // 11-digit international shapes. Determined obfuscators can
        // still spell digits out; we accept that.
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue) {
            let matches = detector.matches(in: out, options: [], range: NSRange(location: 0, length: (out as NSString).length)).reversed()
            for m in matches {
                if m.range.location + m.range.length <= (out as NSString).length {
                    out = (out as NSString).replacingCharacters(in: m.range, with: placeholder)
                }
            }
        }

        // 3. Telegram / Instagram / etc handles — `@username` shape.
        // 5+ chars after the @ to avoid stripping common in-text "@4"
        // mentions (we don't have @-mentions in 1:1 chat anyway, so
        // catching the obvious off-platform handle pattern is safe).
        let handleRegex = try? NSRegularExpression(
            pattern: "@[A-Za-z0-9_]{5,}",
            options: []
        )
        if let regex = handleRegex {
            out = regex.stringByReplacingMatches(
                in: out,
                options: [],
                range: NSRange(location: 0, length: (out as NSString).length),
                withTemplate: placeholder
            )
        }

        return out
    }
}

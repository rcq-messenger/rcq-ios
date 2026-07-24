import Combine
import Foundation
import SwiftUI
import UIKit

@MainActor
final class ChatViewModel: ObservableObject {
    let target: ChatTarget

    @Published var messages: [Message] = []
    /// Day-bucketed, album-collapsed render list, derived from `messages`
    /// via a Combine sink in `init`. Recomputed ONLY when messages change,
    /// never on a composer keystroke — ChatView reads this stored array
    /// instead of calling `grouped()`/`collapsedAlbums()` in its body, so
    /// typing no longer re-runs the O(n log n) grouping over the whole
    /// history every time `input` mutates (the edit-composer lag root).
    @Published private(set) var groupedUnits: [(label: String, units: [RenderUnit])] = []
    @Published var input: String = ""
    @Published var isPeerTyping: Bool = false
    @Published var fadingOutIDs: Set<UUID> = []
    /// True while older messages exist in CoreData beyond the
    /// currently-loaded window. ChatView shows a "load earlier" hint
    /// at the top of the list and triggers `loadOlder()` when the
    /// user scrolls near it.
    @Published var hasOlder: Bool = false
    /// Set while a load-older fetch is in-flight to prevent the
    /// scroll-trigger from firing multiple times on the same page.
    @Published var isLoadingOlder: Bool = false
    @Published var replyTarget: Message?
    @Published var editingTarget: Message?
    @Published var translatedTexts: [UUID: String] = [:]
    @Published var pendingTranslationMessage: Message?
    /// Picked-but-not-yet-sent media. Lives in the composer as preview
    /// thumbnails so the user can attach a caption before tapping Send,
    /// instead of the picker firing each item off as a standalone
    /// message the moment it returns.
    @Published var pendingMedia: [PendingMediaItem] = []
    /// Pending photo/video ids the user marked as spoilers (tap on the
    /// pending tile toggles). Consumed + cleared by the send drain.
    @Published var spoilerMedia: Set<UUID> = []
    /// Multi-select state for batch delete / forward. Entered via the
    /// "Select" action on the message context menu and exited via the
    /// Cancel button on the selection action bar.
    @Published var isSelecting: Bool = false
    @Published var selectedIDs: Set<UUID> = []
    enum PendingMediaItem: Identifiable {
        case photo(id: UUID, image: UIImage)
        case video(id: UUID, url: URL, thumbnail: UIImage?)
        /// Animated GIF carried through the composer as raw bytes so
        /// the send path can upload without JPEG recompression.
        /// `preview` is the first frame for the pending-tile thumbnail.
        case gif(id: UUID, data: Data, preview: UIImage)

        var id: UUID {
            switch self {
            case .photo(let id, _): return id
            case .video(let id, _, _): return id
            case .gif(let id, _, _): return id
            }
        }
    }

    private var cancellables = Set<AnyCancellable>()
    private var typingDebounce: Task<Void, Never>?
    private var lastTypingActiveAt: Date?

    init(target: ChatTarget) {
        self.target = target

        if case .randomPeer = target {
        } else if let draft = UserDefaults.standard.string(forKey: Self.draftKey(for: target)),
                  !draft.isEmpty {
            self.input = draft
        }
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
            self.messages = RandomChatService.shared.messages
            RandomChatService.shared.$messages
                .assign(to: &$messages)
        default:
            let thread = target.thread
            self.messages = MessageStore.shared.threads[thread] ?? []
            MessageStore.shared.$threads
                .map { $0[thread] ?? [] }
                // MessageStore publishes the WHOLE thread dictionary on any
                // thread's mutation. Without this, an UNRELATED thread's
                // reaction/read-receipt re-emits this thread's (unchanged)
                // array, re-firing the O(n) computeGroupedUnits sink + a full
                // list diff. Message is Equatable, so only re-emit when THIS
                // thread's messages actually changed.
                .removeDuplicates()
                .assign(to: &$messages)
            self.fadingOutIDs = MessageStore.shared.fadingOutIDs
            MessageStore.shared.$fadingOutIDs
                .assign(to: &$fadingOutIDs)
            self.hasOlder = MessageStore.shared.hasOlderInDB[thread] ?? false
            MessageStore.shared.$hasOlderInDB
                .map { $0[thread] ?? false }
                .assign(to: &$hasOlder)
        }

        if case .peer(let contact) = target {
            AppState.shared.$typingByUIN
                .receive(on: DispatchQueue.main)
                .map { $0[contact.uin] ?? false }
                .assign(to: &$isPeerTyping)
        }

        // Recompute the day-grouped / album-collapsed render list only
        // when `messages` actually changes (new/edited/removed message),
        // NOT on every keystroke. Fires once on subscribe with the
        // current value, so the initial render is populated.
        $messages
            .sink { [weak self] msgs in
                self?.groupedUnits = ChatViewModel.computeGroupedUnits(msgs)
            }
            .store(in: &cancellables)

        captureUnreadIfNeeded()
    }

    private static func draftKey(for target: ChatTarget) -> String {
        switch target {
        case .peer(let c):       return "rcq.draft.peer.\(c.uin)"
        case .group(let g):      return "rcq.draft.group.\(g.id)"
        case .randomPeer(let p): return "rcq.draft.random.\(p.uin)"
        }
    }

    private var didCaptureUnread = false
    /// Unread count snapshotted at init, BEFORE markThreadSeen() clears it —
    /// so we can open scrolled to the first unread message (every-messenger
    /// behaviour), not the bottom.
    private(set) var openUnreadCount = 0

    /// Live "unread still below the viewport" counter behind the jump-down
    /// arrow badge (#15). Seeded with [openUnreadCount] at init — before any
    /// LazyVStack row can realize — and only ever shrinks (sawRow). It used
    /// to be @State in ChatView seeded from the root onAppear, which raced
    /// the rows' own onAppear: rows that realized first saw 0, skipped the
    /// decrement, and the badge then showed the original count forever
    /// (beta report). A nav push/pop also re-ran the seeding and resurrected
    /// the stale number.
    @Published private(set) var unreadBelow = 0

    /// A row materialized — at most messagesBelow(id) messages can still be
    /// unread below it. Monotonic shrink; LazyVStack realization runs a bit
    /// ahead of actual visibility, which only errs toward "read sooner".
    func sawRow(_ id: UUID) {
        guard unreadBelow > 0 else { return }
        unreadBelow = min(unreadBelow, messagesBelow(id))
    }

    /// Jump-to-bottom consumed everything below — badge off, regardless of
    /// which rows got a chance to fire onAppear on the way down.
    func clearUnreadBelow() {
        if unreadBelow != 0 { unreadBelow = 0 }
    }

    /// The first unread message to open at, or nil → open at the bottom.
    /// Clamps when there are MORE unread than currently-loaded messages (a
    /// group with a big backlog, only the latest page loaded) — without the
    /// clamp it returned nil and the chat opened at the bottom past all the
    /// unread (founder report). Anchor to the oldest loaded message instead.
    var openFirstUnreadID: UUID? {
        guard openUnreadCount > 0, !messages.isEmpty else { return nil }
        let idx = max(0, messages.count - openUnreadCount)
        return messages[idx].id
    }

    /// How many messages sit AFTER [id] in the loaded list (i.e. below it in
    /// the timeline). Used to shrink the scroll-down unread badge as you read.
    func messagesBelow(_ id: UUID) -> Int {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return 0 }
        return messages.count - 1 - i
    }

    func onAppear() {
        captureUnreadIfNeeded()
        markThreadSeen()
    }

    /// Snapshot the unread count. Runs at init — onAppear is too late: the
    /// LazyVStack rows can realize (and call sawRow) before the root
    /// onAppear fires, and markThreadSeen() clears the source counters.
    private func captureUnreadIfNeeded() {
        guard !didCaptureUnread else { return }
        didCaptureUnread = true
        switch target {
        case .peer(let c):
            openUnreadCount = ContactService.shared.contacts.first(where: { $0.uin == c.uin })?.unread ?? 0
        case .group(let g):
            openUnreadCount = GroupService.shared.unread[g.id] ?? 0
        case .randomPeer:
            openUnreadCount = 0
        }
        unreadBelow = openUnreadCount
    }

    /// Pull the next page of older messages from CoreData and prepend
    /// them to the loaded window. Called when ChatView's scroll
    /// approaches the top of the list. Returns the count loaded; 0
    /// means we hit the start of history (ChatView hides the hint).
    @discardableResult
    func loadOlder() async -> Int {
        // .randomPeer does not persist to CoreData; pagination is a
        // no-op there. Pre-condition also stops re-entrancy from
        // overlapping scroll callbacks.
        if case .randomPeer = target { return 0 }
        if isLoadingOlder { return 0 }
        if !hasOlder { return 0 }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        return MessageStore.shared.loadOlder(for: target.thread)
    }

    func ackIfVisible(_ message: Message) {
        guard !message.isFromMe, message.deliveryState != .read else { return }
        markThreadSeen()
    }

    /// Clear every unseen indicator for the active thread. Idempotent.
    private func markThreadSeen() {
        switch target {
        case .peer(let contact):
            ContactService.shared.clearUnread(for: contact.uin)
            ReactionInboxStore.shared.clear(.peer(uin: contact.uin))
            MentionInboxStore.shared.clear(.peer(uin: contact.uin))
        case .group(let group):
            GroupService.shared.clearUnread(group.id)
            ReactionInboxStore.shared.clear(.group(id: group.id))
            MentionInboxStore.shared.clear(.group(id: group.id))
        case .randomPeer:
            return
        }
        Task { await MessageService.shared.markRead(messages: messages, in: target) }
    }

    func toggleReaction(_ asset: String, on message: Message) {
        Task { await MessageService.shared.toggleReaction(on: message, asset: asset, in: target) }
    }

    func toggleTranslate(_ message: Message) {
        if translatedTexts[message.id] != nil {
            translatedTexts.removeValue(forKey: message.id)
            return
        }
        let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingTranslationMessage = message
    }

    func displayText(for message: Message) -> String {
        translatedTexts[message.id] ?? message.text
    }

    func isTranslated(_ message: Message) -> Bool {
        translatedTexts[message.id] != nil
    }

    /// Drop a specific text payload into the chat without going
    /// through the composer's `input` buffer — used by the
    /// share-group picker which already has the canonical URL in
    /// hand. Reply context is intentionally not consumed (a
    /// share-as-reply is a contrived flow; the composer's reply
    /// strip stays for the next manual message).
    func sendText(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            switch target {
            case .peer(let c):       try await MessageService.shared.send(text: trimmed, to: c)
            case .group(let g):      try await MessageService.shared.send(text: trimmed, to: g)
            case .randomPeer(let p): try await MessageService.shared.send(text: trimmed, toRandom: p)
            }
        } catch { }
    }

    /// In-chat bridge sharing: hand the 1:1 peer a relay from your pool.
    func shareRelay(_ relay: RelayConfigStore.RelayEntry) async {
        switch target {
        case .peer(let c):
            try? await MessageService.shared.shareRelay(relay, to: c)
        case .group(let g):
            try? await MessageService.shared.shareRelay(relay, toGroup: g)
        case .randomPeer:
            break
        }
    }

    func send() async {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if case .randomPeer = target {
            text = ChatViewModel.scrubbedForStrangerMode(text)
        }
        guard !text.isEmpty else { return }
        if let editing = editingTarget {
            // Optimistic: dismiss the edit composer + clear input NOW, send in
            // the background. MessageService.edit applies the local edit to the
            // store synchronously before its own await, so the bubble updates
            // immediately too — only the network round-trip is deferred (the
            // composer used to linger until the server ACKed).
            let newText = text
            let editTarget = target
            withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                editingTarget = nil
            }
            input = ""
            if newText != editing.text {
                EmoticonUsageStore.shared.bump(forText: newText)
                Task {
                    do {
                        switch editTarget {
                        case .peer(let c):       try await MessageService.shared.edit(message: editing, newText: newText, to: c)
                        case .group(let g):      try await MessageService.shared.edit(message: editing, newText: newText, in: g)
                        case .randomPeer(let p): try await MessageService.shared.edit(message: editing, newText: newText, toRandom: p)
                        }
                    } catch { }
                }
            }
            return
        }
        input = ""
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

    func startEdit(_ message: Message) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
            replyTarget = nil
            editingTarget = message
        }
        input = message.text
    }

    func cancelEdit() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
            editingTarget = nil
        }
        input = ""
    }

    /// Hard cap so the composer doesn't grow unboundedly (and to mirror
    /// the picker's selectionLimit). Items past the cap are dropped on
    /// the floor — UI prevents picking past it, this is a safety net.
    static let maxPendingMedia = 5

    func queuePendingPhotos(_ images: [UIImage]) {
        for img in images {
            guard pendingMedia.count < Self.maxPendingMedia else { break }
            pendingMedia.append(.photo(id: UUID(), image: img))
        }
    }

    func queuePendingVideo(url: URL, thumbnail: UIImage?) {
        guard pendingMedia.count < Self.maxPendingMedia else { return }
        pendingMedia.append(.video(id: UUID(), url: url, thumbnail: thumbnail))
    }

    func queuePendingGIF(data: Data, preview: UIImage) {
        guard pendingMedia.count < Self.maxPendingMedia else { return }
        pendingMedia.append(.gif(id: UUID(), data: data, preview: preview))
    }

    var pendingMediaSlotsLeft: Int {
        max(0, Self.maxPendingMedia - pendingMedia.count)
    }

    func removePendingMedia(_ id: UUID) {
        if case .video(_, let url, _) = pendingMedia.first(where: { $0.id == id }) {
            try? FileManager.default.removeItem(at: url)
        }
        pendingMedia.removeAll { $0.id == id }
        spoilerMedia.remove(id)
    }

    func clearPendingMedia() {
        for item in pendingMedia {
            if case .video(_, let url, _) = item {
                try? FileManager.default.removeItem(at: url)
            }
        }
        pendingMedia = []
        spoilerMedia = []
    }

    /// Tap-to-blur on a pending tile (photo/video only — the GIF path
    /// has no spoiler lane on the wire).
    func toggleSpoilerMedia(_ id: UUID) {
        guard let item = pendingMedia.first(where: { $0.id == id }) else { return }
        if case .gif = item { return }
        if spoilerMedia.contains(id) { spoilerMedia.remove(id) } else { spoilerMedia.insert(id) }
    }

    /// Drains `pendingMedia`, attaching the composer text to the LAST
    /// item as a caption (Telegram-style album behaviour). Returns
    /// the first error encountered, or nil. The composer text and
    /// pending list are cleared once dispatch starts so the user sees
    /// the queue empty out immediately.
    @discardableResult
    func sendPendingMediaWithCaption() async -> String? {
        guard !pendingMedia.isEmpty else { return nil }
        let caption = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let queue = pendingMedia
        pendingMedia = []
        input = ""
        // One album-id for the whole batch — only assigned when there
        // are 2+ items, so a single-pick send keeps the standalone
        // bubble layout. Receivers group by this id at render time.
        let album: UUID? = queue.count > 1 ? UUID() : nil
        var firstError: String?
        for (idx, item) in queue.enumerated() {
            // Caption rides inline on the LAST media — sending it as
            // a separate `.text` message would let it race ahead of
            // the slow video upload and arrive out of album-order.
            // The renderer pulls the caption out and paints it as a
            // proper-looking text bubble below the album, so visually
            // it still reads like a separate chat message.
            let isLast = (idx == queue.count - 1)
            let cap: String? = (isLast && !caption.isEmpty) ? caption : nil
            let spoiler = spoilerMedia.contains(item.id)
            let err: String?
            switch item {
            case .photo(_, let img):
                err = await sendPhoto(img, caption: cap, albumID: album, spoiler: spoiler)
            case .video(_, let url, let thumb):
                err = await sendVideo(from: url, previewThumbnail: thumb, caption: cap, albumID: album, spoiler: spoiler)
            case .gif(_, let data, let preview):
                err = await sendGIF(data: data, preview: preview, caption: cap, albumID: album)
            }
            if let e = err, firstError == nil { firstError = e }
        }
        spoilerMedia = []
        return firstError
    }

    @discardableResult
    func sendGIF(data: Data, preview: UIImage, caption: String? = nil, albumID: UUID? = nil) async -> String? {
        let reply = consumeReplyContext()
        do {
            switch target {
            case .peer(let c):       try await MessageService.shared.sendGIF(data: data, preview: preview, to: c, caption: caption, replyTo: reply, albumID: albumID)
            case .group(let g):      try await MessageService.shared.sendGIF(data: data, preview: preview, to: g, caption: caption, replyTo: reply, albumID: albumID)
            case .randomPeer(let p): try await MessageService.shared.sendGIF(data: data, preview: preview, toRandom: p, caption: caption, replyTo: reply, albumID: albumID)
            }
            return nil
        } catch let err as MediaService.Failure {
            return err.errorDescription
        } catch {
            return nil
        }
    }

    @discardableResult
    func sendPhoto(_ image: UIImage, caption: String? = nil, albumID: UUID? = nil, spoiler: Bool = false) async -> String? {
        let reply = consumeReplyContext()
        do {
            switch target {
            case .peer(let c):       try await MessageService.shared.sendPhoto(image, to: c, caption: caption, replyTo: reply, albumID: albumID, spoiler: spoiler)
            case .group(let g):      try await MessageService.shared.sendPhoto(image, to: g, caption: caption, replyTo: reply, albumID: albumID, spoiler: spoiler)
            case .randomPeer(let p): try await MessageService.shared.sendPhoto(image, toRandom: p, caption: caption, replyTo: reply, albumID: albumID, spoiler: spoiler)
            }
            return nil
        } catch let err as MediaService.Failure {
            return err.errorDescription
        } catch {
            return nil
        }
    }

    private func consumeReplyContext() -> ReplyContext? {
        guard let target = replyTarget else { return nil }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
            replyTarget = nil
        }
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
        case .file:  raw = "📎 \(message.fileName ?? "File")"
        case .location: raw = "📍 Location"
        case .poll:
            // `.poll` stores the full PollPayload as JSON in `text`
            // — the reply strip rendered the raw braces / option
            // labels until we pulled out the question here.
            let q = PollPayload.decode(from: message.text)?.question ?? "Poll"
            raw = "📊 \(q)"
        default:     raw = message.text.isEmpty ? "Message" : message.text
        }
        if raw.count <= 80 { return raw }
        return raw.prefix(80) + "…"
    }

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

    /// Static pinned location — coordinates picked via map sheet, sent
    /// inside the envelope (no encrypted blob path). Random-chat is
    /// gated upstream by the attach menu hiding the row entirely.
    func sendLocation(latitude: Double, longitude: Double) async -> String? {
        let reply = consumeReplyContext()
        do {
            switch target {
            case .peer(let c):
                try await MessageService.shared.sendLocation(
                    latitude: latitude, longitude: longitude,
                    to: c, replyTo: reply,
                )
            case .group(let g):
                try await MessageService.shared.sendLocation(
                    latitude: latitude, longitude: longitude,
                    to: g, replyTo: reply,
                )
            case .randomPeer:
                break
            }
            return nil
        } catch {
            return APIErrorPresenter.friendly(error)
        }
    }

    /// Arbitrary file (PDF / DOCX / ZIP / …). Random-chat is gated upstream
    /// in the attach menu so this method only has to route 1:1 and groups.
    ///
    /// Files above 25 MB require the "Pay for files" toggle (Settings) —
    /// without it we block here so the server's 402 doesn't surface as
    /// a generic upload failure.
    func sendFile(fileURL: URL, fileName: String, mime: String, sizeBytes: Int) async -> String? {
        let reply = consumeReplyContext()
        do {
            switch target {
            case .peer(let c):
                try await MessageService.shared.sendFile(
                    fileURL: fileURL, fileName: fileName, mime: mime, sizeBytes: sizeBytes,
                    to: c, replyTo: reply
                )
            case .group(let g):
                try await MessageService.shared.sendFile(
                    fileURL: fileURL, fileName: fileName, mime: mime, sizeBytes: sizeBytes,
                    to: g, replyTo: reply
                )
            case .randomPeer:
                break
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func sendVideo(
        from sourceURL: URL,
        previewThumbnail: UIImage? = nil,
        caption: String? = nil,
        albumID: UUID? = nil,
        spoiler: Bool = false,
    ) async -> String? {
        let reply = consumeReplyContext()
        // Picker-strip thumbnail (small JPEG) ships down so the bubble
        // pops in instantly with a real preview while VideoProcessor
        // (compression, full-thumbnail extraction) catches up in the
        // background. Empty-string sentinel = "no preview yet, render
        // the placeholder tile for now".
        let previewB64: String = previewThumbnail
            .flatMap { ImageCompressor.compress($0, maxSide: 200, quality: 0.7) }
            .map { $0.base64EncodedString() } ?? ""
        do {
            switch target {
            case .peer(let c):
                try await MessageService.shared.sendVideo(
                    from: sourceURL, previewThumbnailB64: previewB64,
                    to: c, caption: caption, replyTo: reply, albumID: albumID, spoiler: spoiler,
                )
            case .group(let g):
                try await MessageService.shared.sendVideo(
                    from: sourceURL, previewThumbnailB64: previewB64,
                    to: g, caption: caption, replyTo: reply, albumID: albumID, spoiler: spoiler,
                )
            case .randomPeer(let p):
                // Random-chat keeps the legacy pre-process flow — single
                // ephemeral peer, lower bar for "feels instant", and the
                // thread is throwaway anyway.
                let processed = try await VideoProcessor.process(sourceURL: sourceURL)
                try? FileManager.default.removeItem(at: sourceURL)
                try await MessageService.shared.sendVideo(processed: processed, toRandom: p, caption: caption, replyTo: reply, albumID: albumID, spoiler: spoiler)
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

    func setTTL(_ ttl: Int?) {
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

    func resend(_ message: Message) async {
        await MessageService.shared.resend(message, in: target)
    }

    func deleteForMe(_ message: Message) {
        if case .randomPeer = target {
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

    // MARK: - Multi-select

    func enterSelection(seeding messageID: UUID) {
        isSelecting = true
        selectedIDs = [messageID]
    }

    func toggleSelection(_ messageID: UUID) {
        if selectedIDs.contains(messageID) {
            selectedIDs.remove(messageID)
        } else {
            selectedIDs.insert(messageID)
        }
        if selectedIDs.isEmpty {
            isSelecting = false
        }
    }

    func cancelSelection() {
        isSelecting = false
        selectedIDs = []
    }

    private var selectedMessages: [Message] {
        let set = selectedIDs
        return messages.filter { set.contains($0.id) }
    }

    /// True when every selected message was sent by the current user
    /// AND can be retracted (none too old, none already deleted).
    /// Drives the visibility of the "Delete for everyone" option in
    /// the selection action bar.
    var selectionAllRetractable: Bool {
        let me = AuthService.shared.ownUIN
        guard let me else { return false }
        return !selectedMessages.isEmpty
            && selectedMessages.allSatisfy { $0.senderUIN == me && !$0.deletedForEveryone }
    }

    /// True if any selected message can't be forwarded (deleted,
    /// voice, premium, etc). Hides the Forward button rather than
    /// silently skipping unforwardable items.
    var selectedMessagesContainNonForwardable: Bool {
        selectedMessages.contains { msg in
            if msg.deletedForEveryone { return true }
            switch msg.kind {
            case .text, .photo, .video: return false
            default: return true
            }
        }
    }

    /// Anchor for the multi-forward picker sheet. Picks the earliest-
    /// sent selected message so the sheet's preview is stable when
    /// the user adds/removes items.
    var firstSelectedMessage: Message? {
        selectedMessages.min(by: { $0.sentAt < $1.sentAt })
    }

    func deleteSelectedForMe() {
        for m in selectedMessages {
            deleteForMe(m)
        }
        cancelSelection()
    }

    func deleteSelectedForEveryone() async {
        let snapshot = selectedMessages
        cancelSelection()
        for m in snapshot {
            await deleteForEveryone(m)
        }
    }

    func forwardSelected(toContact contact: Contact) async {
        let snapshot = selectedMessages.sorted { $0.sentAt < $1.sentAt }
        cancelSelection()
        for m in snapshot {
            await forward(m, toContact: contact)
        }
    }

    func forwardSelected(toGroup group: RCQGroup) async {
        let snapshot = selectedMessages.sorted { $0.sentAt < $1.sentAt }
        cancelSelection()
        for m in snapshot {
            await forward(m, toGroup: group)
        }
    }

    private static let typingThrottle: TimeInterval = 3.0
    private static let typingIdleTimeout: UInt64 = 4_000_000_000

    func notifyTyping() {
        guard case .peer(let contact) = target else { return }
        if contact.uin == AuthService.shared.ownUIN { return }

        let now = Date()
        if lastTypingActiveAt == nil || now.timeIntervalSince(lastTypingActiveAt!) >= Self.typingThrottle {
            WebSocketService.shared.sendTyping(to: contact.uin, active: true)
            lastTypingActiveAt = now
        }

        typingDebounce?.cancel()
        typingDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.typingIdleTimeout)
            // task.sleep with try? swallows CancellationError, so check explicitly
            if Task.isCancelled { return }
            guard let self else { return }
            WebSocketService.shared.sendTyping(to: contact.uin, active: false)
            self.lastTypingActiveAt = nil
        }
    }

    /// Combines day-grouping and album-collapsing in a single pass.
    /// Pure over `messages`, so it's safe to drive off the Combine sink
    /// that watches `$messages` (see init) and cache the result in
    /// `groupedUnits`.
    static func computeGroupedUnits(_ messages: [Message]) -> [(label: String, units: [RenderUnit])] {
        dayGroups(messages).map { (label: $0.label, units: collapseAlbums($0.items)) }
    }

    static func dayGroups(_ messages: [Message]) -> [(label: String, items: [Message])] {
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

    /// Render unit — either a stand-alone message or a contiguous run
    /// of media that shared an albumID at send time.
    enum RenderUnit: Identifiable {
        case single(Message)
        case album(id: UUID, items: [Message])

        var id: UUID {
            switch self {
            case .single(let m): return m.id
            case .album(let id, _): return id
            }
        }
    }

    /// Collapses consecutive messages with the same `albumID` (and same
    /// sender) into one render unit. Anything without an albumID, or a
    /// run of length 1, stays as `.single`.
    static func collapseAlbums(_ items: [Message]) -> [RenderUnit] {
        var out: [RenderUnit] = []
        var i = 0
        while i < items.count {
            let m = items[i]
            guard let album = m.albumID else {
                out.append(.single(m))
                i += 1
                continue
            }
            // Lookahead while same album + same sender (avoid merging
            // through a different sender's interjection).
            var j = i + 1
            while j < items.count,
                  items[j].albumID == album,
                  items[j].senderUIN == m.senderUIN {
                j += 1
            }
            let run = Array(items[i..<j])
            if run.count > 1 {
                out.append(.album(id: album, items: run))
            } else {
                out.append(.single(m))
            }
            i = j
        }
        return out
    }

    /// True when `message` quotes one of MY OWN messages, so the quote shows
    /// "You" to me. The wire carries the real nick, so everyone else still sees
    /// the nick — fixes "others see You" on a reply to your own message.
    func replyIsMine(_ message: Message) -> Bool {
        guard let rid = message.replyToID else { return false }
        return messages.first(where: { $0.id == rid })?.isFromMe ?? false
    }

    func senderNickname(_ uin: Int) -> String {
        // random sessions never expose real nickname on either side
        if case .randomPeer = target {
            if uin == AuthService.shared.ownUIN { return "chat.random.you".localized }
            return "chat.random.stranger".localized
        }
        if uin == AuthService.shared.ownUIN { return AuthService.shared.nickname }
        if case .group(let g) = target, let m = g.members.first(where: { $0.uin == uin }) { return m.nickname }
        if let c = ContactService.shared.contacts.first(where: { $0.uin == uin }) { return c.nickname }
        return String(uin)
    }

    /// Strip URLs, phone numbers, and @handles from stranger-mode text.
    /// Client-side only; a motivated sender can still obfuscate.
    static func scrubbedForStrangerMode(_ text: String) -> String {
        let placeholder = "[hidden]"
        var out = text

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

        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue) {
            let matches = detector.matches(in: out, options: [], range: NSRange(location: 0, length: (out as NSString).length)).reversed()
            for m in matches {
                if m.range.location + m.range.length <= (out as NSString).length {
                    out = (out as NSString).replacingCharacters(in: m.range, with: placeholder)
                }
            }
        }

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

import Combine
import Foundation
import SwiftUI
import UIKit

@MainActor
final class ChatViewModel: ObservableObject {
    let target: ChatTarget

    @Published var messages: [Message] = []
    @Published var input: String = ""
    @Published var isPeerTyping: Bool = false
    @Published var fadingOutIDs: Set<UUID> = []
    @Published var replyTarget: Message?
    @Published var editingTarget: Message?
    @Published var translatedTexts: [UUID: String] = [:]
    @Published var pendingTranslationMessage: Message?
    /// Picked-but-not-yet-sent media. Lives in the composer as preview
    /// thumbnails so the user can attach a caption before tapping Send,
    /// instead of the picker firing each item off as a standalone
    /// message the moment it returns.
    @Published var pendingMedia: [PendingMediaItem] = []
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
                .assign(to: &$messages)
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

    private static func draftKey(for target: ChatTarget) -> String {
        switch target {
        case .peer(let c):       return "rcq.draft.peer.\(c.uin)"
        case .group(let g):      return "rcq.draft.group.\(g.id)"
        case .randomPeer(let p): return "rcq.draft.random.\(p.uin)"
        }
    }

    func onAppear() {
        switch target {
        case .peer(let contact): ContactService.shared.clearUnread(for: contact.uin)
        case .group(let group):  GroupService.shared.clearUnread(group.id)
        case .randomPeer: break
        }
        if case .randomPeer = target { return }
        Task { await MessageService.shared.markRead(messages: messages, in: target) }
    }

    func ackIfVisible(_ message: Message) {
        guard !message.isFromMe, message.deliveryState != .read else { return }
        Task { await MessageService.shared.markRead(messages: [message], in: target) }
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

    func send() async {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if case .randomPeer = target {
            text = ChatViewModel.scrubbedForStrangerMode(text)
        }
        guard !text.isEmpty else { return }
        if let editing = editingTarget {
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
            withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                editingTarget = nil
            }
            input = ""
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
    }

    func clearPendingMedia() {
        for item in pendingMedia {
            if case .video(_, let url, _) = item {
                try? FileManager.default.removeItem(at: url)
            }
        }
        pendingMedia = []
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
            let err: String?
            switch item {
            case .photo(_, let img):
                err = await sendPhoto(img, caption: cap, albumID: album)
            case .video(_, let url, let thumb):
                err = await sendVideo(from: url, previewThumbnail: thumb, caption: cap, albumID: album)
            case .gif(_, let data, let preview):
                err = await sendGIF(data: data, preview: preview, caption: cap, albumID: album)
            }
            if let e = err, firstError == nil { firstError = e }
        }
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
    func sendPhoto(_ image: UIImage, caption: String? = nil, albumID: UUID? = nil) async -> String? {
        let reply = consumeReplyContext()
        do {
            switch target {
            case .peer(let c):       try await MessageService.shared.sendPhoto(image, to: c, caption: caption, replyTo: reply, albumID: albumID)
            case .group(let g):      try await MessageService.shared.sendPhoto(image, to: g, caption: caption, replyTo: reply, albumID: albumID)
            case .randomPeer(let p): try await MessageService.shared.sendPhoto(image, toRandom: p, caption: caption, replyTo: reply, albumID: albumID)
            }
            return nil
        } catch let err as MediaService.Failure {
            return err.errorDescription
        } catch {
            return nil
        }
    }

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
        case .premiumPhoto: raw = "🔒 Premium photo"
        case .premiumVideo: raw = "🔒 Premium video"
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
        let payEnabled = UserDefaults.standard.bool(forKey: "rcq.network.pay_for_large_files")
        let payJetons = MediaService.jetonCost(forBytes: sizeBytes)
        if payJetons > 0 && !payEnabled {
            return "chat.file.pay_required".localized
        }
        let reply = consumeReplyContext()
        do {
            switch target {
            case .peer(let c):
                try await MessageService.shared.sendFile(
                    fileURL: fileURL, fileName: fileName, mime: mime, sizeBytes: sizeBytes,
                    payJetons: payJetons,
                    to: c, replyTo: reply
                )
            case .group(let g):
                try await MessageService.shared.sendFile(
                    fileURL: fileURL, fileName: fileName, mime: mime, sizeBytes: sizeBytes,
                    payJetons: payJetons,
                    to: g, replyTo: reply
                )
            case .randomPeer:
                // Document attaches are hidden from random-chat — defensive
                // no-op in case the call site ever leaks past that gate.
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
                    to: c, caption: caption, replyTo: reply, albumID: albumID,
                )
            case .group(let g):
                try await MessageService.shared.sendVideo(
                    from: sourceURL, previewThumbnailB64: previewB64,
                    to: g, caption: caption, replyTo: reply, albumID: albumID,
                )
            case .randomPeer(let p):
                // Random-chat keeps the legacy pre-process flow — single
                // ephemeral peer, lower bar for "feels instant", and the
                // thread is throwaway anyway.
                let processed = try await VideoProcessor.process(sourceURL: sourceURL)
                try? FileManager.default.removeItem(at: sourceURL)
                try await MessageService.shared.sendVideo(processed: processed, toRandom: p, caption: caption, replyTo: reply, albumID: albumID)
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
    func collapsedAlbums(_ items: [Message]) -> [RenderUnit] {
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

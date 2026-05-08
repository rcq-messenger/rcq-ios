import Combine
import Foundation
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
            editingTarget = nil
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
        replyTarget = nil
        editingTarget = message
        input = message.text
    }

    func cancelEdit() {
        editingTarget = nil
        input = ""
    }

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

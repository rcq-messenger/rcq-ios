import Foundation
import LibSignalClient
import os.log
import UIKit

/// Send + receive layer. Sealed-sender via `/messages/sealed`; group fan-out via `/messages/group-sealed`.
@MainActor
final class MessageService {
    static let shared = MessageService()

    // Internal (not private) so the per-target extensions (Group /
    // Random / Premium living in sibling files) can reach the
    // shared crypto handle. `final class` means no subclass leakage.
    var crypto: CryptoService!
    private(set) var ownUIN: Int = 0

    private static let log = OSLog(subsystem: "app.rcq.client", category: "MessageService")

    private init() {}

    /// True if `text` mentions the local user. `#<ownUIN>` is always
    /// reliable (the UIN is stable); `@<ownNick>` is best-effort and
    /// case-insensitive (skipped when we have no own nickname). Used to set
    /// the home-row @ indicator on inbound group messages.
    func bodyMentionsMe(_ text: String) -> Bool {
        guard ownUIN > 0 else { return false }
        if text.contains("#\(ownUIN)") { return true }
        let nick = AuthService.shared.nickname
        if !nick.isEmpty,
           text.range(of: "@\(nick)", options: [.caseInsensitive]) != nil {
            return true
        }
        return false
    }

    func configure(ownUIN: Int) {
        self.ownUIN = ownUIN
        // Throwaway identity fallback for wiped Keychain — AuthService's
        // 404/401 recovery forces a real re-register on next /users/me.
        if let existing = SignalCryptoService.loadFromKeychain(ownUIN: ownUIN) {
            crypto = existing
        } else if let (_, fresh) = try? SignalCryptoService.bootstrap() {
            print("[MessageService] no identity in Keychain — bootstrapped fresh stub")
            crypto = fresh
        }
    }

    // MARK: - resend (failed messages)

    func resend(_ message: Message, in target: ChatTarget) async {
        guard message.deliveryState == .failed, message.isFromMe else { return }
        MessageStore.shared.updateState(messageID: message.id, thread: target.thread, state: .sending)

        let reply: ReplyContext? = {
            guard let rid = message.replyToID else { return nil }
            return ReplyContext(
                id: rid,
                snippet: message.replyToSnippet ?? "",
                authorName: message.replyToAuthorName ?? "",
            )
        }()
        let ttl = message.ttlSeconds

        let envelope: Envelope? = {
            switch message.kind {
            case .text:
                return .text(id: message.id, text: message.text, ttl: ttl, replyTo: reply)
            case .photo, .video, .file, .voice:
                guard let combined = message.mediaID,
                      let pipe = combined.firstIndex(of: "|") else { return nil }
                let mediaID = String(combined[..<pipe])
                let key = String(combined[combined.index(after: pipe)...])
                let caption: String? = message.text.isEmpty ? nil : message.text
                switch message.kind {
                case .photo:
                    return .photo(id: message.id, mediaID: mediaID, mediaKey: key, caption: caption, ttl: ttl, replyTo: reply, albumID: message.albumID, spoiler: message.isSpoiler)
                case .video:
                    return .video(id: message.id, mediaID: mediaID, mediaKey: key, thumbnailB64: message.thumbnailB64 ?? "", durationSec: message.durationSec, caption: caption, ttl: ttl, replyTo: reply, albumID: message.albumID, spoiler: message.isSpoiler)
                case .file:
                    return .file(id: message.id, mediaID: mediaID, mediaKey: key, fileName: message.fileName ?? "file", mime: message.fileMime ?? "application/octet-stream", sizeBytes: message.fileSizeBytes ?? 0, caption: caption, ttl: ttl, replyTo: reply)
                case .voice:
                    return .voice(id: message.id, mediaID: mediaID, mediaKey: key, durationSec: message.durationSec, ttl: ttl, replyTo: reply)
                default: return nil
                }
            default:
                return nil
            }
        }()

        guard let env = envelope else {
            MessageStore.shared.updateState(messageID: message.id, thread: target.thread, state: .failed)
            return
        }

        do {
            switch target {
            case .peer(let contact):
                try await sendEnvelope(env, to: contact, localID: message.id)
            case .group(let group):
                try await sendGroupEnvelope(env, to: group, localID: message.id)
            case .randomPeer:
                break
            }
        } catch {
        }
    }

    // MARK: - sending (1:1)

    func send(text: String, to contact: Contact, replyTo: ReplyContext? = nil) async throws {
        let ttl = ChatSettingsStore.shared.ttl(for: .peer(uin: contact.uin))
        let local = Message(
            thread: .peer(uin: contact.uin),
            senderUIN: ownUIN,
            isFromMe: true,
            kind: .text,
            text: text,
            ttlSeconds: ttl,
            replyToID: replyTo?.id,
            replyToSnippet: replyTo?.snippet,
            replyToAuthorName: replyTo?.authorName
        )
        MessageStore.shared.append(local)
        // Detach so the bubble paints immediately; failure flows through MessageStore.updateState.
        Task { [weak self] in
            try? await self?.sendEnvelope(.text(id: local.id, text: text, ttl: ttl, replyTo: replyTo), to: contact, localID: local.id)
        }
    }

    /// In-chat bridge sharing: hand `contact` a relay from your pool so they can
    /// route through it when their own relays are blocked (censorship-resistance
    /// — distribute off-config relays peer-to-peer). Renders as a `.relay` card
    /// on both sides; the recipient taps Add. See RCQ/docs/bridge-sharing-design.md.
    func shareRelay(_ relay: RelayConfigStore.RelayEntry, to contact: Contact) async throws {
        let wire = ContactRelayStore.relayToWire(relay)
        let local = Message(
            thread: .peer(uin: contact.uin),
            senderUIN: ownUIN,
            isFromMe: true,
            kind: .relay,
            text: ContactRelayStore.relayToToken(relay)
        )
        MessageStore.shared.append(local)
        Task { [weak self] in
            try? await self?.sendEnvelope(.relayShare(id: local.id, relay: wire, note: nil), to: contact, localID: local.id)
        }
    }

    /// Share a relay into a GROUP — the highest-reach censorship-resistant
    /// distribution: one drop in a community group hands the relay to every member
    /// over the E2E group fan-out (sender keys), invisible to a censor. Renders as
    /// a `.relay` card; each member taps Add (never auto-applied). A group-shared
    /// relay stays exit/fallback only and onion-entry-INELIGIBLE (ContactRelayStore
    /// is excluded from trustedVlessEntries), so a poisoned share can't become
    /// anyone's entry guard. See RCQ/docs/relay-distribution-v2.md.
    func shareRelay(_ relay: RelayConfigStore.RelayEntry, toGroup group: RCQGroup) async throws {
        let wire = ContactRelayStore.relayToWire(relay)
        let local = Message(
            thread: .group(id: group.id),
            senderUIN: ownUIN,
            isFromMe: true,
            kind: .relay,
            text: ContactRelayStore.relayToToken(relay)
        )
        MessageStore.shared.append(local)
        Task { [weak self] in
            try? await self?.sendGroupEnvelope(.relayShare(id: local.id, relay: wire, note: nil), to: group, localID: local.id)
        }
    }

    func sendPhoto(_ image: UIImage, to contact: Contact, caption: String? = nil, replyTo: ReplyContext? = nil, albumID: UUID? = nil, spoiler: Bool = false) async throws {
        let ttl = ChatSettingsStore.shared.ttl(for: .peer(uin: contact.uin))
        let local = Message(
            thread: .peer(uin: contact.uin),
            senderUIN: ownUIN,
            isFromMe: true,
            kind: .photo,
            text: caption ?? "",
            mediaID: nil,
            ttlSeconds: ttl,
            replyToID: replyTo?.id,
            replyToSnippet: replyTo?.snippet,
            replyToAuthorName: replyTo?.authorName,
            albumID: albumID,
            isSpoiler: spoiler
        )
        MessageStore.shared.append(local)
        MediaProgressStore.shared.begin(local.id)
        Task { [weak self] in
            guard let self else { return }
            let upload: MediaService.UploadResult
            do {
                upload = try await MediaService.shared.uploadImage(image, peerHost: contact.host) { p in
                    MediaProgressStore.shared.set(local.id, value: p)
                }
            } catch {
                MediaProgressStore.shared.clear(local.id)
                MessageStore.shared.updateState(messageID: local.id, thread: .peer(uin: contact.uin), state: .failed)
                return
            }
            MediaProgressStore.shared.clear(local.id)
            let combined = upload.mediaID + "|" + upload.keyBase64
            MessageStore.shared.updateMediaID(messageID: local.id, thread: .peer(uin: contact.uin), mediaID: combined)
            try? await self.sendEnvelope(
                .photo(id: local.id, mediaID: upload.mediaID, mediaKey: upload.keyBase64, caption: caption, ttl: ttl, replyTo: replyTo, albumID: albumID, spoiler: spoiler),
                to: contact, localID: local.id
            )
        }
    }

    /// Send an animated GIF preserving its raw bytes (no JPEG
    /// recompression). Envelope is `.photo` — the receiver detects the
    /// `"GIF8"` magic on the decrypted blob and renders via
    /// `AnimatedGIFView`. Mirrors `sendPhoto` otherwise.
    func sendGIF(data: Data, preview: UIImage, to contact: Contact, caption: String? = nil, replyTo: ReplyContext? = nil, albumID: UUID? = nil) async throws {
        let ttl = ChatSettingsStore.shared.ttl(for: .peer(uin: contact.uin))
        let local = Message(
            thread: .peer(uin: contact.uin),
            senderUIN: ownUIN,
            isFromMe: true,
            kind: .photo,
            text: caption ?? "",
            mediaID: nil,
            ttlSeconds: ttl,
            replyToID: replyTo?.id,
            replyToSnippet: replyTo?.snippet,
            replyToAuthorName: replyTo?.authorName,
            albumID: albumID
        )
        MessageStore.shared.append(local)
        MediaProgressStore.shared.begin(local.id)
        Task { [weak self] in
            guard let self else { return }
            let upload: MediaService.UploadResult
            do {
                upload = try await MediaService.shared.uploadGIF(data: data, peerHost: contact.host) { p in
                    MediaProgressStore.shared.set(local.id, value: p)
                }
            } catch {
                MediaProgressStore.shared.clear(local.id)
                MessageStore.shared.updateState(messageID: local.id, thread: .peer(uin: contact.uin), state: .failed)
                return
            }
            MediaProgressStore.shared.clear(local.id)
            let combined = upload.mediaID + "|" + upload.keyBase64
            MessageStore.shared.updateMediaID(messageID: local.id, thread: .peer(uin: contact.uin), mediaID: combined)
            try? await self.sendEnvelope(
                .photo(id: local.id, mediaID: upload.mediaID, mediaKey: upload.keyBase64, caption: caption, ttl: ttl, replyTo: replyTo, albumID: albumID),
                to: contact, localID: local.id
            )
        }
    }

    /// Consumes the `.m4a` at `fileURL` (deleted on success or failure).
    func sendVoice(fileURL: URL, durationSec: Double, to contact: Contact, replyTo: ReplyContext? = nil) async throws {
        let ttl = ChatSettingsStore.shared.ttl(for: .peer(uin: contact.uin))
        let local = Message(
            thread: .peer(uin: contact.uin),
            senderUIN: ownUIN,
            isFromMe: true,
            kind: .voice,
            text: "",
            mediaID: nil,
            durationSec: durationSec,
            ttlSeconds: ttl,
            replyToID: replyTo?.id,
            replyToSnippet: replyTo?.snippet,
            replyToAuthorName: replyTo?.authorName,
        )
        MessageStore.shared.append(local)
        MediaProgressStore.shared.begin(local.id)
        Task { [weak self] in
            guard let self else { return }
            defer { try? FileManager.default.removeItem(at: fileURL) }
            let upload: MediaService.UploadResult
            do {
                upload = try await MediaService.shared.uploadFile(at: fileURL, peerHost: contact.host) { p in
                    MediaProgressStore.shared.set(local.id, value: p)
                }
            } catch {
                MediaProgressStore.shared.clear(local.id)
                MessageStore.shared.updateState(messageID: local.id, thread: .peer(uin: contact.uin), state: .failed)
                return
            }
            MediaProgressStore.shared.clear(local.id)
            let combined = upload.mediaID + "|" + upload.keyBase64
            MessageStore.shared.updateMediaID(messageID: local.id, thread: .peer(uin: contact.uin), mediaID: combined)
            try? await self.sendEnvelope(
                .voice(
                    id: local.id,
                    mediaID: upload.mediaID, mediaKey: upload.keyBase64,
                    durationSec: durationSec,
                    ttl: ttl,
                    replyTo: replyTo
                ),
                to: contact, localID: local.id
            )
        }
    }

    /// Arbitrary attachment (PDF / DOCX / ZIP / …). Reuses the encrypted
    /// blob pipeline — the receiver detects the kind via envelope and
    /// renders a file bubble; tap-to-open downloads + decrypts + hands
    /// the bytes to QuickLook / share sheet.
    func sendFile(
        fileURL: URL,
        fileName: String,
        mime: String,
        sizeBytes: Int,
        to contact: Contact,
        caption: String? = nil,
        replyTo: ReplyContext? = nil,
    ) async throws {
        let ttl = ChatSettingsStore.shared.ttl(for: .peer(uin: contact.uin))
        let local = Message(
            thread: .peer(uin: contact.uin),
            senderUIN: ownUIN,
            isFromMe: true,
            kind: .file,
            text: caption ?? "",
            mediaID: nil,
            ttlSeconds: ttl,
            replyToID: replyTo?.id,
            replyToSnippet: replyTo?.snippet,
            replyToAuthorName: replyTo?.authorName,
            fileName: fileName,
            fileMime: mime,
            fileSizeBytes: sizeBytes,
        )
        MessageStore.shared.append(local)
        MediaProgressStore.shared.begin(local.id)
        Task { [weak self] in
            guard let self else { return }
            defer { try? FileManager.default.removeItem(at: fileURL) }
            let upload: MediaService.UploadResult
            do {
                upload = try await MediaService.shared.uploadFile(at: fileURL, peerHost: contact.host) { p in
                    MediaProgressStore.shared.set(local.id, value: p)
                }
            } catch {
                MediaProgressStore.shared.clear(local.id)
                MessageStore.shared.updateState(messageID: local.id, thread: .peer(uin: contact.uin), state: .failed)
                return
            }
            MediaProgressStore.shared.clear(local.id)
            let combined = upload.mediaID + "|" + upload.keyBase64
            MessageStore.shared.updateMediaID(messageID: local.id, thread: .peer(uin: contact.uin), mediaID: combined)
            try? await self.sendEnvelope(
                .file(
                    id: local.id,
                    mediaID: upload.mediaID, mediaKey: upload.keyBase64,
                    fileName: fileName, mime: mime, sizeBytes: sizeBytes,
                    caption: caption,
                    ttl: ttl,
                    replyTo: replyTo
                ),
                to: contact, localID: local.id
            )
        }
    }

    /// Static pinned location (latitude / longitude). Receivers render
    /// a map snapshot bubble; tap → opens Apple Maps. No encrypted
    /// blob — coordinates ship inside the envelope itself.
    func sendLocation(
        latitude: Double,
        longitude: Double,
        to contact: Contact,
        caption: String? = nil,
        replyTo: ReplyContext? = nil,
    ) async throws {
        let ttl = ChatSettingsStore.shared.ttl(for: .peer(uin: contact.uin))
        let local = Message(
            thread: .peer(uin: contact.uin),
            senderUIN: ownUIN,
            isFromMe: true,
            kind: .location,
            text: caption ?? "",
            ttlSeconds: ttl,
            replyToID: replyTo?.id,
            replyToSnippet: replyTo?.snippet,
            replyToAuthorName: replyTo?.authorName,
            latitude: latitude,
            longitude: longitude,
        )
        MessageStore.shared.append(local)
        try await sendEnvelope(
            .location(
                id: local.id,
                lat: latitude, lng: longitude,
                caption: caption,
                ttl: ttl,
                replyTo: replyTo
            ),
            to: contact, localID: local.id
        )
    }

    /// Optimistic-render send. The bubble appears in the chat the
    /// instant the user taps Send — pre-populated with the picker's
    /// quick first-frame thumbnail. VideoProcessor (compression) +
    /// upload run inside the spawned Task; the bubble's canonical
    /// thumbnail and duration are patched in when processing finishes,
    /// then the real mediaID lands when the upload settles.
    /// `previewThumbnailB64` is the picker's strip preview JPEG, base64.
    func sendVideo(
        from sourceURL: URL,
        previewThumbnailB64: String,
        to contact: Contact,
        caption: String? = nil,
        replyTo: ReplyContext? = nil,
        albumID: UUID? = nil,
        spoiler: Bool = false,
    ) async throws {
        let ttl = ChatSettingsStore.shared.ttl(for: .peer(uin: contact.uin))
        let local = Message(
            thread: .peer(uin: contact.uin),
            senderUIN: ownUIN,
            isFromMe: true,
            kind: .video,
            text: caption ?? "",
            mediaID: nil,
            thumbnailB64: previewThumbnailB64.isEmpty ? nil : previewThumbnailB64,
            durationSec: 0,
            ttlSeconds: ttl,
            replyToID: replyTo?.id,
            replyToSnippet: replyTo?.snippet,
            replyToAuthorName: replyTo?.authorName,
            albumID: albumID,
            isSpoiler: spoiler
        )
        MessageStore.shared.append(local)
        MediaProgressStore.shared.begin(local.id)
        Task { [weak self] in
            guard let self else { return }
            defer { try? FileManager.default.removeItem(at: sourceURL) }
            let processed: VideoProcessor.Output
            do {
                processed = try await VideoProcessor.process(sourceURL: sourceURL)
            } catch {
                MediaProgressStore.shared.clear(local.id)
                MessageStore.shared.updateState(messageID: local.id, thread: .peer(uin: contact.uin), state: .failed)
                return
            }
            MessageStore.shared.updateVideoMeta(
                messageID: local.id, thread: .peer(uin: contact.uin),
                thumbnailB64: processed.thumbnailB64, durationSec: processed.durationSec,
            )
            let upload: MediaService.UploadResult
            do {
                upload = try await MediaService.shared.uploadFile(at: processed.url, peerHost: contact.host) { p in
                    MediaProgressStore.shared.set(local.id, value: p)
                }
            } catch {
                MediaProgressStore.shared.clear(local.id)
                MessageStore.shared.updateState(messageID: local.id, thread: .peer(uin: contact.uin), state: .failed)
                return
            }
            MediaProgressStore.shared.clear(local.id)
            let combined = upload.mediaID + "|" + upload.keyBase64
            MessageStore.shared.updateMediaID(messageID: local.id, thread: .peer(uin: contact.uin), mediaID: combined)
            try? await self.sendEnvelope(
                .video(
                    id: local.id,
                    mediaID: upload.mediaID, mediaKey: upload.keyBase64,
                    thumbnailB64: processed.thumbnailB64,
                    durationSec: processed.durationSec,
                    caption: caption,
                    ttl: ttl,
                    replyTo: replyTo,
                    albumID: albumID,
                    spoiler: spoiler
                ),
                to: contact, localID: local.id
            )
        }
    }

    // MARK: - sending (forward)

    /// Nickname-only attribution per spec — original UIN is never propagated.
    func forward(message: Message, authorName: String, toContact contact: Contact) async throws {
        let thread = ThreadID.peer(uin: contact.uin)
        let newID = UUID()
        let envelope = forwardEnvelope(from: message, newID: newID, authorName: authorName, ttlForThread: thread)
        let local = forwardLocalMessage(from: message, newID: newID, in: thread, authorName: authorName)
        MessageStore.shared.append(local)
        try await sendEnvelope(envelope, to: contact, localID: local.id)
    }

    func forward(message: Message, authorName: String, toGroup group: RCQGroup) async throws {
        let thread = ThreadID.group(id: group.id)
        let newID = UUID()
        let envelope = forwardEnvelope(from: message, newID: newID, authorName: authorName, ttlForThread: thread)
        let local = forwardLocalMessage(from: message, newID: newID, in: thread, authorName: authorName)
        MessageStore.shared.append(local)
        try await sendGroupEnvelope(envelope, to: group, localID: local.id)
    }

    private func forwardEnvelope(from source: Message, newID: UUID, authorName: String, ttlForThread thread: ThreadID) -> Envelope {
        let ttl = ChatSettingsStore.shared.ttl(for: thread)
        switch source.kind {
        case .photo:
            // mediaID is "<id>|<key>" — split for the envelope.
            let parts = (source.mediaID ?? "").split(separator: "|", maxSplits: 1).map(String.init)
            let mediaID = parts.first ?? ""
            let mediaKey = parts.count > 1 ? parts[1] : ""
            return .photo(
                id: newID,
                mediaID: mediaID, mediaKey: mediaKey,
                caption: source.text.isEmpty ? nil : source.text,
                ttl: ttl,
                forwardedFromName: authorName,
                spoiler: source.isSpoiler
            )
        case .video:
            let parts = (source.mediaID ?? "").split(separator: "|", maxSplits: 1).map(String.init)
            let mediaID = parts.first ?? ""
            let mediaKey = parts.count > 1 ? parts[1] : ""
            return .video(
                id: newID,
                mediaID: mediaID, mediaKey: mediaKey,
                thumbnailB64: source.thumbnailB64 ?? "",
                durationSec: source.durationSec,
                caption: source.text.isEmpty ? nil : source.text,
                ttl: ttl,
                forwardedFromName: authorName,
                spoiler: source.isSpoiler
            )
        case .voice:
            let parts = (source.mediaID ?? "").split(separator: "|", maxSplits: 1).map(String.init)
            let mediaID = parts.first ?? ""
            let mediaKey = parts.count > 1 ? parts[1] : ""
            return .voice(
                id: newID,
                mediaID: mediaID, mediaKey: mediaKey,
                durationSec: source.durationSec,
                ttl: ttl,
                forwardedFromName: authorName
            )
        default:
            return .text(id: newID, text: source.text, ttl: ttl, forwardedFromName: authorName)
        }
    }

    private func forwardLocalMessage(from source: Message, newID: UUID, in thread: ThreadID, authorName: String) -> Message {
        Message(
            id: newID,
            thread: thread,
            senderUIN: ownUIN,
            isFromMe: true,
            kind: source.kind,
            text: source.text,
            mediaID: source.mediaID,
            sentAt: Date(),
            deliveryState: .sending,
            thumbnailB64: source.thumbnailB64,
            durationSec: source.durationSec,
            ttlSeconds: ChatSettingsStore.shared.ttl(for: thread),
            forwardedFromName: authorName,
            isSpoiler: source.isSpoiler
        )
    }

    // MARK: - editing

    func edit(message: Message, newText: String, to contact: Contact) async throws {
        let now = Date()
        let thread = ThreadID.peer(uin: contact.uin)
        MessageStore.shared.applyEdit(messageID: message.id, thread: thread, newText: newText, editedAt: now)
        // Saved Messages — no peer to notify.
        if contact.uin == ownUIN { return }
        try await sendEnvelope(.edit(targetID: message.id, text: newText), to: contact, localID: nil)
    }

    func edit(message: Message, newText: String, in group: RCQGroup) async throws {
        let now = Date()
        let thread = ThreadID.group(id: group.id)
        MessageStore.shared.applyEdit(messageID: message.id, thread: thread, newText: newText, editedAt: now)
        try await sendGroupEnvelope(.edit(targetID: message.id, text: newText), to: group, localID: nil)
    }

    func edit(message: Message, newText: String, toRandom peer: RandomPeer) async throws {
        // Random ingest is a no-op for .edit — sender-side local update is the visible part.
        if let idx = RandomChatService.shared.messages.firstIndex(where: { $0.id == message.id }) {
            var msg = RandomChatService.shared.messages[idx]
            msg = Message(
                id: msg.id, thread: msg.thread, senderUIN: msg.senderUIN,
                isFromMe: msg.isFromMe, kind: msg.kind, text: newText,
                mediaID: msg.mediaID, sentAt: msg.sentAt,
                deliveryState: msg.deliveryState, receivedWhileAway: msg.receivedWhileAway,
                deletedForEveryone: msg.deletedForEveryone,
                reactions: msg.reactions,
                thumbnailB64: msg.thumbnailB64,
                durationSec: msg.durationSec,
                ttlSeconds: msg.ttlSeconds,
                forwardedFromName: msg.forwardedFromName,
                replyToID: msg.replyToID,
                replyToSnippet: msg.replyToSnippet,
                replyToAuthorName: msg.replyToAuthorName,
                editedAt: Date()
            )
            // delete + append swaps the row since append dedups on UUID.
            RandomChatService.shared.deleteMessage(id: message.id)
            RandomChatService.shared.append(msg)
        }
        try await sendRandomEnvelope(.edit(targetID: message.id, text: newText), to: peer, localID: nil)
    }

    /// Drop the local row first so the fade fires on tap; ship envelope after.
    func deleteForEveryone(message: Message, to contact: Contact) async throws {
        MessageStore.shared.deleteLocal(messageID: message.id, thread: .peer(uin: contact.uin))
        try await sendEnvelope(
            .deleteForEveryone(targetID: message.id),
            to: contact,
            localID: nil
        )
    }

    func deleteForEveryone(message: Message, toRandom peer: RandomPeer) async throws {
        RandomChatService.shared.deleteMessage(id: message.id)
        try await sendRandomEnvelope(
            .deleteForEveryone(targetID: message.id),
            to: peer, localID: nil
        )
    }

    private static func blurThumbnailB64(from image: UIImage) -> String {
        let target: CGFloat = 64
        let scale = min(target / image.size.width, target / image.size.height, 1.0)
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let small = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
        return small.jpegData(compressionQuality: 0.4)?.base64EncodedString() ?? ""
    }

    // MARK: - read receipts

    /// 1:1 only — group acks would broadcast to N members.
    func markRead(messages: [Message], in target: ChatTarget) async {
        let received = messages.filter { !$0.isFromMe && $0.deliveryState != .read }
        guard !received.isEmpty else { return }
        let ids = received.map(\.id)
        switch target {
        case .peer(let contact):
            MessageStore.shared.markRead(messageIDs: ids, thread: .peer(uin: contact.uin))
            // Privacy gate — "nobody" suppresses every outbound
            // receipt; the local read-state still lands so the
            // user's own bubble chrome updates. "contacts" /
            // "everyone" both send: peer chats are reached only
            // through the contact list, so "contacts" is the same
            // observable behaviour as "everyone".
            let policy = UserDefaults.standard.string(forKey: "rcq.privacy.readReceiptsVisibility") ?? "everyone"
            guard policy != "nobody" else { return }
            do {
                try await sendEnvelope(.readReceipt(targetIDs: ids), to: contact, localID: nil)
            } catch { }
        case .group:
            MessageStore.shared.markRead(messageIDs: ids, thread: target.thread)
        case .randomPeer:
            // Would leak engagement metadata to the stranger.
            break
        }
    }

    // MARK: - reactions

    func toggleReaction(on message: Message, asset: String, in target: ChatTarget) async {
        let me = ownUIN
        let current = message.reactions[me]
        let newAsset: String? = (current == asset) ? nil : asset
        // Auto-tick only when SETTING a reaction (not when toggling off).
        if case .randomPeer = target {
            RandomChatService.shared.applyReaction(targetID: message.id, uin: me, asset: newAsset)
        } else {
            MessageStore.shared.applyReaction(
                targetID: message.id, thread: target.thread, uin: me, asset: newAsset
            )
        }
        let env: Envelope = .reaction(targetID: message.id, asset: newAsset)
        do {
            switch target {
            case .peer(let c):
                try await sendEnvelope(env, to: c, localID: nil)
            case .group(let g):
                try await sendGroupEnvelope(env, to: g, localID: nil)
            case .randomPeer(let p):
                try await sendRandomEnvelope(env, to: p, localID: nil)
            }
        } catch { }
        // Echo to your OWN other devices (linked web / second phone): random
        // chats are ephemeral and never synced, so skip them.
        if case .randomPeer = target {} else {
            await sendReactionSelfEcho(env)
        }
    }

    /// Echo a reaction to the user's OWN other logged-in devices. sendEnvelope()
    /// short-circuits a send to self (Saved Messages stays local), so we seal
    /// the reaction to our own identity (v=1) and POST it to our own uin. The
    /// receiver applies reactions by target id across threads, so it lands on
    /// the same message there. Best-effort — the reaction itself already went.
    private func sendReactionSelfEcho(_ envelope: Envelope) async {
        let me = ownUIN
        guard let mine = try? crypto.bootstrapIdentity() else { return }
        let selfBundle = PeerBundle(uin: me, identityKey: mine.identityKey, signingKey: mine.signingKey)
        guard let blob = try? crypto.encrypt(envelope: envelope, for: selfBundle) else { return }
        struct Body: Encodable { let to_uin: Int; let envelope_type: String; let payload: String }
        struct Out: Decodable { let delivered: Bool; let queued: Bool }
        do {
            let _: Out = try await APIClient.shared.request(
                "POST", "/messages/sealed",
                body: Body(to_uin: me, envelope_type: envelopeType(for: envelope), payload: blob),
                authenticated: false,
                retries: 1
            )
        } catch { }
    }

    // MARK: - multi-device carbons (send-side sync)

    /// Message kinds we mirror to the user's other devices via a carbon.
    /// Reactions sync through their own self-echo; control envelopes don't sync.
    private func isCarbonable(_ env: Envelope) -> Bool {
        switch env {
        case .text, .photo, .video, .voice, .file, .location: return true
        // An edit has to ride along too. Without it the queue held a carbon of
        // the ORIGINAL wording and never one of the correction, so a message
        // that came back through that route came back in its pre-edit form —
        // the third symptom in #415 — and the user's other device never saw the
        // edit at all.
        case .edit: return true
        default: return false
        }
    }

    /// Mirror a just-sent message to the user's OTHER logged-in devices. Seals
    /// a `.carbon` (the original envelope + its destination) to our own identity
    /// (v=1) and posts it to our own uin with a NON-pushable type so it doesn't
    /// buzz us about our own message — it syncs over WS / the per-device queue.
    /// The other device files the inner message as fromMe; the origin device
    /// dedups its own carbon by id. Best-effort — the message already went out.
    private func sendMessageCarbon(_ inner: Envelope, toPeer: Int?, toGroup: Int?) async {
        guard isCarbonable(inner) else { return }
        let me = ownUIN
        guard let mine = try? crypto.bootstrapIdentity() else { return }
        let selfBundle = PeerBundle(uin: me, identityKey: mine.identityKey, signingKey: mine.signingKey)
        let carbon: Envelope = .carbon(to: toPeer, gid: toGroup, env: inner)
        guard let blob = try? crypto.encrypt(envelope: carbon, for: selfBundle) else { return }
        struct Body: Encodable { let to_uin: Int; let envelope_type: String; let payload: String }
        struct Out: Decodable { let delivered: Bool; let queued: Bool }
        do {
            let _: Out = try await APIClient.shared.request(
                "POST", "/messages/sealed",
                body: Body(to_uin: me, envelope_type: "carbon", payload: blob),
                authenticated: false,
                retries: 1
            )
        } catch { }
    }

    /// File a carbon's inner message as a fromMe row in its destination thread.
    /// Mirrors the incoming construction but marks it ours and .delivered.
    /// MessageStore dedups by id, so the origin device's own carbon and any
    /// queue redelivery are no-ops.
    @discardableResult
    private func appendCarbonMessage(inner: Envelope, thread: ThreadID, serverTime: Date) -> Bool {
        let me = ownUIN
        switch inner {
        case .text(let id, let text, let ttl, let fwd, let reply):
            return MessageStore.shared.append(Message(
                id: id, thread: thread, senderUIN: me, isFromMe: true,
                kind: .text, text: text, sentAt: serverTime, deliveryState: .delivered,
                receivedWhileAway: false, ttlSeconds: ttl, forwardedFromName: fwd,
                replyToID: reply?.id, replyToSnippet: reply?.snippet, replyToAuthorName: reply?.authorName
            ))
        case .photo(let id, let mediaID, let mediaKey, let caption, let ttl, let fwd, let reply, let album, let spoiler):
            return MessageStore.shared.append(Message(
                id: id, thread: thread, senderUIN: me, isFromMe: true,
                kind: .photo, text: caption ?? "", mediaID: mediaID + "|" + mediaKey,
                sentAt: serverTime, deliveryState: .delivered,
                receivedWhileAway: false, ttlSeconds: ttl, forwardedFromName: fwd,
                replyToID: reply?.id, replyToSnippet: reply?.snippet, replyToAuthorName: reply?.authorName,
                albumID: album, isSpoiler: spoiler
            ))
        case .video(let id, let mediaID, let mediaKey, let thumb, let dur, let caption, let ttl, let fwd, let reply, let album, let spoiler):
            return MessageStore.shared.append(Message(
                id: id, thread: thread, senderUIN: me, isFromMe: true,
                kind: .video, text: caption ?? "", mediaID: mediaID + "|" + mediaKey,
                sentAt: serverTime, deliveryState: .delivered,
                receivedWhileAway: false, thumbnailB64: thumb, durationSec: dur,
                ttlSeconds: ttl, forwardedFromName: fwd,
                replyToID: reply?.id, replyToSnippet: reply?.snippet, replyToAuthorName: reply?.authorName,
                albumID: album, isSpoiler: spoiler
            ))
        case .voice(let id, let mediaID, let mediaKey, let dur, let ttl, let fwd, let reply):
            return MessageStore.shared.append(Message(
                id: id, thread: thread, senderUIN: me, isFromMe: true,
                kind: .voice, text: "", mediaID: mediaID + "|" + mediaKey,
                sentAt: serverTime, deliveryState: .delivered,
                receivedWhileAway: false, durationSec: dur, ttlSeconds: ttl, forwardedFromName: fwd,
                replyToID: reply?.id, replyToSnippet: reply?.snippet, replyToAuthorName: reply?.authorName
            ))
        case .file(let id, let mediaID, let mediaKey, let fname, let mime, let size, let caption, let ttl, let fwd, let reply):
            return MessageStore.shared.append(Message(
                id: id, thread: thread, senderUIN: me, isFromMe: true,
                kind: .file, text: caption ?? "", mediaID: mediaID + "|" + mediaKey,
                sentAt: serverTime, deliveryState: .delivered,
                receivedWhileAway: false, ttlSeconds: ttl, forwardedFromName: fwd,
                replyToID: reply?.id, replyToSnippet: reply?.snippet, replyToAuthorName: reply?.authorName,
                fileName: fname, fileMime: mime, fileSizeBytes: size
            ))
        case .location(let id, let lat, let lng, let caption, let ttl, let fwd, let reply):
            return MessageStore.shared.append(Message(
                id: id, thread: thread, senderUIN: me, isFromMe: true,
                kind: .location, text: caption ?? "", sentAt: serverTime, deliveryState: .delivered,
                receivedWhileAway: false, ttlSeconds: ttl, forwardedFromName: fwd,
                replyToID: reply?.id, replyToSnippet: reply?.snippet, replyToAuthorName: reply?.authorName,
                latitude: lat, longitude: lng
            ))
        default:
            return false
        }
    }

    // MARK: - screen-secure (per-conversation)

    /// Propagate this 1:1 conversation's screen-secure toggle to the peer so
    /// THEIR client also blanks the chat (you can't blank a screenshot on the
    /// peer's phone except by their client enforcing it).
    func sendSecureScreen(on: Bool, to contact: Contact) async {
        try? await sendEnvelope(.secureScreen(on: on), to: contact, localID: nil)
    }

    /// A screenshot was taken in a secure 1:1 chat — post "You took a
    /// screenshot" locally and tell the peer (their client renders
    /// "<me> took a screenshot" with my name in their locale).
    func reportScreenshot(to contact: Contact) async {
        let thread = ThreadID.peer(uin: contact.uin)
        _ = await MainActor.run {
            MessageStore.shared.append(Message(
                id: UUID(), thread: thread, senderUIN: ownUIN, isFromMe: true,
                kind: .systemNotice, text: "secscreen.you_screenshotted".localized,
                sentAt: Date(), deliveryState: .sent
            ))
        }
        try? await sendEnvelope(.screenshotTaken(id: UUID()), to: contact, localID: nil)
    }

    // MARK: - low level

    private func sendEnvelope(_ envelope: Envelope, to contact: Contact, localID: UUID?) async throws {
        // ⚠⚠ A duress session puts nothing on the wire, and must not look like
        // it tried.
        //
        // It already sent nothing: the encrypt below throws for a decoy contact
        // (no usable key) and the throw happens inside a detached `Task` whose
        // `try?` drops it, so the bubble sat in "sending" forever. A spinner
        // that never resolves is the loudest tell this screen had — "send
        // something" is the cheapest test a coercer can run, and the decoy
        // failed it on the first message. (Our own article says the send is
        // imitated locally. It was not, which is how a reader found it.)
        //
        // Marked `.sent`, which is exactly what a message to someone who is
        // offline looks like: one tick, no error, and no second tick promised.
        // The row is already in the decoy's own encrypted store, so it survives
        // leaving the chat and coming back.
        if PanicPINService.shared.isDecoy {
            if let localID {
                MessageStore.shared.updateState(
                    messageID: localID, thread: .peer(uin: contact.uin), state: .sent
                )
            }
            playSentSound(for: envelope)
            return
        }
        // Saved Messages. The note is already in this device's store, so there
        // is nothing to deliver TO — but there are the account's OTHER devices,
        // and until now they never learned about it: a note written on the
        // iPhone stayed on the iPhone (founder, 12.08), which is the same gap
        // the web had until #469 and which Android has never had.
        //
        // A carbon is exactly the right shape and already works: it seals the
        // inner envelope to our own key, the receiving device files it into
        // `.peer(uin: ownUIN)` — the Saved thread — and MessageStore dedups by
        // id, so this device ignores its own copy coming back.
        if contact.uin == ownUIN {
            if let localID {
                MessageStore.shared.updateState(messageID: localID, thread: .peer(uin: contact.uin), state: .delivered)
            }
            playSentSound(for: envelope)
            await sendMessageCarbon(envelope, toPeer: ownUIN, toGroup: nil)
            return
        }
        // Federation (F2): a cross-island peer (host set) lives on another island —
        // seal v=1 to their key card and deposit to their island(s), not the
        // flagship. Gated strictly: every flagship contact has host==nil and falls
        // through to the unchanged path below.
        if let host = contact.host {
            let ciBundle = PeerBundle(uin: contact.uin, identityKey: contact.identityKey, signingKey: contact.signingKey)
            let ciBlob = try crypto.encrypt(envelope: envelope, for: ciBundle)
            var ok = false
            // Gossip-aware home resolution anchored to the LOCALLY-pinned signing
            // key, so the send reaches the peer via our gossip mirror even when
            // their own island is blocked or dead (the seal above already uses
            // the local identity key — no live card fetch). Floor to the single
            // address we have when nothing verifies anywhere.
            var ciHomes = await Multihome.resolveAndMirrorHomes(peerHost: host, peerUin: contact.uin, peerSigningKey: contact.signingKey)
            if ciHomes.isEmpty { ciHomes = [RcqFederation.Home(host: host, uin: contact.uin)] }
            for h in ciHomes {
                // F3: attach an anonymous deposit token (mintToken) on the
                // cross-island 1:1 message path — the permissionless-spam vector.
                if await CrossIslandSender.deposit(host: h.host, uin: h.uin, payload: ciBlob, mintToken: true) { ok = true }
            }
            if let localID {
                MessageStore.shared.updateState(messageID: localID, thread: .peer(uin: contact.uin), state: ok ? .sent : .failed)
            }
            playSentSound(for: envelope)
            return
        }
        let bundle = PeerBundle(uin: contact.uin, identityKey: contact.identityKey, signingKey: contact.signingKey)
        let fanout = try await sealForPeerDevices(
            envelope: envelope, peer: bundle, peerSignalIdentityKey: contact.signalIdentityKey
        )

        struct Out: Decodable { let delivered: Bool; let queued: Bool }

        let envType = envelopeType(for: envelope)
        do {
            var delivered = false
            var queued = false
            var accepted = 0
            var lastError: Error = URLError(.unknown)
            for copy in fanout.copies {
                do {
                    let out: Out = try await APIClient.shared.request(
                        "POST", "/messages/sealed",
                        body: SealedSendBody(
                            to_uin: contact.uin, envelope_type: envType,
                            payload: copy.payload, to_device_id: copy.deviceID
                        ),
                        authenticated: false,
                        retries: 2
                    )
                    accepted += 1
                    delivered = delivered || out.delivered
                    queued = queued || out.queued
                } catch {
                    // 404 on an addressed copy = that install is gone; the
                    // list we fanned out over is stale. The peer's other
                    // devices still took their copy, so this is not a failed
                    // send unless every copy failed.
                    if copy.deviceID != nil, let api = error as? APIError, case .http(404, _) = api {
                        await SignalCryptoService.invalidatePeerDevices(forPeerUIN: contact.uin)
                    }
                    lastError = error
                }
            }
            // Throws only when EVERY copy failed: a peer with a phone online
            // and a desktop that is gone has still been written to.
            guard accepted > 0 else { throw lastError }
            // `delivered` needs the fan-out to be WHOLE — every install sealed
            // to AND every copy accepted. A partial fan-out reports the weaker
            // state on purpose: the message did reach somebody, so failing the
            // send outright would be a lie too, but a device that got no copy
            // is one this send never delivered to and the tick above the
            // bubble must not say otherwise.
            let whole = fanout.complete && accepted == fanout.copies.count
            if !whole {
                print("[MessageService] partial fan-out to \(contact.uin): \(accepted) of \(fanout.copies.count) copies posted")
            }
            if let localID {
                let next: DeliveryState
                if delivered && whole {
                    next = .delivered
                } else if delivered || queued {
                    // One tick — the same thing a message to somebody offline
                    // shows, and the same thing it means: it is on the island,
                    // it has not reached every install of them yet.
                    next = .sent
                } else {
                    next = .failed
                }
                MessageStore.shared.updateState(messageID: localID, thread: .peer(uin: contact.uin), state: next)
            }
            playSentSound(for: envelope)
            // Multihoming v1: best-effort v=1 sealed copy into the peer's OTHER
            // home islands; no-op (cached record lookup only) for single-homed
            // peers — today's universal case.
            if let v1Blob = try? crypto.encrypt(envelope: envelope, for: bundle) {
                let peerUin = contact.uin, peerSk = contact.signingKey
                Task.detached(priority: .utility) {
                    _ = await Multihome.depositToExtraHomes(peerUin: peerUin, peerSigningKey: peerSk, sealedV1: v1Blob)
                }
            }
            // Mirror the message to the user's other devices (best-effort).
            await sendMessageCarbon(envelope, toPeer: contact.uin, toGroup: nil)
        } catch {
            // Primary island unreachable — failover: the (possibly stale-cached)
            // record may list other homes; one accepted copy = delivered.
            if let v1Blob = try? crypto.encrypt(envelope: envelope, for: bundle),
               await Multihome.depositToExtraHomes(peerUin: contact.uin, peerSigningKey: contact.signingKey, sealedV1: v1Blob) > 0 {
                if let localID {
                    MessageStore.shared.updateState(messageID: localID, thread: .peer(uin: contact.uin), state: .sent)
                }
                playSentSound(for: envelope)
                return
            }
            if let localID {
                MessageStore.shared.updateState(messageID: localID, thread: .peer(uin: contact.uin), state: .failed)
            }
            throw error
        }
    }

    /// Federation gossip B1 (second half) — SELF-PUSH the signed home-island
    /// record to every contact as a v=1 `homerec` envelope, so contacts cache
    /// where to reach us even if our island later dies (the server mirror can't
    /// cover "both my islands gone at once"). Call AFTER a record change
    /// (add/remove backup, promote) — NOT on every boot. Best-effort per
    /// contact. Only shares OUR homes with people already our contacts → no
    /// social-graph leak (founder rejected the pull-from-mutuals variant).
    func pushHomeRecordToContacts() async {
        let uin = ownUIN
        guard uin != 0,
              let doc = await AuthService.shared.buildOwnRecordDoc(ownUIN: uin),
              let data = try? JSONSerialization.data(withJSONObject: doc),
              let wire = try? JSONDecoder().decode(Envelope.IslandRecordWire.self, from: data) else { return }
        let env = Envelope.homeRecord(rec: wire)
        struct Ack: Decodable {}
        struct Body: Encodable { let to_uin: Int; let envelope_type: String; let payload: String }
        for c in ContactService.shared.contacts where !c.blocked && c.uin != uin && !c.identityKey.isEmpty {
            let bundle = PeerBundle(uin: c.uin, identityKey: c.identityKey, signingKey: c.signingKey)
            guard let blob = try? crypto.encrypt(envelope: env, for: bundle) else { continue }  // v=1
            if let host = c.host {
                // Cross-island contact: deposit to their home(s) (gossip-aware).
                var homes = await Multihome.resolveAndMirrorHomes(peerHost: host, peerUin: c.uin, peerSigningKey: c.signingKey)
                if homes.isEmpty { homes = [RcqFederation.Home(host: host, uin: c.uin)] }
                for h in homes { _ = await CrossIslandSender.deposit(host: h.host, uin: h.uin, payload: blob) }
            } else {
                // Flagship contact: non-pushable type so it doesn't buzz them.
                _ = try? await APIClient.shared.request(
                    "POST", "/messages/sealed",
                    body: Body(to_uin: c.uin, envelope_type: "homerec", payload: blob),
                    authenticated: false
                ) as Ack
            }
        }
    }

    private func encryptForPeer(envelope: Envelope, peer: PeerBundle, peerSignalIdentityKey: String?) async throws -> String {
        guard let psk = peerSignalIdentityKey, !psk.isEmpty else {
            return try crypto.encrypt(envelope: envelope, for: peer)
        }
        do {
            try await SignalCryptoService.ensureStage3Session(forPeerUIN: peer.uin)
            return try crypto.encryptStage3(envelope: envelope, for: peer, deviceId: 1)
        } catch {
            print("[MessageService] Stage 3 encrypt for \(peer.uin) failed (\(error)) — falling back to v=1")
            return try crypto.encrypt(envelope: envelope, for: peer)
        }
    }

    /// One sealed copy of a 1:1 message. `deviceID` rides the wire as
    /// `to_device_id`; nil means "whichever device gets there first", the
    /// only thing an island or a peer from before per-device sessions knows.
    struct SealedCopy {
        let deviceID: Int?
        let payload: String
    }

    /// The sealed copies of one envelope plus whether they cover EVERY install
    /// the recipient runs. A device we could not seal to is a device that will
    /// never see this message, and a send that reports "delivered" over it is
    /// the same silent loss as not sending at all — only harder to notice.
    struct SealedFanout {
        let copies: [SealedCopy]
        let complete: Bool
    }

    /// `to_device_id` is OMITTED rather than sent as null when there is no
    /// device to name — synthesised Encodable does that for an optional, and
    /// an island that predates per-device addressing has never seen the key.
    private struct SealedSendBody: Encodable {
        let to_uin: Int
        let envelope_type: String
        let payload: String
        let to_device_id: Int?
    }

    /// Seal a 1:1 envelope once per libsignal device the peer runs.
    ///
    /// A v=2 session belongs to a PAIR of devices, so one ciphertext reaches
    /// exactly one install of the recipient — a peer holding a phone and a
    /// desktop needs two. Every way of not learning the device list (a
    /// v=1-only peer, an island without the endpoint, an empty answer, a
    /// bundle we cannot fetch) lands on exactly the pre-fan-out wire: one
    /// copy, no `to_device_id`.
    private func sealForPeerDevices(
        envelope: Envelope, peer: PeerBundle, peerSignalIdentityKey: String?
    ) async throws -> SealedFanout {
        guard let psk = peerSignalIdentityKey, !psk.isEmpty else {
            return SealedFanout(
                copies: [SealedCopy(deviceID: nil, payload: try crypto.encrypt(envelope: envelope, for: peer))],
                complete: true
            )
        }
        if let devices = await SignalCryptoService.peerDeviceIDs(forPeerUIN: peer.uin) {
            // Who may arm the silence probe at all.
            //
            // ⚠ PEERS only, never ourselves: sendEnvelope short-circuits
            // Saved Messages before this point, but the guard stays — probing
            // one of our OWN installs would re-read a bundle for a device we
            // are not waiting on. And only for an envelope that EARNS an
            // answer; see SilenceProbe.earnsAnswer on why arming on receipts
            // made "armed and never cleared" the steady state on the web.
            let probePeer = peer.uin != ownUIN && SilenceProbe.earnsAnswer(envelope)
            var copies: [SealedCopy] = []
            for d in devices where (1...127).contains(d) {
                // The silence probe: a device that has answered NOTHING for
                // two minutes of active sending gets its published identity
                // re-checked, and its session rebuilt only if the identity
                // behind it CHANGED (probeSession explains why a blind
                // rebuild loses messages). Throttled per device, so a quiet
                // peer costs one free comparison every half hour and nothing
                // else.
                if probePeer, SilenceProbe.shared.probeDue(uin: peer.uin, deviceId: d) {
                    let result = await SignalCryptoService.probeSession(forPeerUIN: peer.uin, deviceId: d)
                    // The throttle is spent on a probe that actually READ
                    // something. An unreachable island must not buy the peer
                    // half an hour of not being checked.
                    if result != .unreachable {
                        SilenceProbe.shared.noteProbeRan(uin: peer.uin, deviceId: d)
                    }
                    if result == .rebuilt {
                        SilenceProbe.shared.noteRebuilt(uin: peer.uin, deviceId: d)
                    }
                }
                do {
                    try await SignalCryptoService.ensureStage3Session(forPeerUIN: peer.uin, deviceId: UInt32(d))
                    copies.append(SealedCopy(
                        deviceID: d,
                        payload: try crypto.encryptStage3(envelope: envelope, for: peer, deviceId: UInt32(d))
                    ))
                    // Armed AFTER a successful seal: from here this device
                    // owes us a receipt, and hearing nothing for long enough
                    // is what makes the probe worth running.
                    if probePeer { SilenceProbe.shared.arm(uin: peer.uin, deviceId: d) }
                } catch {
                    print("[MessageService] Stage 3 encrypt for \(peer.uin)/\(d) failed (\(error))")
                }
            }
            if !copies.isEmpty {
                // A device id the list carried but libsignal cannot address
                // (outside 1...127) is a device we skipped just as surely as
                // one whose session we could not build, so the count of
                // copies is measured against the WHOLE list.
                if copies.count != devices.count {
                    print("[MessageService] fan-out to \(peer.uin) covers \(copies.count) of \(devices.count) devices")
                }
                return SealedFanout(copies: copies, complete: copies.count == devices.count)
            }
        }
        return SealedFanout(
            copies: [SealedCopy(
                deviceID: nil,
                payload: try await encryptForPeer(
                    envelope: envelope, peer: peer, peerSignalIdentityKey: peerSignalIdentityKey
                )
            )],
            complete: true
        )
    }

    func sendGroupEnvelope(_ envelope: Envelope, to snapshot: RCQGroup, localID: UUID?) async throws {
        // Same rule as the 1:1 path above: a duress session sends nothing and
        // shows no failure for it. A seeded decoy has no groups today, so this
        // is unreachable — and it is here anyway, because "the decoy has no
        // groups" is a property of the seed, not of this function.
        if PanicPINService.shared.isDecoy {
            if let localID {
                MessageStore.shared.updateState(
                    messageID: localID, thread: .group(id: snapshot.id), state: .sent
                )
            }
            playSentSound(for: envelope)
            return
        }
        // Cross-island group (§5c): seal AS the guest identity (the sender uin
        // must be our per-island uin so the roster resolves it; keys identical)
        // and deposit to the group's island. Handled on its own path.
        if let host = snapshot.host, let ref = VisitedIslandsStore.shared.refByAlias(snapshot.id),
           let creds = CrossIslandGroups.foreignCreds(host: host, ownUIN: AuthService.shared.ownUIN) {
            try await sendForeignGroupEnvelope(envelope, to: snapshot, remoteId: ref.remoteId,
                                               host: host, guestUIN: creds.uin, localID: localID)
            return
        }
        // ⚠ The roster, not whatever roster the caller happened to be holding.
        // The chat list is fetched without one, so the group handed to us can
        // legitimately have an empty member list — every branch below fans out
        // per recipient, and an empty list means a message that is delivered to
        // nobody while every local signal says it was sent.
        let group = await GroupService.shared.ensureRoster(snapshot.id) ?? snapshot
        struct Entry: Encodable { let to_uin: Int; let payload: String }
        struct Body: Encodable { let group_id: Int; let envelope_type: String; let payloads: [Entry] }
        struct BroadcastBody: Encodable { let group_id: Int; let envelope_type: String; let payload: String }
        struct Out: Decodable { let delivered: Bool; let queued: Bool }

        let envType = envelopeType(for: envelope)
        // owner_only (broadcast) MESSAGE posts attach our token so the server
        // can verify we're the owner (sealed sender hides nothing here — every
        // post is the owner's). Reactions/edits and all 'all'-group sends stay
        // anonymous to preserve sealed sender.
        let authPost = group.postPolicy == "owner_only" && envType == "message"

        func legacySeal(_ member: RCQGroupMember) async -> Entry? {
            let bundle = PeerBundle(uin: member.uin, identityKey: member.identityKey, signingKey: member.signingKey)
            // Groups ALWAYS use v=1 sealed-sender (stateless ECIES); the v=2
            // ratchet desynced across the per-recipient fan-out. nil routes v=1.
            guard let blob = try? await encryptForPeer(envelope: envelope, peer: bundle, peerSignalIdentityKey: nil)
            else { print("[MessageService] encrypt for \(member.uin) failed"); return nil }
            return Entry(to_uin: member.uin, payload: blob)
        }

        let sendable = group.members.filter { $0.uin != ownUIN && !$0.identityKey.isEmpty }
        // Sender keys (encrypt-once) for any capable member. Foreign groups keep
        // the legacy path (their capability lookup + broadcast endpoint live on
        // the foreign island) — but this method's foreign case already returned
        // above, so here `group.host == nil`.
        let capable = sendable.filter { $0.senderKeys }

        do {
            let out: Out
            if !capable.isEmpty {
                let step = GroupSenderKeyStore.shared.prepareOwnSend(ownUin: ownUIN, gid: group.id, capableUins: capable.map { $0.uin })
                let gmsg = try crypto.sealGmsg(envelope: envelope, gid: group.id, kid: step.kid, epoch: step.epoch, index: step.index, mk: step.mk)
                // Distribute the chain key to capable members who need it FIRST,
                // so a recipient never gets a gmsg for an unknown kid.
                let skdmTargets = capable.filter { step.needDistribution.contains($0.uin) }
                if !skdmTargets.isEmpty {
                    let skdmEnv: Envelope = .skdm(gid: group.id, kid: step.kid, epoch: step.epoch, index: step.index, ck: step.ckAtI)
                    var skdmEntries: [Entry] = []
                    for m in skdmTargets {
                        let bundle = PeerBundle(uin: m.uin, identityKey: m.identityKey, signingKey: m.signingKey)
                        if let blob = try? crypto.encrypt(envelope: skdmEnv, for: bundle) { skdmEntries.append(Entry(to_uin: m.uin, payload: blob)) }
                    }
                    if !skdmEntries.isEmpty {
                        let _: Out = try await APIClient.shared.request("POST", "/messages/group-sealed",
                            body: Body(group_id: group.id, envelope_type: "skdm", payloads: skdmEntries), authenticated: false, retries: 1)
                    }
                }
                out = try await APIClient.shared.request("POST", "/messages/group-broadcast",
                    body: BroadcastBody(group_id: group.id, envelope_type: envType, payload: gmsg), authenticated: true, retries: 2)
                GroupSenderKeyStore.shared.markDistributed(ownUin: ownUIN, gid: group.id, uins: skdmTargets.map { $0.uin })
                GroupSenderKeyStore.shared.advanceOwn(ownUin: ownUIN, gid: group.id)
                // Legacy members (not yet updated) still get their per-member copy.
                let legacy = sendable.filter { !$0.senderKeys }
                if !legacy.isEmpty {
                    var legacyEntries: [Entry] = []
                    for m in legacy { if let e = await legacySeal(m) { legacyEntries.append(e) } }
                    if !legacyEntries.isEmpty {
                        let _: Out = try await APIClient.shared.request("POST", "/messages/group-sealed",
                            body: Body(group_id: group.id, envelope_type: envType, payloads: legacyEntries), authenticated: authPost, retries: 1)
                    }
                }
            } else {
                // No capable member: original per-member fan-out.
                var entries: [Entry] = []
                await withTaskGroup(of: Entry?.self) { tg in
                    for m in sendable { tg.addTask { await legacySeal(m) } }
                    for await r in tg { if let r { entries.append(r) } }
                }
                out = try await APIClient.shared.request("POST", "/messages/group-sealed",
                    body: Body(group_id: group.id, envelope_type: envType, payloads: entries), authenticated: authPost, retries: 2)
            }
            if let localID {
                let next: DeliveryState = out.delivered ? .delivered : .sent
                MessageStore.shared.updateState(messageID: localID, thread: .group(id: group.id), state: next)
            }
            playSentSound(for: envelope)
            // Mirror the message to the user's other devices (best-effort).
            await sendMessageCarbon(envelope, toPeer: nil, toGroup: group.id)
        } catch {
            if let localID {
                MessageStore.shared.updateState(messageID: localID, thread: .group(id: group.id), state: .failed)
            }
            throw error
        }
    }

    // MARK: - sender-keys receive helpers

    /// Decode a `gmsg` broadcast via the stored chain. Returns the inner
    /// envelope + real sender, or nil when the message is mine (carbon handles
    /// it), a replay, unverifiable, or pending an SKDM (a NACK is fired then).
    private func openIncomingGmsg(_ payloadB64: String, gid: Int) -> DecryptedEnvelope? {
        guard let hdr = SenderKeys.parseGmsgHeader(payloadB64) else { return nil }
        if GroupSenderKeyStore.shared.ownsKid(hdr.kid) { return nil } // my own echoed broadcast
        guard let key = GroupSenderKeyStore.shared.deriveInbound(ownUin: ownUIN, kid: hdr.kid, epoch: hdr.epoch, index: hdr.index) else {
            if !GroupSenderKeyStore.shared.knowsKid(ownUin: ownUIN, hdr.kid) { sendSknack(gid: gid, kid: hdr.kid) }
            return nil
        }
        guard let opened = SenderKeys.openGmsg(payloadB64, gid: gid, mk: key.mk, expectedSpubB64: key.spub) else { return nil }
        guard opened.verified else {
            print("[MessageService] gmsg sig did not verify; dropping gid=\(gid) kid=\(hdr.kid)")
            return nil
        }
        return DecryptedEnvelope(senderUIN: key.senderUin, envelope: opened.envelope)
    }

    private static var lastSknack: [String: Date] = [:]

    /// Fire one recovery request for an unknown kid to the group's capable
    /// members (we don't know whose kid it is). Debounced per kid.
    private func sendSknack(gid: Int, kid: String) {
        if let prev = Self.lastSknack[kid], Date().timeIntervalSince(prev) < 600 { return }
        Self.lastSknack[kid] = Date()
        struct Entry: Encodable { let to_uin: Int; let payload: String }
        struct Body: Encodable { let group_id: Int; let envelope_type: String; let payloads: [Entry] }
        struct Out: Decodable { let delivered: Bool; let queued: Bool }
        let env: Envelope = .sknack(gid: gid, kid: kid)
        Task {
            // Per-recipient again, so the roster has to be real: with an empty
            // one this asks nobody for the key and the group stays unreadable.
            guard let group = await GroupService.shared.ensureRoster(gid) else { return }
            let targets = group.members.filter { $0.senderKeys && $0.uin != ownUIN && !$0.identityKey.isEmpty }
            var entries: [Entry] = []
            for m in targets {
                let bundle = PeerBundle(uin: m.uin, identityKey: m.identityKey, signingKey: m.signingKey)
                if let blob = try? crypto.encrypt(envelope: env, for: bundle) { entries.append(Entry(to_uin: m.uin, payload: blob)) }
            }
            guard !entries.isEmpty else { return }
            let _: Out? = try? await APIClient.shared.request("POST", "/messages/group-sealed",
                body: Body(group_id: gid, envelope_type: "sknack", payloads: entries), authenticated: false, retries: 0)
        }
    }

    /// Answer a recovery request: if I own this group's chain, re-seal a current
    /// SKDM to the requester so they can read going forward.
    private func answerSknack(gid: Int, requesterUIN: Int, kid: String) {
        guard GroupSenderKeyStore.shared.ownKidForGroup(ownUin: ownUIN, gid: gid) == kid,
              let snap = GroupSenderKeyStore.shared.ownChainSnapshot(ownUin: ownUIN, gid: gid) else { return }
        struct Entry: Encodable { let to_uin: Int; let payload: String }
        struct Body: Encodable { let group_id: Int; let envelope_type: String; let payloads: [Entry] }
        struct Out: Decodable { let delivered: Bool; let queued: Bool }
        let env: Envelope = .skdm(gid: gid, kid: snap.kid, epoch: snap.epoch, index: snap.index, ck: snap.ck)
        Task {
            // The requester's key comes out of the roster, so ask for one first:
            // without it nobody is ever found and the request goes unanswered.
            guard let group = await GroupService.shared.ensureRoster(gid),
                  let m = group.members.first(where: { $0.uin == requesterUIN }),
                  !m.identityKey.isEmpty else { return }
            let bundle = PeerBundle(uin: m.uin, identityKey: m.identityKey, signingKey: m.signingKey)
            guard let blob = try? crypto.encrypt(envelope: env, for: bundle) else { return }
            let _: Out? = try? await APIClient.shared.request("POST", "/messages/group-sealed",
                body: Body(group_id: gid, envelope_type: "skdm", payloads: [Entry(to_uin: m.uin, payload: blob)]), authenticated: false, retries: 0)
        }
    }

    /// §5c cross-island group send: seal per-member AS the guest identity
    /// (`fromUIN`/`fromHost` = our per-island uin + the group's island) and
    /// deposit to the group's island. No carbon (the carbon would carry the
    /// server-side group id, which another of our devices would misread as a
    /// LOCAL group — alias maps are per-device).
    private func sendForeignGroupEnvelope(
        _ envelope: Envelope, to group: RCQGroup, remoteId: Int,
        host: String, guestUIN: Int, localID: UUID?
    ) async throws {
        let recipients = group.members.filter { $0.uin != guestUIN && !$0.identityKey.isEmpty }
        let entries: [CrossIslandGroups.GroupEntry] = recipients.compactMap { member in
            let bundle = PeerBundle(uin: member.uin, identityKey: member.identityKey, signingKey: member.signingKey)
            guard let blob = try? crypto.encrypt(envelope: envelope, for: bundle, fromUIN: guestUIN, fromHost: host) else { return nil }
            return CrossIslandGroups.GroupEntry(to_uin: member.uin, payload: blob)
        }
        do {
            try await CrossIslandGroups.groupSealedDeposit(
                host: host, remoteId: remoteId, envelopeType: envelopeType(for: envelope), payloads: entries
            )
            if let localID {
                MessageStore.shared.updateState(messageID: localID, thread: .group(id: group.id), state: .sent)
            }
            playSentSound(for: envelope)
        } catch {
            if let localID {
                MessageStore.shared.updateState(messageID: localID, thread: .group(id: group.id), state: .failed)
            }
            throw error
        }
    }

    /// Advertise this client's capabilities (fire-and-forget at boot).
    func advertiseSenderKeysCapability() async {
        struct Body: Encodable { let sender_keys: Bool }
        let _: EmptyResponse? = try? await APIClient.shared.request("POST", "/users/me/capabilities", body: Body(sender_keys: true), authenticated: true)
    }

    private func envelopeType(for envelope: Envelope) -> String {
        switch envelope {
        case .deleteForEveryone: return "delete"
        case .systemNotice: return "system"
        case .readReceipt: return "read"
        // ⚠ Labelled "read" on the OUTER envelope on purpose, not a new type.
        // The outer label decides whether the island pushes (it does not for
        // "read") and whether a client routes the packet live at all. A brand
        // new label would be routed by nobody until every client in the field
        // updated — which for a receipt means the tick stays broken exactly for
        // the people running the oldest builds. The INNER kind carries the
        // meaning.
        case .deliveredReceipt: return "read"
        case .reaction: return "reaction"
        case .bounce: return "bounce"
        case .visit: return "visit"
        case .edit: return "edit"
        case .secureScreen, .screenshotTaken: return "secscreen"
        default: return "message"
        }
    }

    // MARK: - profile visits

    private var lastVisitFiredAt: [Int: Date] = [:]
    private static let visitThrottle: TimeInterval = 60 * 60

    /// Fire-and-forget visit ping. Throttled per (session, target).
    func sendVisit(toUIN targetUIN: Int, identityKey: String, signingKey: String, signalIdentityKey: String? = nil) async {
        guard targetUIN != ownUIN else { return }
        if let last = lastVisitFiredAt[targetUIN],
           Date().timeIntervalSince(last) < Self.visitThrottle {
            return
        }
        lastVisitFiredAt[targetUIN] = Date()

        let bundle = PeerBundle(uin: targetUIN, identityKey: identityKey, signingKey: signingKey)
        do {
            // Completeness is not tracked here: a visit ping has no tick to be
            // wrong about, and one install of the peer hearing it is the whole
            // point of the envelope.
            let fanout = try await sealForPeerDevices(
                envelope: .visit(at: Date()),
                peer: bundle,
                peerSignalIdentityKey: signalIdentityKey
            )
            struct Out: Decodable { let delivered: Bool; let queued: Bool }
            var accepted = false
            for copy in fanout.copies {
                let out: Out? = try? await APIClient.shared.request(
                    "POST", "/messages/sealed",
                    body: SealedSendBody(
                        to_uin: targetUIN, envelope_type: "visit",
                        payload: copy.payload, to_device_id: copy.deviceID
                    ),
                    authenticated: false
                )
                if out != nil { accepted = true }
            }
            // Re-arm the throttle only when nothing landed — a retry that
            // re-fires the copies that DID land would double-count the visit.
            if !accepted { lastVisitFiredAt[targetUIN] = nil }
        } catch {
            lastVisitFiredAt[targetUIN] = nil
        }
    }

    /// Inverts wire `authorName` for random chat: sender's "You" = receiver's "Stranger".
    /// Falls back to wire value if parent is gone.
    @MainActor
    static func resolveRandomReplyAuthor(reply: ReplyContext?) -> String? {
        guard let reply else { return nil }
        let ownUIN = AuthService.shared.ownUIN ?? -1
        if let parent = RandomChatService.shared.messages.first(where: { $0.id == reply.id }) {
            return parent.senderUIN == ownUIN
                ? "chat.random.you".localized
                : "chat.random.stranger".localized
        }
        return reply.authorName
    }

    static func messageID(in envelope: Envelope) -> UUID? {
        switch envelope {
        case .text(let id, _, _, _, _): return id
        case .photo(let id, _, _, _, _, _, _, _, _): return id
        case .video(let id, _, _, _, _, _, _, _, _, _, _): return id
        case .voice(let id, _, _, _, _, _, _): return id
        case .systemNotice(let id, _): return id
        case .poll(let id, _, _, _, _, _): return id
        case .relayShare(let id, _, _): return id
        default: return nil
        }
    }

    func playSentSound(for envelope: Envelope) {
        switch envelope {
        case .text, .photo, .voice, .poll: SoundService.shared.play(.messageSent)
        default: break
        }
    }

    // MARK: - ingest

    struct IngestOutcome {
        let thread: ThreadID
        /// True only for brand-new content; false for dedup, control envelopes, visits.
        let isNewContent: Bool
        /// True when the NSE already decrypted this envelope and pre-
        /// populated `PushDecryptCache`. The fetch-queue caller uses
        /// this to skip a second app-icon badge bump — NSE already
        /// did it in the extension process.
        let wasInNSECache: Bool
    }

    /// A short plaintext preview of a quarantined cross-island request message.
    static func requestPreview(for env: Envelope) -> String {
        switch env {
        case .text(_, let text, _, _, _): return text
        case .photo(_, _, _, let caption, _, _, _, _, _): return caption?.isEmpty == false ? caption! : "📷"
        case .video(_, _, _, _, _, let caption, _, _, _, _, _): return caption?.isEmpty == false ? caption! : "🎬"
        case .voice: return "🎤"
        case .file(_, _, _, let fname, _, _, _, _, _, _): return "📎 \(fname)"
        case .location: return "📍"
        default: return ""
        }
    }

    /// §5d/§5e/§5f arrive with no host: KEEP THE ROW, don't ACK it.
    ///
    /// The sender's island is the whole identity of a cross-island peer, and a
    /// control envelope that reaches a gate without one can only be dropped —
    /// guessing by bare uin is how a lookalike on another island gets to rename
    /// or ring someone. The bug was what happened NEXT: these branches returned
    /// a non-nil outcome, `fetchOfflineQueue` read that as "persisted", ACKed
    /// the row, and the island deleted the only copy. A missed call, a rejected
    /// contact request and a stale name, all unrecoverable, from one nil.
    ///
    /// Returning nil leaves the row queued so a later drain (with the host
    /// present) can act on it, and re-stashing the plaintext means the retry
    /// isn't blocked by a v=2 ratchet this decrypt already stepped. The row
    /// expires with the queue TTL if the sender really never sends `from_host`.
    private func requeueHostlessControl(
        _ ws: WebSocketService.EnvelopePacket,
        _ decrypted: DecryptedEnvelope,
        kind: String
    ) -> IngestOutcome? {
        os_log(
            "ingest: %{public}@ envelope from #%d has no from_host — NOT acking, leaving it queued",
            log: Self.log, type: .error, kind, decrypted.senderUIN
        )
        PushDecryptCache.store(ciphertextB64: ws.payload, decrypted: decrypted)
        return nil
    }

    /// `nil` = drop silently (decrypt failed, blocked sender, random-routed, or visit).
    @discardableResult
    func ingest(envelope ws: WebSocketService.EnvelopePacket) -> IngestOutcome? {
        var decryptError: Error?
        return ingest(envelope: ws, decryptError: &decryptError)
    }

    /// `decryptError` separates "we could not open it" from "we opened it
    /// and chose not to keep it", and says WHY when it is the former. The
    /// offline queue needs both: a deliberate drop can still be worth
    /// redelivering (a cross-island control envelope waiting for its
    /// `from_host`), and among the failures only some are final — see
    /// `isUnreadableHere`.
    @discardableResult
    func ingest(envelope ws: WebSocketService.EnvelopePacket, decryptError: inout Error?) -> IngestOutcome? {
        // A fan-out copy sealed for another install of this account. Live
        // delivery is not filtered server-side, so every socket of the
        // account sees every copy; only one of them can open this.
        if let to = ws.toDeviceID, to != SignalProtocolStores.shared.localDeviceId { return nil }
        do {
            // Hand off NSE-decrypted plaintext if present — decrypting v=2
            // twice would advance the Double Ratchet twice and fail.
            let decrypted: DecryptedEnvelope
            let fromNSE: Bool
            if ws.type == "gmsg" {
                // Sender-keys broadcast: not a sealed envelope — decode via the chain.
                guard let gid = ws.groupID, let opened = openIncomingGmsg(ws.payload, gid: gid) else { return nil }
                decrypted = opened
                fromNSE = false
            } else if let cached = PushDecryptCache.consume(ciphertextB64: ws.payload) {
                decrypted = cached
                fromNSE = true
            } else {
                decrypted = try crypto.decrypt(envelopeB64: ws.payload)
                fromNSE = false
            }
            let thread: ThreadID = ws.groupID.map { .group(id: $0) } ?? .peer(uin: decrypted.senderUIN)

            // Any decrypted envelope naming its device — a message, a receipt,
            // anything — proves that install can talk to us: its silence probe
            // stands down. Both delivery paths (live socket, queue drain) and
            // the NSE hand-off all come through here, so this is the one place
            // to listen. v=1 carries no device id and clears nothing.
            if let dev = decrypted.senderDeviceID, decrypted.senderUIN != ownUIN {
                SilenceProbe.shared.noteInbound(uin: decrypted.senderUIN, deviceId: dev)
            }

            // Sender-keys distribution / recovery (never rendered). SKDM binds
            // the chain to its authenticated sender; SKNACK asks the kid owner to
            // re-distribute. Both ride the per-member sealed path.
            if case .skdm(let gid, let kid, let epoch, let index, let ck) = decrypted.envelope {
                if let sk = decrypted.senderSigningKey {
                    GroupSenderKeyStore.shared.acceptSkdm(ownUin: ownUIN, kid: kid, gid: gid, senderUIN: decrypted.senderUIN, spub: sk, epoch: epoch, index: index, ck: ck)
                }
                return IngestOutcome(thread: thread, isNewContent: false, wasInNSECache: fromNSE)
            }
            if case .sknack(let gid, let kid) = decrypted.envelope {
                answerSknack(gid: ws.groupID ?? gid, requesterUIN: decrypted.senderUIN, kid: kid)
                return IngestOutcome(thread: thread, isNewContent: false, wasInNSECache: fromNSE)
            }

            // Multi-device carbon: a message I sent from ANOTHER device, echoed
            // to my own uin. Unwrap and file the inner message as fromMe in its
            // destination thread (NOT the sender-derived Saved-Messages thread).
            // Only honour a carbon actually signed by me; dedup by the inner id
            // (the origin device no-ops its own carbon). Never a banner/badge —
            // it's my own message — but return a non-nil outcome so the offline
            // queue acks it instead of redelivering forever.
            if case .carbon(let cTo, let cGid, let inner) = decrypted.envelope {
                guard decrypted.senderUIN == ownUIN else { return nil }
                let dest: ThreadID? = cGid.map { .group(id: $0) } ?? cTo.map { .peer(uin: $0) }
                guard let dest else { return nil }
                appendCarbonMessage(inner: inner, thread: dest, serverTime: ws.serverTime)
                return IngestOutcome(thread: dest, isNewContent: false, wasInNSECache: fromNSE)
            }

            // §5d cross-island call signaling rides sealed envelopes (kind
            // "call") — route to the call state machine, never the message
            // store, and never the request quarantine (signals are ephemeral).
            // Only an ACCEPTED cross-island contact may ring us; a stale offer
            // (old `ts` — offline-queue drains deliver hours-old rows) files a
            // missed-call row instead of ringing. ACK every branch so the
            // queue stops redelivering.
            if case .callSignal(_, let sig, let cid, let ts, let data) = decrypted.envelope {
                let outcome = IngestOutcome(thread: thread, isNewContent: false, wasInNSECache: fromNSE)
                guard ws.groupID == nil else { return outcome }
                // No host = we cannot tell whose call this is. Re-deliverable,
                // never acked — see `requeueHostlessControl`.
                guard let fromHost = decrypted.senderHost else {
                    return requeueHostlessControl(ws, decrypted, kind: "call")
                }
                guard !Multihome.isOwnHost(fromHost),
                      CrossIslandStore.shared.all().contains(where: { $0.uin == decrypted.senderUIN && $0.host == fromHost })
                else { return outcome }
                if sig == "call_offer", Int(Date().timeIntervalSince1970) - ts > 60 {
                    CallService.shared.fileMissedCall(
                        fromUIN: decrypted.senderUIN,
                        fromHost: fromHost,
                        media: CallMedia(rawValue: data["media"] ?? "video") ?? .video
                    )
                    return outcome
                }
                CallService.shared.handleCrossIslandSignal(sig: sig, fromUIN: decrypted.senderUIN, callID: cid, data: data)
                return outcome
            }

            // §5f cross-island CONTACT REQUEST (kind "contactreq"). Adding a peer
            // on another island used to be purely local — nothing was deposited
            // and the peer was never told, which is why a QR scan claimed a
            // request nobody would ever see and why §5d's mutual-accept gate was
            // unreachable through the ordinary flow. This branch is the receive
            // half: it files a PENDING request where a same-island pending
            // request appears, and NEVER writes to the message store or the
            // quarantine below. ACK every branch so the queue stops redelivering.
            if case .contactRequest(_, let act, _, let nickname, let note) = decrypted.envelope {
                let outcome = IngestOutcome(thread: thread, isNewContent: false, wasInNSECache: fromNSE)
                guard ws.groupID == nil, decrypted.senderUIN != ownUIN else { return outcome }
                guard let fromHost = decrypted.senderHost else {
                    return requeueHostlessControl(ws, decrypted, kind: "contactreq")
                }
                guard !Multihome.isOwnHost(fromHost) else { return outcome }
                let uin = decrypted.senderUIN
                // Same-island rule, unchanged: a blocked or removed sender's
                // request is dropped silently.
                if BlockedContactsStore.shared.contains(uin)
                    || RemovedContactsStore.shared.contains(uin)
                    || CrossIslandRequestsStore.shared.isBlocked(uin: uin, host: fromHost) {
                    return outcome
                }
                let alreadyAccepted = CrossIslandStore.shared.all()
                    .contains { $0.uin == uin && $0.host == fromHost }
                switch act {
                case "request":
                    // Already accepted → no-op, not a second row.
                    if alreadyAccepted { return outcome }
                    CrossIslandRequestsStore.shared.holdContactRequest(
                        uin: uin, host: fromHost, nickname: nickname, note: note
                    )
                case "accept":
                    // They accepted the request we sent: we already hold their
                    // row (the add wrote it, which is what "we asked them" means
                    // on every client), so both sides now hold each other — the
                    // mutual state §5d checks and §5e addresses. Nothing to
                    // write; just retire any pending row.
                    if alreadyAccepted {
                        CrossIslandRequestsStore.shared.clear(uin: uin, host: fromHost)
                        // §5e first-contact push: the relationship just became
                        // mutual, so hand them our CURRENT name and picture
                        // instead of leaving them with the card snapshot their
                        // add took.
                        if let row = CrossIslandStore.shared.all()
                            .first(where: { $0.uin == uin && $0.host == fromHost }) {
                            Task { await CrossIslandSender.sendProfile(to: row) }
                        }
                        return outcome
                    }
                    // An `accept` from someone we never asked is NOT a licence
                    // to add them: auto-adding here let any stranger self-add
                    // with one envelope, skipping the whole consent step §5f
                    // exists to create (and, once in the roster, their messages
                    // skip the Variant A quarantine and §5d lets them call).
                    // Degrade it to a pending row the user decides on — which is
                    // also what web does, so the same envelope now means the
                    // same thing on all three clients.
                    CrossIslandRequestsStore.shared.holdContactRequest(
                        uin: uin, host: fromHost, nickname: nickname, note: note
                    )
                case "decline":
                    // Drop our local pending row for them, silently. The pinned
                    // keys and the local contact row are left alone.
                    CrossIslandRequestsStore.shared.clear(uin: uin, host: fromHost)
                default:
                    break
                }
                return outcome
            }

            // §5e cross-island PROFILE REFRESH (kind "profile"). A cross-island
            // contact's name and picture were read exactly once, off their open
            // key card, when they were added — and never again, because the
            // same-island `contact_renamed` broadcast has no way to include a
            // holder on another island. This branch applies the push that
            // replaces it, and applies NOTHING else: display fields on a row we
            // already hold, never the pinned keys, never a new row, never the
            // message store or the quarantine below. ACK every branch so the
            // queue stops redelivering.
            if case .profile(_, let ts, let nickname, let avatarID, let avatarKey) = decrypted.envelope {
                let outcome = IngestOutcome(thread: thread, isNewContent: false, wasInNSECache: fromNSE)
                // The host is the whole identity of a cross-island row.
                // Guessing (bare uin, "the only row with this uin") is exactly
                // how a lookalike on another island gets to rename someone, so
                // an unknown host still applies NOTHING — it just no longer
                // ACKs the row away. (`PushDecryptCache` carries `from_host`
                // since 2026-08-15, so the push path reaches here with a host.)
                guard ws.groupID == nil, decrypted.senderUIN != ownUIN else { return outcome }
                guard let fromHost = decrypted.senderHost else {
                    return requeueHostlessControl(ws, decrypted, kind: "profile")
                }
                guard !Multihome.isOwnHost(fromHost) else { return outcome }
                let uin = decrypted.senderUIN
                if BlockedContactsStore.shared.contains(uin)
                    || RemovedContactsStore.shared.contains(uin) {
                    return outcome
                }
                // Drops (returns nil) for a sender we do not hold as an accepted
                // cross-island contact, and for a `ts` older than the last one we
                // applied. Persists to the App Group container, which is what the
                // push path reads without a live session.
                guard let updated = CrossIslandStore.shared.applyProfile(
                    uin: uin, host: fromHost, ts: ts,
                    nickname: nickname, avatarMediaID: avatarID, avatarMediaKey: avatarKey
                ) else { return outcome }
                ContactService.shared.applyCrossIslandProfile(updated)
                return outcome
            }

            // Federation gossip B1 self-push: a contact handed us their fresh
            // signed home-island record. Verify it's signed by the SAME key that
            // signed this envelope (binds it to the real sender), reject a ts
            // rollback, cache their homes. Never reaches the store/quarantine.
            if case .homeRecord(let rec) = decrypted.envelope {
                if let sk = decrypted.senderSigningKey {
                    Multihome.applyPushedRecord(senderUIN: decrypted.senderUIN, senderSigningKey: sk, rec: rec)
                }
                return IngestOutcome(thread: thread, isNewContent: false, wasInNSECache: fromNSE)
            }

            // Variant A consent: a 1:1 message from an un-accepted CROSS-ISLAND
            // sender (its `from_host` isn't ours and we haven't added them) is
            // QUARANTINED as a "message request" instead of landing in the chat
            // list. Accepted → normal flow. Blocked → hold() no-ops but we still
            // ACK so the queue stops redelivering.
            if ws.groupID == nil, let fromHost = decrypted.senderHost,
               !Multihome.isOwnHost(fromHost), decrypted.senderUIN != ownUIN,
               !CrossIslandStore.shared.all().contains(where: { $0.uin == decrypted.senderUIN && $0.host == fromHost }) {
                CrossIslandRequestsStore.shared.hold(
                    uin: decrypted.senderUIN, host: fromHost,
                    payload: ws.payload, preview: Self.requestPreview(for: decrypted.envelope)
                )
                return IngestOutcome(thread: thread, isNewContent: false, wasInNSECache: fromNSE)
            }

            // Route to ephemeral random buffer when sender is the active anonymous peer.
            if ws.groupID == nil,
               let peer = RandomChatService.shared.activePeer,
               decrypted.senderUIN == peer.uin {
                switch decrypted.envelope {
                case .text(let id, let text, _, _, let reply):
                    let m = Message(
                        id: id,
                        thread: .peer(uin: peer.uin),
                        senderUIN: peer.uin,
                        isFromMe: false,
                        kind: .text, text: text,
                        sentAt: ws.serverTime,
                        deliveryState: .delivered,
                        replyToID: reply?.id,
                        replyToSnippet: reply?.snippet,
                        replyToAuthorName: Self.resolveRandomReplyAuthor(reply: reply)
                    )
                    RandomChatService.shared.append(m)
                    SoundService.shared.play(.messageIncoming)
                case .photo(let id, let mediaID, let mediaKey, let caption, _, _, let reply, let album, let spoiler):
                    let m = Message(
                        id: id,
                        thread: .peer(uin: peer.uin),
                        senderUIN: peer.uin,
                        isFromMe: false,
                        kind: .photo, text: caption ?? "",
                        mediaID: mediaID + "|" + mediaKey,
                        sentAt: ws.serverTime,
                        deliveryState: .delivered,
                        replyToID: reply?.id,
                        replyToSnippet: reply?.snippet,
                        replyToAuthorName: Self.resolveRandomReplyAuthor(reply: reply),
                        albumID: album,
                        isSpoiler: spoiler
                    )
                    RandomChatService.shared.append(m)
                    SoundService.shared.play(.messageIncoming)
                case .video(let id, let mediaID, let mediaKey, let thumb, let dur, let caption, _, _, let reply, let album, let spoiler):
                    let m = Message(
                        id: id,
                        thread: .peer(uin: peer.uin),
                        senderUIN: peer.uin,
                        isFromMe: false,
                        kind: .video, text: caption ?? "",
                        mediaID: mediaID + "|" + mediaKey,
                        sentAt: ws.serverTime,
                        deliveryState: .delivered,
                        thumbnailB64: thumb,
                        durationSec: dur,
                        replyToID: reply?.id,
                        replyToSnippet: reply?.snippet,
                        replyToAuthorName: Self.resolveRandomReplyAuthor(reply: reply),
                        albumID: album,
                        isSpoiler: spoiler
                    )
                    RandomChatService.shared.append(m)
                    SoundService.shared.play(.messageIncoming)
                case .voice(let id, let mediaID, let mediaKey, let dur, _, _, let reply):
                    let m = Message(
                        id: id,
                        thread: .peer(uin: peer.uin),
                        senderUIN: peer.uin,
                        isFromMe: false,
                        kind: .voice, text: "",
                        mediaID: mediaID + "|" + mediaKey,
                        sentAt: ws.serverTime,
                        deliveryState: .delivered,
                        durationSec: dur,
                        replyToID: reply?.id,
                        replyToSnippet: reply?.snippet,
                        replyToAuthorName: Self.resolveRandomReplyAuthor(reply: reply)
                    )
                    RandomChatService.shared.append(m)
                    SoundService.shared.play(.messageIncoming)
                case .file(let id, let mediaID, let mediaKey, let fname, let mime, let size, let caption, _, _, let reply):
                    let m = Message(
                        id: id,
                        thread: .peer(uin: peer.uin),
                        senderUIN: peer.uin,
                        isFromMe: false,
                        kind: .file, text: caption ?? "",
                        mediaID: mediaID + "|" + mediaKey,
                        sentAt: ws.serverTime,
                        deliveryState: .delivered,
                        replyToID: reply?.id,
                        replyToSnippet: reply?.snippet,
                        replyToAuthorName: Self.resolveRandomReplyAuthor(reply: reply),
                        fileName: fname,
                        fileMime: mime,
                        fileSizeBytes: size
                    )
                    RandomChatService.shared.append(m)
                    SoundService.shared.play(.messageIncoming)
                case .location(let id, let lat, let lng, let caption, _, _, let reply):
                    let m = Message(
                        id: id,
                        thread: .peer(uin: peer.uin),
                        senderUIN: peer.uin,
                        isFromMe: false,
                        kind: .location, text: caption ?? "",
                        sentAt: ws.serverTime,
                        deliveryState: .delivered,
                        replyToID: reply?.id,
                        replyToSnippet: reply?.snippet,
                        replyToAuthorName: Self.resolveRandomReplyAuthor(reply: reply),
                        latitude: lat,
                        longitude: lng
                    )
                    RandomChatService.shared.append(m)
                    SoundService.shared.play(.messageIncoming)
                case .deleteForEveryone(let targetID):
                    RandomChatService.shared.deleteMessage(id: targetID)
                case .reaction(let targetID, let asset):
                    RandomChatService.shared.applyReaction(
                        targetID: targetID, uin: peer.uin, asset: asset
                    )
                default:
                    break
                }
                // ⚠ This used to return nil, which fetchOfflineQueue reads as
                // "ingest failed, do NOT ack" — so the island kept the row and
                // handed it back on every drain. Random chat is v=1, whose
                // decrypt succeeds every time (no ratchet to notice a replay),
                // so there was nothing downstream to catch it either: the same
                // message played the incoming tone and appended another bubble
                // on every reconnect, boot and foreground push. It is handled,
                // so say so.
                return IngestOutcome(thread: thread, isNewContent: false, wasInNSECache: fromNSE)
            }

            // Block-list enforcement is client-side only under sealed sender.
            // The local BlockedContactsStore is the source of truth — it covers
            // strangers / non-contacts and group senders (the server can't block
            // a non-contact and can't filter sealed messages); the server
            // `blocked` contact flag is also honored. Bounce a tombstone for a
            // blocked CONTACT (their bubble flips to .failed); a blocked stranger
            // (no contact row) is just dropped silently. Runs before the 1:1 gate
            // so it covers group messages too.
            let senderContact = ContactService.shared.contacts.first(where: { $0.uin == decrypted.senderUIN })
            let isBlocked = BlockedContactsStore.shared.contains(decrypted.senderUIN) || (senderContact?.blocked ?? false)
            if isBlocked {
                if let messageID = Self.messageID(in: decrypted.envelope), let contact = senderContact {
                    Task { try? await self.sendEnvelope(.bounce(targetID: messageID), to: contact, localID: nil) }
                }
                return nil
            }
            // User removed this contact (ICQ-style mutual delete). Server
            // can't filter sealed messages by sender; we silently drop on
            // ingest so no banner, no sound, no chat-list reappearance.
            if RemovedContactsStore.shared.contains(decrypted.senderUIN) {
                return nil
            }
            // Sealed sender lets anyone-message-anyone. If the sender
            // isn't in our contacts, ingest still stores the message
            // but the chat list is contact-driven and won't render
            // the thread — symptom is "iPhone → sim doesn't arrive"
            // when the recipient had been mutually-removed. Auto-
            // surface the stranger so the thread appears; the user
            // can still block/remove them if it's unwanted.
            // `ws.groupID == nil` gates this to 1:1 — group senders
            // are already resolvable via the group's member list and
            // we don't want to flood the contact list with members
            // of joined groups.
            if ws.groupID == nil,
               senderContact == nil,
               decrypted.senderUIN != ownUIN {
                Task { await ContactService.shared.upsertStranger(uin: decrypted.senderUIN) }
            }

            // TTL precedence: envelope ttl wins, else local thread setting.
            let localTTL = ChatSettingsStore.shared.ttl(for: thread)
            var inserted = false
            switch decrypted.envelope {
            case .text(let id, let text, let envTTL, let fwd, let reply):
                inserted = MessageStore.shared.append(Message(
                    id: id,
                    thread: thread,
                    senderUIN: decrypted.senderUIN,
                    isFromMe: decrypted.senderUIN == ownUIN,
                    kind: .text, text: text,
                    sentAt: ws.serverTime,
                    deliveryState: .delivered,
                    receivedWhileAway: ws.offline,
                    ttlSeconds: envTTL ?? localTTL,
                    forwardedFromName: fwd,
                    replyToID: reply?.id,
                    replyToSnippet: reply?.snippet,
                    replyToAuthorName: reply?.authorName
                ))
                // Home-row @ indicator: group-only, from someone else, when
                // the thread isn't open, and the body mentions us (#uin or
                // @nick). Same gates as the reaction inbox.
                if case .group = thread,
                   decrypted.senderUIN != ownUIN,
                   !MessageBannerService.shared.isViewing(thread),
                   bodyMentionsMe(text) {
                    MentionInboxStore.shared.mark(thread)
                }
            case .photo(let id, let mediaID, let mediaKey, let caption, let envTTL, let fwd, let reply, let album, let spoiler):
                inserted = MessageStore.shared.append(Message(
                    id: id,
                    thread: thread,
                    senderUIN: decrypted.senderUIN,
                    isFromMe: decrypted.senderUIN == ownUIN,
                    kind: .photo, text: caption ?? "",
                    mediaID: mediaID + "|" + mediaKey,
                    sentAt: ws.serverTime,
                    deliveryState: .delivered,
                    receivedWhileAway: ws.offline,
                    ttlSeconds: envTTL ?? localTTL,
                    forwardedFromName: fwd,
                    replyToID: reply?.id,
                    replyToSnippet: reply?.snippet,
                    replyToAuthorName: reply?.authorName,
                    albumID: album,
                    isSpoiler: spoiler
                ))
            case .video(let id, let mediaID, let mediaKey, let thumb, let dur, let caption, let envTTL, let fwd, let reply, let album, let spoiler):
                inserted = MessageStore.shared.append(Message(
                    id: id,
                    thread: thread,
                    senderUIN: decrypted.senderUIN,
                    isFromMe: decrypted.senderUIN == ownUIN,
                    kind: .video, text: caption ?? "",
                    mediaID: mediaID + "|" + mediaKey,
                    sentAt: ws.serverTime,
                    deliveryState: .delivered,
                    receivedWhileAway: ws.offline,
                    thumbnailB64: thumb,
                    durationSec: dur,
                    ttlSeconds: envTTL ?? localTTL,
                    forwardedFromName: fwd,
                    replyToID: reply?.id,
                    replyToSnippet: reply?.snippet,
                    replyToAuthorName: reply?.authorName,
                    albumID: album,
                    isSpoiler: spoiler
                ))
            case .voice(let id, let mediaID, let mediaKey, let dur, let envTTL, let fwd, let reply):
                inserted = MessageStore.shared.append(Message(
                    id: id,
                    thread: thread,
                    senderUIN: decrypted.senderUIN,
                    isFromMe: decrypted.senderUIN == ownUIN,
                    kind: .voice, text: "",
                    mediaID: mediaID + "|" + mediaKey,
                    sentAt: ws.serverTime,
                    deliveryState: .delivered,
                    receivedWhileAway: ws.offline,
                    durationSec: dur,
                    ttlSeconds: envTTL ?? localTTL,
                    forwardedFromName: fwd,
                    replyToID: reply?.id,
                    replyToSnippet: reply?.snippet,
                    replyToAuthorName: reply?.authorName
                ))
            case .file(let id, let mediaID, let mediaKey, let fname, let mime, let size, let caption, let envTTL, let fwd, let reply):
                inserted = MessageStore.shared.append(Message(
                    id: id,
                    thread: thread,
                    senderUIN: decrypted.senderUIN,
                    isFromMe: decrypted.senderUIN == ownUIN,
                    kind: .file, text: caption ?? "",
                    mediaID: mediaID + "|" + mediaKey,
                    sentAt: ws.serverTime,
                    deliveryState: .delivered,
                    receivedWhileAway: ws.offline,
                    ttlSeconds: envTTL ?? localTTL,
                    forwardedFromName: fwd,
                    replyToID: reply?.id,
                    replyToSnippet: reply?.snippet,
                    replyToAuthorName: reply?.authorName,
                    fileName: fname,
                    fileMime: mime,
                    fileSizeBytes: size
                ))
            case .location(let id, let lat, let lng, let caption, let envTTL, let fwd, let reply):
                inserted = MessageStore.shared.append(Message(
                    id: id,
                    thread: thread,
                    senderUIN: decrypted.senderUIN,
                    isFromMe: decrypted.senderUIN == ownUIN,
                    kind: .location, text: caption ?? "",
                    sentAt: ws.serverTime,
                    deliveryState: .delivered,
                    receivedWhileAway: ws.offline,
                    ttlSeconds: envTTL ?? localTTL,
                    forwardedFromName: fwd,
                    replyToID: reply?.id,
                    replyToSnippet: reply?.snippet,
                    replyToAuthorName: reply?.authorName,
                    latitude: lat,
                    longitude: lng
                ))
            case .deleteForEveryone(let targetID):
                // Honor a delete-for-everyone only from someone allowed to make
                // it: the message's own author, OR (in a group) a moderator —
                // the owner, an ADMIN, or a member the owner granted the
                // `delete` cap (founder batch 21.08, item 3; web precedent:
                // incoming-store.ts groupModerator). The wire is unchanged —
                // this is the same envelope the author's own retract fans out —
                // so the RECEIVER decides whether this sender may; sealed
                // sender still reveals the decrypted deleter. An OLDER client
                // ignores a foreign delete and keeps the message — nothing
                // breaks, it just stays there. 1:1 deletes remain author-only.
                let deleter = decrypted.senderUIN
                let target = MessageStore.shared.messages(for: thread).first { $0.id == targetID }
                var authorized = target?.senderUIN == deleter
                if !authorized, case .group(let gid) = thread, let g = GroupService.shared.find(gid) {
                    if g.moderator(deleter) {
                        // The owner is named on the group row itself and needs
                        // no roster to be recognised; an admin / delete-cap
                        // member is found in the roster when one is cached.
                        authorized = true
                    } else if g.members.isEmpty {
                        // Everyone else's role lives in the roster, which the
                        // list fetch no longer carries. The web ignores an
                        // admin's delete here (same as an old client would);
                        // iOS fetches the roster and decides again rather than
                        // silently dropping a moderator's delete.
                        Task {
                            guard let full = await GroupService.shared.ensureRoster(gid),
                                  full.moderator(deleter) else { return }
                            MessageStore.shared.deleteLocal(messageID: targetID, thread: thread)
                        }
                    }
                }
                if authorized {
                    // The message disappears, with no "deleted" placeholder left
                    // behind — a deliberate product choice, not an oversight.
                    // `deleteLocal` now keeps the row's id in the database as a
                    // hidden tombstone, so the dedup that stops a re-delivered
                    // copy still holds without anything showing in the chat.
                    MessageStore.shared.deleteLocal(messageID: targetID, thread: thread)
                }
            case .readReceipt(let ids):
                MessageStore.shared.markRead(messageIDs: ids, thread: thread)
            case .deliveredReceipt(let ids):
                MessageStore.shared.markDelivered(messageIDs: ids, thread: thread)
            case .reaction(let targetID, let asset):
                // Locate the target by id across ALL threads (not the sender-
                // derived `thread`), so a SELF-echo (a reaction made on your
                // other device, sealed to your own identity → sender == you →
                // thread would wrongly resolve to your own peer thread) lands on
                // the right message. Normal peer reactions still resolve to their
                // own thread (unique UUID).
                let reactThread = MessageStore.shared.applyReactionAnywhere(
                    targetID: targetID, uin: decrypted.senderUIN, asset: asset
                )
                if asset != nil, decrypted.senderUIN != ownUIN, let reactThread,
                   !MessageBannerService.shared.isViewing(reactThread),
                   MessageStore.shared.messages(for: reactThread)
                       .first(where: { $0.id == targetID })?.isFromMe == true {
                    ReactionInboxStore.shared.mark(reactThread)
                    // Also stash the reacted message UUID so opening the chat
                    // can scroll to + flash it (reaction-jump-on-open).
                    ReactionInboxStore.shared.markMsg(reactThread, id: targetID)
                }
            case .bounce(let targetID):
                MessageStore.shared.updateState(messageID: targetID, thread: thread, state: .failed)
            case .visit(let at):
                VisitStore.shared.record(viewer: decrypted.senderUIN, at: at)
                return nil
            case .edit(let targetID, let newText):
                MessageStore.shared.applyEdit(
                    messageID: targetID, thread: thread,
                    newText: newText, editedAt: ws.serverTime
                )
            case .systemNotice(let id, let text):
                inserted = MessageStore.shared.append(Message(
                    id: id,
                    thread: thread,
                    senderUIN: decrypted.senderUIN,
                    isFromMe: false,
                    kind: .systemNotice, text: text,
                    sentAt: ws.serverTime,
                    deliveryState: .delivered
                ))
            case .poll(let id, let pollID, let question, let options, let singleChoice, let anonymous):
                // Bubble keeps the question + options + flags as a
                // small JSON blob inside `text` — the renderer parses
                // it via `PollPayload.decode`. Server-side vote
                // tallies fetched on demand via /polls/{pollID}.
                let payload = PollPayload(
                    question: question,
                    options: options,
                    singleChoice: singleChoice,
                    anonymous: anonymous
                )
                let encoded = (try? JSONEncoder().encode(payload))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? question
                inserted = MessageStore.shared.append(Message(
                    id: id,
                    thread: thread,
                    senderUIN: decrypted.senderUIN,
                    isFromMe: decrypted.senderUIN == ownUIN,
                    kind: .poll, text: encoded,
                    sentAt: ws.serverTime,
                    deliveryState: .delivered,
                    receivedWhileAway: ws.offline,
                    pollID: pollID
                ))
            case .relayShare(let id, let relay, _):
                // In-chat bridge sharing: a contact handed us a relay to augment
                // our transport pool. Store the rcq-relay:// token in `text`;
                // ChatView renders it as an Add card. Drop malformed shares.
                guard let r = ContactRelayStore.relayFromWire(relay) else { return nil }
                inserted = MessageStore.shared.append(Message(
                    id: id,
                    thread: thread,
                    senderUIN: decrypted.senderUIN,
                    isFromMe: decrypted.senderUIN == ownUIN,
                    kind: .relay, text: ContactRelayStore.relayToToken(r),
                    sentAt: ws.serverTime,
                    deliveryState: .delivered,
                    receivedWhileAway: ws.offline
                ))
            case .secureScreen(let on):
                // Peer toggled per-conversation screen-secure mode — mirror it
                // locally so OUR side also blanks this chat (1:1 only for now).
                if case .peer = thread {
                    ChatSettingsStore.shared.setSecure(on, for: thread)
                }
                return nil
            case .screenshotTaken(let id):
                // Peer took a screenshot in a secure chat — show a line with
                // their name (resolved on our side, in our locale).
                // Store a sentinel and resolve the screenshotter's name at
                // DISPLAY time (Message.systemNoticeText). The 1:1 peer is
                // always a contact, so resolving live always yields the nick —
                // baking it here produced a stale "#911" whenever contacts
                // weren't loaded yet during a reconnect-queue drain.
                inserted = MessageStore.shared.append(Message(
                    id: id,
                    thread: thread,
                    senderUIN: decrypted.senderUIN,
                    isFromMe: false,
                    kind: .systemNotice,
                    text: Message.screenshotSentinel,
                    sentAt: ws.serverTime,
                    deliveryState: .delivered
                ))
            case .carbon:
                // Intercepted before this switch (filed into its destination
                // thread). Unreachable here; present only for exhaustiveness.
                break
            case .callSignal:
                // §5d: intercepted before this switch (routed to CallService).
                // Unreachable here; present only for exhaustiveness.
                break
            case .homeRecord:
                // Gossip B1: intercepted before this switch (cached via
                // applyPushedRecord). Unreachable here; for exhaustiveness.
                break
            case .contactRequest:
                // §5f: intercepted before this switch (filed as a pending
                // cross-island request, never into the message store).
                // Unreachable here; present only for exhaustiveness.
                break
            case .profile:
                // §5e: intercepted before this switch (display fields of an
                // existing cross-island row). Unreachable here; present only
                // for exhaustiveness.
                break
            case .skdm, .sknack:
                // Sender-keys distribution/recovery: intercepted before this
                // switch. Unreachable here; present only for exhaustiveness.
                break
            case .unknown(let kind):
                // An envelope kind this build has never heard of, from a newer
                // client. Read off the wire safely and dropped here, which is
                // the whole point of decoding it instead of throwing: the ratchet
                // has already advanced, the row is acked, and the next message
                // is not stuck behind one we cannot read.
                os_log("ingest: unknown envelope kind %{public}@, ignored", log: .default, type: .info, kind)
            }
            // Tell the sender it ARRIVED, whether or not anybody opened it.
            //
            // ⚠ This is the only way the second tick can ever catch up. The
            // island decides "delivered" once, at send time, from whether a
            // socket of ours was live at that instant — so everything written
            // while we were offline kept one tick forever, even after we came
            // back and read it. Sealed sender means the island cannot correct
            // itself later: it does not know who sent the row it just handed us.
            // Only this device knows, so only this device can say.
            //
            // 1:1 only, real content only, and never for our own carbon coming
            // back. A group message has as many recipients as members and one
            // tick cannot stand for all of them.
            if inserted, case .peer(let peerUIN) = thread, peerUIN != ownUIN,
               decrypted.senderUIN != ownUIN,
               let contact = ContactService.shared.contacts.first(where: { $0.uin == peerUIN }),
               let insertedID = MessageStore.shared.messages(for: thread).last?.id {
                Task { [weak self] in
                    try? await self?.sendEnvelope(
                        .deliveredReceipt(targetIDs: [insertedID]), to: contact, localID: nil
                    )
                }
            }
            os_log(
                "ingest ok: senderUIN=%d thread=%{public}@ envType=%{public}@ offline=%{public}d new=%{public}d",
                log: Self.log, type: .info,
                decrypted.senderUIN,
                String(describing: thread),
                ws.type,
                ws.offline ? 1 : 0,
                inserted ? 1 : 0
            )
            return IngestOutcome(thread: thread, isNewContent: inserted, wasInNSECache: fromNSE)
        } catch {
            // `duplicatedMessage` means the v=2 ratchet already consumed this
            // envelope — we DECRYPTED AND STORED IT BEFORE. The backend always
            // queues a copy of every message it also delivers live, so the
            // offline queue re-hands us the whole backlog on each drain. With
            // the old "never ACK a failed decrypt" rule a duplicate (which
            // re-decrypt ALWAYS rejects) was never acked → the server kept
            // redelivering the same backlog forever: the log flood, the
            // `Cache purging` memory pressure, and pointless ratchet pokes.
            // Treat a duplicate as a benign, ACK-able outcome (isNewContent
            // false → no badge/banner). Genuine failures (stale key, ratchet
            // desync, unsupported version) still return nil and stay queued
            // for a later retry, as before.
            if String(describing: error).hasPrefix("duplicatedMessage") {
                let dupThread = ws.groupID.map { ThreadID.group(id: $0) } ?? ThreadID.peer(uin: 0)
                return IngestOutcome(thread: dupThread, isNewContent: false, wasInNSECache: false)
            }
            decryptError = error
            // Common: stale identity_key after peer reinstall/re-register.
            os_log(
                "ingest decrypt failed: %{public}@ — payload=%{public}@... type=%{public}@ offline=%{public}d groupID=%{public}@",
                log: Self.log, type: .error,
                String(describing: error),
                String(ws.payload.prefix(40)),
                ws.type,
                ws.offline ? 1 : 0,
                ws.groupID.map(String.init) ?? "-"
            )
            return nil
        }
    }

    /// Whether [error] is libsignal's verdict that THIS install can never open
    /// the ciphertext, however many times it is redelivered — no session under
    /// the sender's address, an identity that is not the one the session was
    /// built on, key material the message names that we never minted. Those
    /// are the shapes a pre-fan-out sender's copy for the account's PRIMARY
    /// install produces when it lands on a secondary.
    ///
    /// Deliberately narrow. A failure that merely did not complete — the store
    /// unreadable for a moment, a key not loaded yet — leaves the row worth
    /// another drain, and our own stores report exactly that as a missing row
    /// (`SignalProtocolStoreError`), indistinguishable from a genuinely absent
    /// one. So only libsignal's own verdict about the message counts here:
    /// re-draining a row we could have opened costs bandwidth, ACKing one
    /// loses the message for good.
    private static func isUnreadableHere(_ error: Error) -> Bool {
        guard let signalError = error as? SignalError else { return false }
        switch signalError {
        case .sessionNotFound, .untrustedIdentity, .invalidKeyIdentifier:
            return true
        default:
            return false
        }
    }

    func fetchOfflineQueue() async {
        if PanicPINService.shared.isLocked || PanicPINService.shared.isDecoy { return }
        // Multihoming v1: make sure the backup-island poll is running (no-op
        // without backup homes; idempotent). Independent of the primary fetch
        // below — when the primary island is down, that loop IS delivery.
        if ownUIN != 0 { Multihome.startPolling(ownUin: ownUIN) }
        struct Row: Decodable {
            let id: Int
            let envelope_type: String
            let payload: String
            let received_at: Date
            let group_id: Int?
            /// Which install of ours the sender sealed this for; nil from a
            /// sender that addresses the account rather than a device.
            let to_device_id: Int?
        }
        let myDeviceId = SignalProtocolStores.shared.localDeviceId
        do {
            // `ack=1` opts into the server-side ACK protocol: rows are
            // returned without being deleted, and the client is expected
            // to POST /messages/queue/ack with the IDs it has successfully
            // persisted. This closes the "push arrived but no message in
            // chat" hole on the legacy fetch-and-drain path — if ingest
            // fails for an envelope (decryption error, malformed payload,
            // crash mid-loop), the server keeps the row and redelivers on
            // the next fetch, up to OFFLINE_QUEUE_TTL_DAYS (default 30).
            // `dev` is OUR libsignal device id: the island hands back rows
            // addressed to it plus rows addressed to nobody in particular.
            let rows: [Row] = try await APIClient.shared.request(
                "GET", "/messages/queue", query: ["ack": "1", "dev": String(myDeviceId)]
            )
            var sawUnknownPeer = false
            // Track which rows landed locally so we can ACK them. Two
            // arrays because OfflineMessage.id and OfflineGroupMessage.id
            // are per-table auto-increment integers on the server and
            // can collide; we split by group_id.
            var ackedDirectIDs: [Int] = []
            var ackedGroupIDs: [Int] = []
            for r in rows {
                // Sealed for a sibling install of ours — an island that
                // predates per-device queues hands the account's whole
                // backlog to whoever asks. Nothing here can open it, and
                // leaving it queued means asking for it forever.
                if let to = r.to_device_id, to != myDeviceId {
                    if r.group_id == nil { ackedDirectIDs.append(r.id) } else { ackedGroupIDs.append(r.id) }
                    continue
                }
                let env = WebSocketService.EnvelopePacket(
                    type: r.envelope_type,
                    payload: r.payload,
                    serverTime: r.received_at,
                    offline: true,
                    groupID: r.group_id,
                    toDeviceID: r.to_device_id
                )
                var decryptError: Error?
                guard let outcome = ingest(envelope: env, decryptError: &decryptError) else {
                    // ingest returned nil — decryption / validation /
                    // persistence failure. Do NOT ACK; server keeps the
                    // row and redelivers on the next /messages/queue
                    // fetch. Better to over-deliver a message we'll
                    // dedupe by inner-envelope UUID than lose it.
                    //
                    // Except on a SECONDARY device, for the one failure that
                    // cannot come out differently later: an unaddressed 1:1
                    // row libsignal says we have no session or no matching
                    // identity for is a copy a pre-fan-out sender sealed to
                    // the account's primary install, and no amount of
                    // redelivery makes it readable here. A row that failed
                    // for any other reason — including one we cannot classify
                    // — stays queued, because the next drain may well open it.
                    if let decryptError, Self.isUnreadableHere(decryptError),
                       r.to_device_id == nil, r.group_id == nil, myDeviceId != 1 {
                        ackedDirectIDs.append(r.id)
                    }
                    continue
                }
                // Non-nil outcome means the envelope is now in MessageDB
                // (either freshly stored or recognised as a duplicate of
                // something we already had). Safe to ACK in both cases.
                if r.group_id == nil {
                    ackedDirectIDs.append(r.id)
                } else {
                    ackedGroupIDs.append(r.id)
                }
                // HTTP queue drain races with WS flush — isNewContent dedups badge bumps.
                guard outcome.isNewContent else { continue }
                let viewing = MessageBannerService.shared.isViewing(outcome.thread)
                // BadgeCounter (the app-icon counter) was already bumped
                // by the NSE for any message the user got a push for.
                // We only need to bump it here for envelopes that landed
                // strictly via WebSocket / offline queue without a push.
                let bumpIcon = !viewing && !outcome.wasInNSECache
                switch outcome.thread {
                case .peer(let uin):
                    if !ContactService.shared.contacts.contains(where: { $0.uin == uin }) {
                        sawUnknownPeer = true
                    }
                    if !viewing { ContactService.shared.incrementUnread(for: uin) }
                    if bumpIcon {
                        BadgeCounter.increment(threadKey: BadgeCounter.threadKey(peerUIN: uin))
                    }
                case .group(let id):
                    if !viewing { GroupService.shared.incrementUnread(id) }
                    if bumpIcon {
                        BadgeCounter.increment(threadKey: BadgeCounter.threadKey(groupID: id))
                    }
                }
            }
            // Send the ACK. Best-effort: if it fails (network blip,
            // server hiccup, app backgrounded mid-call), the server
            // holds those rows until the next fetch — same envelopes
            // come back, ingest dedupes by inner UUID, and we ACK
            // again. Eventually drains. The TTL sweeper catches rows
            // that never get ACKed (old clients, dead accounts).
            if !ackedDirectIDs.isEmpty || !ackedGroupIDs.isEmpty {
                struct AckPayload: Encodable {
                    let direct_ids: [Int]
                    let group_ids: [Int]
                }
                struct AckOut: Decodable { let deleted: Int }
                let payload = AckPayload(direct_ids: ackedDirectIDs, group_ids: ackedGroupIDs)
                do {
                    // Same `dev` as the drain above, and it has to be: the
                    // cursor moves over the contiguous prefix of the rows THIS
                    // device was served, and the server rebuilds that set from
                    // `dev`. Ack under a different one and a sibling's copy —
                    // never handed to us, never ackable — is the first hole the
                    // prefix stops at, so the cursor never moves again and this
                    // device redrains the same rows forever.
                    let _: AckOut = try await APIClient.shared.request(
                        "POST", "/messages/queue/ack", body: payload,
                        query: ["dev": String(myDeviceId)]
                    )
                } catch {
                    // Non-fatal. See comment above.
                }
            }
            // Drain finished — reconcile against the now-current
            // chat list to drop badge slots for threads the user
            // can no longer reach (removed contact, left group,
            // stranger we never upserted). Without this pass the
            // icon counter sticks at N even after every visible
            // chat has been opened.
            let knownPeers = Set(ContactService.shared.contacts.map { $0.uin })
            let knownGroups = Set(GroupService.shared.groups.map { $0.id })
            BadgeCounter.reconcile(keepPeers: knownPeers, keepGroups: knownGroups)
            BadgeCounter.syncIcon()
            if sawUnknownPeer {
                await ContactService.shared.refresh()
            }
        } catch { }
    }
}

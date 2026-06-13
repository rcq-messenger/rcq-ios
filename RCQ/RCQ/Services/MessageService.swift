import Foundation
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
                    return .photo(id: message.id, mediaID: mediaID, mediaKey: key, caption: caption, ttl: ttl, replyTo: reply, albumID: message.albumID)
                case .video:
                    return .video(id: message.id, mediaID: mediaID, mediaKey: key, thumbnailB64: message.thumbnailB64 ?? "", durationSec: message.durationSec, caption: caption, ttl: ttl, replyTo: reply, albumID: message.albumID)
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
        SmokeTracker.shared.tick(.sendMessage1to1)
        if replyTo != nil { SmokeTracker.shared.tick(.replyToMessage) }
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

    func sendPhoto(_ image: UIImage, to contact: Contact, caption: String? = nil, replyTo: ReplyContext? = nil, albumID: UUID? = nil) async throws {
        SmokeTracker.shared.tick(.sendPhoto)
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
                .photo(id: local.id, mediaID: upload.mediaID, mediaKey: upload.keyBase64, caption: caption, ttl: ttl, replyTo: replyTo, albumID: albumID),
                to: contact, localID: local.id
            )
        }
    }

    /// Send an animated GIF preserving its raw bytes (no JPEG
    /// recompression). Envelope is `.photo` — the receiver detects the
    /// `"GIF8"` magic on the decrypted blob and renders via
    /// `AnimatedGIFView`. Mirrors `sendPhoto` otherwise.
    func sendGIF(data: Data, preview: UIImage, to contact: Contact, caption: String? = nil, replyTo: ReplyContext? = nil, albumID: UUID? = nil) async throws {
        SmokeTracker.shared.tick(.sendGif)
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
        SmokeTracker.shared.tick(.sendVoice)
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
        SmokeTracker.shared.tick(.sendLocation)
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
    ) async throws {
        SmokeTracker.shared.tick(.sendVideo)
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
            albumID: albumID
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
                    albumID: albumID
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
                forwardedFromName: authorName
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
                forwardedFromName: authorName
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
            forwardedFromName: authorName
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
        if newAsset != nil { SmokeTracker.shared.tick(.sendReaction) }
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
        case .photo(let id, let mediaID, let mediaKey, let caption, let ttl, let fwd, let reply, let album):
            return MessageStore.shared.append(Message(
                id: id, thread: thread, senderUIN: me, isFromMe: true,
                kind: .photo, text: caption ?? "", mediaID: mediaID + "|" + mediaKey,
                sentAt: serverTime, deliveryState: .delivered,
                receivedWhileAway: false, ttlSeconds: ttl, forwardedFromName: fwd,
                replyToID: reply?.id, replyToSnippet: reply?.snippet, replyToAuthorName: reply?.authorName,
                albumID: album
            ))
        case .video(let id, let mediaID, let mediaKey, let thumb, let dur, let caption, let ttl, let fwd, let reply, let album):
            return MessageStore.shared.append(Message(
                id: id, thread: thread, senderUIN: me, isFromMe: true,
                kind: .video, text: caption ?? "", mediaID: mediaID + "|" + mediaKey,
                sentAt: serverTime, deliveryState: .delivered,
                receivedWhileAway: false, thumbnailB64: thumb, durationSec: dur,
                ttlSeconds: ttl, forwardedFromName: fwd,
                replyToID: reply?.id, replyToSnippet: reply?.snippet, replyToAuthorName: reply?.authorName,
                albumID: album
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
        // Saved Messages: stay local — flip delivered state and skip the wire.
        if contact.uin == ownUIN {
            if let localID {
                MessageStore.shared.updateState(messageID: localID, thread: .peer(uin: contact.uin), state: .delivered)
            }
            playSentSound(for: envelope)
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
                if await CrossIslandSender.deposit(host: h.host, uin: h.uin, payload: ciBlob) { ok = true }
            }
            if let localID {
                MessageStore.shared.updateState(messageID: localID, thread: .peer(uin: contact.uin), state: ok ? .sent : .failed)
            }
            playSentSound(for: envelope)
            return
        }
        let bundle = PeerBundle(uin: contact.uin, identityKey: contact.identityKey, signingKey: contact.signingKey)
        let blob = try await encryptForPeer(envelope: envelope, peer: bundle, peerSignalIdentityKey: contact.signalIdentityKey)

        struct Body: Encodable { let to_uin: Int; let envelope_type: String; let payload: String }
        struct Out: Decodable { let delivered: Bool; let queued: Bool }

        let envType = envelopeType(for: envelope)
        do {
            let out: Out = try await APIClient.shared.request(
                "POST", "/messages/sealed",
                body: Body(to_uin: contact.uin, envelope_type: envType, payload: blob),
                authenticated: false,
                retries: 2
            )
            if let localID {
                let next: DeliveryState = out.delivered ? .delivered : (out.queued ? .sent : .failed)
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
              let doc = AuthService.shared.buildOwnRecordDoc(ownUIN: uin),
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
            return try crypto.encryptStage3(envelope: envelope, for: peer)
        } catch {
            print("[MessageService] Stage 3 encrypt for \(peer.uin) failed (\(error)) — falling back to v=1")
            return try crypto.encrypt(envelope: envelope, for: peer)
        }
    }

    func sendGroupEnvelope(_ envelope: Envelope, to group: RCQGroup, localID: UUID?) async throws {
        // Cross-island group (§5c): seal AS the guest identity (the sender uin
        // must be our per-island uin so the roster resolves it; keys identical)
        // and deposit to the group's island. Handled on its own path.
        if let host = group.host, let ref = VisitedIslandsStore.shared.refByAlias(group.id),
           let creds = CrossIslandGroups.foreignCreds(host: host, ownUIN: AuthService.shared.ownUIN) {
            try await sendForeignGroupEnvelope(envelope, to: group, remoteId: ref.remoteId,
                                               host: host, guestUIN: creds.uin, localID: localID)
            return
        }
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
                    for m in sendable { tg.addTask { [self] in await legacySeal(m) } }
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
        guard let key = GroupSenderKeyStore.shared.deriveInbound(kid: hdr.kid, epoch: hdr.epoch, index: hdr.index) else {
            if !GroupSenderKeyStore.shared.knowsKid(hdr.kid) { sendSknack(gid: gid, kid: hdr.kid) }
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
        guard let group = GroupService.shared.groups.first(where: { $0.id == gid }) else { return }
        let targets = group.members.filter { $0.senderKeys && $0.uin != ownUIN && !$0.identityKey.isEmpty }
        struct Entry: Encodable { let to_uin: Int; let payload: String }
        struct Body: Encodable { let group_id: Int; let envelope_type: String; let payloads: [Entry] }
        struct Out: Decodable { let delivered: Bool; let queued: Bool }
        let env: Envelope = .sknack(gid: gid, kid: kid)
        Task {
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
              let snap = GroupSenderKeyStore.shared.ownChainSnapshot(ownUin: ownUIN, gid: gid),
              let group = GroupService.shared.groups.first(where: { $0.id == gid }),
              let m = group.members.first(where: { $0.uin == requesterUIN }), !m.identityKey.isEmpty else { return }
        struct Entry: Encodable { let to_uin: Int; let payload: String }
        struct Body: Encodable { let group_id: Int; let envelope_type: String; let payloads: [Entry] }
        struct Out: Decodable { let delivered: Bool; let queued: Bool }
        let env: Envelope = .skdm(gid: gid, kid: snap.kid, epoch: snap.epoch, index: snap.index, ck: snap.ck)
        Task {
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
            let blob = try await encryptForPeer(
                envelope: .visit(at: Date()),
                peer: bundle,
                peerSignalIdentityKey: signalIdentityKey
            )
            struct Body: Encodable { let to_uin: Int; let envelope_type: String; let payload: String }
            struct Out: Decodable { let delivered: Bool; let queued: Bool }
            let _: Out = try await APIClient.shared.request(
                "POST", "/messages/sealed",
                body: Body(to_uin: targetUIN, envelope_type: "visit", payload: blob),
                authenticated: false
            )
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
        case .photo(let id, _, _, _, _, _, _, _): return id
        case .video(let id, _, _, _, _, _, _, _, _, _): return id
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
        case .photo(_, _, _, let caption, _, _, _, _): return caption?.isEmpty == false ? caption! : "📷"
        case .video(_, _, _, _, _, let caption, _, _, _, _): return caption?.isEmpty == false ? caption! : "🎬"
        case .voice: return "🎤"
        case .file(_, _, _, let fname, _, _, _, _, _, _): return "📎 \(fname)"
        case .location: return "📍"
        default: return ""
        }
    }

    /// `nil` = drop silently (decrypt failed, blocked sender, random-routed, or visit).
    @discardableResult
    func ingest(envelope ws: WebSocketService.EnvelopePacket) -> IngestOutcome? {
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

            // Sender-keys distribution / recovery (never rendered). SKDM binds
            // the chain to its authenticated sender; SKNACK asks the kid owner to
            // re-distribute. Both ride the per-member sealed path.
            if case .skdm(let gid, let kid, let epoch, let index, let ck) = decrypted.envelope {
                if let sk = decrypted.senderSigningKey {
                    GroupSenderKeyStore.shared.acceptSkdm(kid: kid, gid: gid, senderUIN: decrypted.senderUIN, spub: sk, epoch: epoch, index: index, ck: ck)
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
                guard ws.groupID == nil,
                      let fromHost = decrypted.senderHost, fromHost != Multihome.ownHost(),
                      CrossIslandStore.shared.all().contains(where: { $0.uin == decrypted.senderUIN && $0.host == fromHost })
                else { return outcome }
                if sig == "call_offer", Int(Date().timeIntervalSince1970) - ts > 60 {
                    CallService.shared.fileMissedCall(
                        fromUIN: decrypted.senderUIN,
                        media: CallMedia(rawValue: data["media"] ?? "video") ?? .video
                    )
                    return outcome
                }
                CallService.shared.handleCrossIslandSignal(sig: sig, fromUIN: decrypted.senderUIN, callID: cid, data: data)
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
               fromHost != Multihome.ownHost(), decrypted.senderUIN != ownUIN,
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
                case .photo(let id, let mediaID, let mediaKey, let caption, _, _, let reply, let album):
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
                        albumID: album
                    )
                    RandomChatService.shared.append(m)
                    SoundService.shared.play(.messageIncoming)
                case .video(let id, let mediaID, let mediaKey, let thumb, let dur, let caption, _, _, let reply, let album):
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
                        albumID: album
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
                return nil
            }

            // Block-list enforcement is client-side only under sealed sender.
            // Bounce a tombstone so sender's bubble flips to .failed.
            let senderContact = ContactService.shared.contacts.first(where: { $0.uin == decrypted.senderUIN })
            if let blocked = senderContact?.blocked, blocked {
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
            case .photo(let id, let mediaID, let mediaKey, let caption, let envTTL, let fwd, let reply, let album):
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
                    albumID: album
                ))
            case .video(let id, let mediaID, let mediaKey, let thumb, let dur, let caption, let envTTL, let fwd, let reply, let album):
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
                    albumID: album
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
                // the owner or a member the owner granted the `delete` cap.
                // Sealed sender still reveals the decrypted deleter, and we have
                // the cached roster. (Previously honored from ANYONE.)
                let deleter = decrypted.senderUIN
                let target = MessageStore.shared.messages(for: thread).first { $0.id == targetID }
                var authorized = target?.senderUIN == deleter
                if !authorized, case .group(let gid) = thread, let g = GroupService.shared.find(gid) {
                    authorized = g.members.first { $0.uin == deleter }?.canDelete(ownerUIN: g.ownerUIN) == true
                }
                if authorized {
                    MessageStore.shared.deleteLocal(messageID: targetID, thread: thread)
                }
            case .readReceipt(let ids):
                MessageStore.shared.markRead(messageIDs: ids, thread: thread)
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
            case .skdm, .sknack:
                // Sender-keys distribution/recovery: intercepted before this
                // switch. Unreachable here; present only for exhaustiveness.
                break
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
        }
        do {
            // `ack=1` opts into the server-side ACK protocol: rows are
            // returned without being deleted, and the client is expected
            // to POST /messages/queue/ack with the IDs it has successfully
            // persisted. This closes the "push arrived but no message in
            // chat" hole on the legacy fetch-and-drain path — if ingest
            // fails for an envelope (decryption error, malformed payload,
            // crash mid-loop), the server keeps the row and redelivers on
            // the next fetch, up to OFFLINE_QUEUE_TTL_DAYS (default 30).
            let rows: [Row] = try await APIClient.shared.request(
                "GET", "/messages/queue", query: ["ack": "1"]
            )
            var sawUnknownPeer = false
            // Track which rows landed locally so we can ACK them. Two
            // arrays because OfflineMessage.id and OfflineGroupMessage.id
            // are per-table auto-increment integers on the server and
            // can collide; we split by group_id.
            var ackedDirectIDs: [Int] = []
            var ackedGroupIDs: [Int] = []
            for r in rows {
                let env = WebSocketService.EnvelopePacket(
                    type: r.envelope_type,
                    payload: r.payload,
                    serverTime: r.received_at,
                    offline: true,
                    groupID: r.group_id
                )
                guard let outcome = ingest(envelope: env) else {
                    // ingest returned nil — decryption / validation /
                    // persistence failure. Do NOT ACK; server keeps the
                    // row and redelivers on the next /messages/queue
                    // fetch. Better to over-deliver a message we'll
                    // dedupe by inner-envelope UUID than lose it.
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
                    let _: AckOut = try await APIClient.shared.request(
                        "POST", "/messages/queue/ack", body: payload
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

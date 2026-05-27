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
                upload = try await MediaService.shared.uploadImage(image) { p in
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
                upload = try await MediaService.shared.uploadGIF(data: data) { p in
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
                upload = try await MediaService.shared.uploadFile(at: fileURL) { p in
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
                upload = try await MediaService.shared.uploadFile(at: fileURL) { p in
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
                upload = try await MediaService.shared.uploadFile(at: processed.url) { p in
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
        do {
            switch target {
            case .peer(let c):
                try await sendEnvelope(.reaction(targetID: message.id, asset: newAsset), to: c, localID: nil)
            case .group(let g):
                try await sendGroupEnvelope(.reaction(targetID: message.id, asset: newAsset), to: g, localID: nil)
            case .randomPeer(let p):
                try await sendRandomEnvelope(
                    .reaction(targetID: message.id, asset: newAsset),
                    to: p, localID: nil
                )
            }
        } catch { }
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
        let bundle = PeerBundle(uin: contact.uin, identityKey: contact.identityKey, signingKey: contact.signingKey)
        let blob = try await encryptForPeer(envelope: envelope, peer: bundle, peerSignalIdentityKey: contact.signalIdentityKey)

        struct Body: Encodable { let to_uin: Int; let envelope_type: String; let payload: String }
        struct Out: Decodable { let delivered: Bool; let queued: Bool }

        let envType = envelopeType(for: envelope)
        do {
            let out: Out = try await APIClient.shared.request(
                "POST", "/messages/sealed",
                body: Body(to_uin: contact.uin, envelope_type: envType, payload: blob),
                authenticated: false
            )
            if let localID {
                let next: DeliveryState = out.delivered ? .delivered : (out.queued ? .sent : .failed)
                MessageStore.shared.updateState(messageID: localID, thread: .peer(uin: contact.uin), state: next)
            }
            playSentSound(for: envelope)
        } catch {
            if let localID {
                MessageStore.shared.updateState(messageID: localID, thread: .peer(uin: contact.uin), state: .failed)
            }
            throw error
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
        // Per-member encrypt (skipping self) — keeps sealed-sender intact
        // at the cost of N session encrypts vs one Sender-Keys groupEncrypt.
        struct Entry: Encodable { let to_uin: Int; let payload: String }
        let recipients = group.members.filter { m in
            guard m.uin != ownUIN else { return false }
            if m.identityKey.isEmpty {
                print("[MessageService] group member \(m.uin) has no identity key — skipping")
                return false
            }
            return true
        }
        let entries: [Entry] = await withTaskGroup(of: Entry?.self) { taskGroup in
            for member in recipients {
                taskGroup.addTask { [self] in
                    let bundle = PeerBundle(
                        uin: member.uin,
                        identityKey: member.identityKey,
                        signingKey: member.signingKey
                    )
                    do {
                        let blob = try await encryptForPeer(
                            envelope: envelope,
                            peer: bundle,
                            peerSignalIdentityKey: member.signalIdentityKey
                        )
                        return Entry(to_uin: member.uin, payload: blob)
                    } catch {
                        // Skip one bad pubkey rather than failing the whole send.
                        print("[MessageService] encrypt for \(member.uin) failed: \(error)")
                        return nil
                    }
                }
            }
            var collected: [Entry] = []
            for await result in taskGroup {
                if let r = result { collected.append(r) }
            }
            return collected
        }

        struct Body: Encodable { let group_id: Int; let envelope_type: String; let payloads: [Entry] }
        struct Out: Decodable { let delivered: Bool; let queued: Bool }

        let envType = envelopeType(for: envelope)
        do {
            let out: Out = try await APIClient.shared.request(
                "POST", "/messages/group-sealed",
                body: Body(group_id: group.id, envelope_type: envType, payloads: entries),
                authenticated: false
            )
            if let localID {
                let next: DeliveryState = out.delivered ? .delivered : .sent
                MessageStore.shared.updateState(messageID: localID, thread: .group(id: group.id), state: next)
            }
            playSentSound(for: envelope)
        } catch {
            if let localID {
                MessageStore.shared.updateState(messageID: localID, thread: .group(id: group.id), state: .failed)
            }
            throw error
        }
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

    /// `nil` = drop silently (decrypt failed, blocked sender, random-routed, or visit).
    @discardableResult
    func ingest(envelope ws: WebSocketService.EnvelopePacket) -> IngestOutcome? {
        do {
            // Hand off NSE-decrypted plaintext if present — decrypting v=2
            // twice would advance the Double Ratchet twice and fail.
            let decrypted: DecryptedEnvelope
            let fromNSE: Bool
            if let cached = PushDecryptCache.consume(ciphertextB64: ws.payload) {
                decrypted = cached
                fromNSE = true
            } else {
                decrypted = try crypto.decrypt(envelopeB64: ws.payload)
                fromNSE = false
            }
            let thread: ThreadID = ws.groupID.map { .group(id: $0) } ?? .peer(uin: decrypted.senderUIN)

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
                MessageStore.shared.deleteLocal(messageID: targetID, thread: thread)
            case .readReceipt(let ids):
                MessageStore.shared.markRead(messageIDs: ids, thread: thread)
            case .reaction(let targetID, let asset):
                MessageStore.shared.applyReaction(
                    targetID: targetID, thread: thread,
                    uin: decrypted.senderUIN, asset: asset
                )
                if asset != nil, decrypted.senderUIN != ownUIN,
                   !MessageBannerService.shared.isViewing(thread),
                   MessageStore.shared.messages(for: thread)
                       .first(where: { $0.id == targetID })?.isFromMe == true {
                    ReactionInboxStore.shared.mark(thread)
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
        struct Row: Decodable {
            let id: Int
            let envelope_type: String
            let payload: String
            let received_at: Date
            let group_id: Int?
        }
        do {
            let rows: [Row] = try await APIClient.shared.request("GET", "/messages/queue")
            // Refresh contact list if any envelope landed under an unknown UIN.
            var sawUnknownPeer = false
            for r in rows {
                let env = WebSocketService.EnvelopePacket(
                    type: r.envelope_type,
                    payload: r.payload,
                    serverTime: r.received_at,
                    offline: true,
                    groupID: r.group_id
                )
                guard let outcome = ingest(envelope: env) else { continue }
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

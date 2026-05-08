import Foundation
import os.log
import UIKit

/// Send + receive layer. Sealed-sender via `/messages/sealed`; group fan-out via `/messages/group-sealed`.
@MainActor
final class MessageService {
    static let shared = MessageService()

    private var crypto: CryptoService!
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

    func sendPhoto(_ image: UIImage, to contact: Contact, caption: String? = nil, replyTo: ReplyContext? = nil) async throws {
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
            replyToAuthorName: replyTo?.authorName
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
                .photo(id: local.id, mediaID: upload.mediaID, mediaKey: upload.keyBase64, caption: caption, ttl: ttl, replyTo: replyTo),
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

    func sendVideo(processed: VideoProcessor.Output, to contact: Contact, caption: String? = nil, replyTo: ReplyContext? = nil) async throws {
        let ttl = ChatSettingsStore.shared.ttl(for: .peer(uin: contact.uin))
        let local = Message(
            thread: .peer(uin: contact.uin),
            senderUIN: ownUIN,
            isFromMe: true,
            kind: .video,
            text: caption ?? "",
            mediaID: nil,
            thumbnailB64: processed.thumbnailB64,
            durationSec: processed.durationSec,
            ttlSeconds: ttl,
            replyToID: replyTo?.id,
            replyToSnippet: replyTo?.snippet,
            replyToAuthorName: replyTo?.authorName
        )
        MessageStore.shared.append(local)
        MediaProgressStore.shared.begin(local.id)
        Task { [weak self] in
            guard let self else { return }
            defer { try? FileManager.default.removeItem(at: processed.url) }
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
                    replyTo: replyTo
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

    /// v1 supports text bubbles only — callers must gate.
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

    // MARK: - sending (random chat)

    /// Local copy lives in `RandomChatService.messages` (in-memory, ephemeral).
    func send(text: String, toRandom peer: RandomPeer, replyTo: ReplyContext? = nil) async throws {
        let local = Message(
            thread: .peer(uin: peer.uin),
            senderUIN: ownUIN,
            isFromMe: true,
            kind: .text,
            text: text,
            replyToID: replyTo?.id,
            replyToSnippet: replyTo?.snippet,
            replyToAuthorName: replyTo?.authorName
        )
        RandomChatService.shared.append(local)

        let bundle = PeerBundle(uin: peer.uin, identityKey: peer.identityKey, signingKey: peer.signingKey)
        let blob = try crypto.encrypt(envelope: .text(id: local.id, text: text, replyTo: replyTo), for: bundle)

        struct Body: Encodable { let to_uin: Int; let envelope_type: String; let payload: String }
        struct Out: Decodable { let delivered: Bool; let queued: Bool }

        do {
            let out: Out = try await APIClient.shared.request(
                "POST", "/messages/sealed",
                body: Body(to_uin: peer.uin, envelope_type: "message", payload: blob),
                authenticated: false
            )
            let next: DeliveryState = out.delivered ? .delivered : (out.queued ? .sent : .failed)
            RandomChatService.shared.updateState(messageID: local.id, to: next)
            SoundService.shared.play(.messageSent)
        } catch {
            RandomChatService.shared.updateState(messageID: local.id, to: .failed)
            throw error
        }
    }

    func sendPhoto(_ image: UIImage, toRandom peer: RandomPeer, caption: String? = nil, replyTo: ReplyContext? = nil) async throws {
        let local = Message(
            thread: .peer(uin: peer.uin),
            senderUIN: ownUIN,
            isFromMe: true,
            kind: .photo,
            text: caption ?? "",
            mediaID: nil,
            replyToID: replyTo?.id,
            replyToSnippet: replyTo?.snippet,
            replyToAuthorName: replyTo?.authorName
        )
        RandomChatService.shared.append(local)
        MediaProgressStore.shared.begin(local.id)
        let upload: MediaService.UploadResult
        do {
            upload = try await MediaService.shared.uploadImage(image) { p in
                MediaProgressStore.shared.set(local.id, value: p)
            }
        } catch {
            MediaProgressStore.shared.clear(local.id)
            RandomChatService.shared.updateState(messageID: local.id, to: .failed)
            throw error
        }
        MediaProgressStore.shared.clear(local.id)
        let combined = upload.mediaID + "|" + upload.keyBase64
        RandomChatService.shared.updateMediaID(messageID: local.id, mediaID: combined)
        try await sendRandomEnvelope(
            .photo(id: local.id, mediaID: upload.mediaID, mediaKey: upload.keyBase64, caption: caption, replyTo: replyTo),
            to: peer,
            localID: local.id
        )
    }

    func sendVoice(fileURL: URL, durationSec: Double, toRandom peer: RandomPeer, replyTo: ReplyContext? = nil) async throws {
        let local = Message(
            thread: .peer(uin: peer.uin),
            senderUIN: ownUIN,
            isFromMe: true,
            kind: .voice,
            text: "",
            mediaID: nil,
            durationSec: durationSec,
            replyToID: replyTo?.id,
            replyToSnippet: replyTo?.snippet,
            replyToAuthorName: replyTo?.authorName,
        )
        RandomChatService.shared.append(local)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        MediaProgressStore.shared.begin(local.id)
        let upload: MediaService.UploadResult
        do {
            upload = try await MediaService.shared.uploadFile(at: fileURL) { p in
                MediaProgressStore.shared.set(local.id, value: p)
            }
        } catch {
            MediaProgressStore.shared.clear(local.id)
            RandomChatService.shared.updateState(messageID: local.id, to: .failed)
            throw error
        }
        MediaProgressStore.shared.clear(local.id)
        let combined = upload.mediaID + "|" + upload.keyBase64
        RandomChatService.shared.updateMediaID(messageID: local.id, mediaID: combined)
        try await sendRandomEnvelope(
            .voice(
                id: local.id,
                mediaID: upload.mediaID, mediaKey: upload.keyBase64,
                durationSec: durationSec,
                replyTo: replyTo
            ),
            to: peer,
            localID: local.id
        )
    }

    func sendVideo(processed: VideoProcessor.Output, toRandom peer: RandomPeer, caption: String? = nil, replyTo: ReplyContext? = nil) async throws {
        let local = Message(
            thread: .peer(uin: peer.uin),
            senderUIN: ownUIN,
            isFromMe: true,
            kind: .video,
            text: caption ?? "",
            mediaID: nil,
            thumbnailB64: processed.thumbnailB64,
            durationSec: processed.durationSec,
            replyToID: replyTo?.id,
            replyToSnippet: replyTo?.snippet,
            replyToAuthorName: replyTo?.authorName
        )
        RandomChatService.shared.append(local)
        defer { try? FileManager.default.removeItem(at: processed.url) }
        MediaProgressStore.shared.begin(local.id)
        let upload: MediaService.UploadResult
        do {
            upload = try await MediaService.shared.uploadFile(at: processed.url) { p in
                MediaProgressStore.shared.set(local.id, value: p)
            }
        } catch {
            MediaProgressStore.shared.clear(local.id)
            RandomChatService.shared.updateState(messageID: local.id, to: .failed)
            throw error
        }
        MediaProgressStore.shared.clear(local.id)
        let combined = upload.mediaID + "|" + upload.keyBase64
        RandomChatService.shared.updateMediaID(messageID: local.id, mediaID: combined)
        try await sendRandomEnvelope(
            .video(
                id: local.id,
                mediaID: upload.mediaID, mediaKey: upload.keyBase64,
                thumbnailB64: processed.thumbnailB64,
                durationSec: processed.durationSec,
                caption: caption,
                replyTo: replyTo
            ),
            to: peer,
            localID: local.id
        )
    }

    private func sendRandomEnvelope(_ envelope: Envelope, to peer: RandomPeer, localID: UUID?) async throws {
        let bundle = PeerBundle(uin: peer.uin, identityKey: peer.identityKey, signingKey: peer.signingKey)
        let blob = try crypto.encrypt(envelope: envelope, for: bundle)
        struct Body: Encodable { let to_uin: Int; let envelope_type: String; let payload: String }
        struct Out: Decodable { let delivered: Bool; let queued: Bool }
        do {
            let out: Out = try await APIClient.shared.request(
                "POST", "/messages/sealed",
                body: Body(to_uin: peer.uin, envelope_type: "message", payload: blob),
                authenticated: false
            )
            if let localID {
                let next: DeliveryState = out.delivered ? .delivered : (out.queued ? .sent : .failed)
                RandomChatService.shared.updateState(messageID: localID, to: next)
            }
            playSentSound(for: envelope)
        } catch {
            if let localID {
                RandomChatService.shared.updateState(messageID: localID, to: .failed)
            }
            throw error
        }
    }

    // MARK: - sending (group)

    func send(text: String, to group: RCQGroup, replyTo: ReplyContext? = nil) async throws {
        let ttl = ChatSettingsStore.shared.ttl(for: .group(id: group.id))
        let local = Message(
            thread: .group(id: group.id),
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
        // Detach — fan-out is N×crypto rounds, would otherwise hang the composer.
        Task { [weak self] in
            try? await self?.sendGroupEnvelope(.text(id: local.id, text: text, ttl: ttl, replyTo: replyTo), to: group, localID: local.id)
        }
    }

    func sendPhoto(_ image: UIImage, to group: RCQGroup, caption: String? = nil, replyTo: ReplyContext? = nil) async throws {
        let ttl = ChatSettingsStore.shared.ttl(for: .group(id: group.id))
        let local = Message(
            thread: .group(id: group.id),
            senderUIN: ownUIN,
            isFromMe: true,
            kind: .photo,
            text: caption ?? "",
            ttlSeconds: ttl,
            replyToID: replyTo?.id,
            replyToSnippet: replyTo?.snippet,
            replyToAuthorName: replyTo?.authorName
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
                MessageStore.shared.updateState(messageID: local.id, thread: .group(id: group.id), state: .failed)
                return
            }
            MediaProgressStore.shared.clear(local.id)
            let combined = upload.mediaID + "|" + upload.keyBase64
            MessageStore.shared.updateMediaID(messageID: local.id, thread: .group(id: group.id), mediaID: combined)
            try? await self.sendGroupEnvelope(
                .photo(id: local.id, mediaID: upload.mediaID, mediaKey: upload.keyBase64, caption: caption, ttl: ttl, replyTo: replyTo),
                to: group, localID: local.id
            )
        }
    }

    func sendVoice(fileURL: URL, durationSec: Double, to group: RCQGroup, replyTo: ReplyContext? = nil) async throws {
        let ttl = ChatSettingsStore.shared.ttl(for: .group(id: group.id))
        let local = Message(
            thread: .group(id: group.id),
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
                MessageStore.shared.updateState(messageID: local.id, thread: .group(id: group.id), state: .failed)
                return
            }
            MediaProgressStore.shared.clear(local.id)
            let combined = upload.mediaID + "|" + upload.keyBase64
            MessageStore.shared.updateMediaID(messageID: local.id, thread: .group(id: group.id), mediaID: combined)
            try? await self.sendGroupEnvelope(
                .voice(
                    id: local.id,
                    mediaID: upload.mediaID, mediaKey: upload.keyBase64,
                    durationSec: durationSec,
                    ttl: ttl,
                    replyTo: replyTo
                ),
                to: group, localID: local.id
            )
        }
    }

    func sendVideo(processed: VideoProcessor.Output, to group: RCQGroup, caption: String? = nil, replyTo: ReplyContext? = nil) async throws {
        let ttl = ChatSettingsStore.shared.ttl(for: .group(id: group.id))
        let local = Message(
            thread: .group(id: group.id),
            senderUIN: ownUIN,
            isFromMe: true,
            kind: .video,
            text: caption ?? "",
            mediaID: nil,
            thumbnailB64: processed.thumbnailB64,
            durationSec: processed.durationSec,
            ttlSeconds: ttl,
            replyToID: replyTo?.id,
            replyToSnippet: replyTo?.snippet,
            replyToAuthorName: replyTo?.authorName
        )
        MessageStore.shared.append(local)
        MediaProgressStore.shared.begin(local.id)
        Task { [weak self] in
            guard let self else { return }
            defer { try? FileManager.default.removeItem(at: processed.url) }
            let upload: MediaService.UploadResult
            do {
                upload = try await MediaService.shared.uploadFile(at: processed.url) { p in
                    MediaProgressStore.shared.set(local.id, value: p)
                }
            } catch {
                MediaProgressStore.shared.clear(local.id)
                MessageStore.shared.updateState(messageID: local.id, thread: .group(id: group.id), state: .failed)
                return
            }
            MediaProgressStore.shared.clear(local.id)
            let combined = upload.mediaID + "|" + upload.keyBase64
            MessageStore.shared.updateMediaID(messageID: local.id, thread: .group(id: group.id), mediaID: combined)
            try? await self.sendGroupEnvelope(
                .video(
                    id: local.id,
                    mediaID: upload.mediaID, mediaKey: upload.keyBase64,
                    thumbnailB64: processed.thumbnailB64,
                    durationSec: processed.durationSec,
                    caption: caption,
                    ttl: ttl,
                    replyTo: replyTo
                ),
                to: group, localID: local.id
            )
        }
    }

    func deleteForEveryone(message: Message, in group: RCQGroup) async throws {
        // Local drop first — fan-out is too slow to animate against.
        MessageStore.shared.deleteLocal(messageID: message.id, thread: .group(id: group.id))
        try await sendGroupEnvelope(
            .deleteForEveryone(targetID: message.id), to: group, localID: nil
        )
    }

    // MARK: - premium content (paywalled media)

    private struct PremiumRecipient {
        let uin: Int
        let identityKey: String
        let signingKey: String
        let signalIdentityKey: String?
    }

    private func premiumRecipients(for target: ChatTarget) -> [PremiumRecipient] {
        switch target {
        case .peer(let c):
            return [PremiumRecipient(
                uin: c.uin, identityKey: c.identityKey,
                signingKey: c.signingKey, signalIdentityKey: c.signalIdentityKey
            )]
        case .group(let g):
            return g.members.compactMap { m in
                guard m.uin != ownUIN, !m.identityKey.isEmpty else { return nil }
                return PremiumRecipient(
                    uin: m.uin, identityKey: m.identityKey,
                    signingKey: m.signingKey, signalIdentityKey: m.signalIdentityKey
                )
            }
        case .randomPeer:
            return []
        }
    }

    private func uploadPremiumKeys(
        contentID: UUID, mediaKeyB64: String, recipients: [PremiumRecipient], price: Int
    ) async throws {
        struct RecipientKey: Encodable { let uin: Int; let wrapped_key: String }
        struct Body: Encodable { let id: String; let price_tokens: Int; let recipient_keys: [RecipientKey] }
        struct Out: Decodable { let id: String }

        let wrapped: [RecipientKey] = try recipients.map { r in
            let bundle = PeerBundle(uin: r.uin, identityKey: r.identityKey, signingKey: r.signingKey)
            let w = try crypto.wrapKey(mediaKeyB64, for: bundle)
            return RecipientKey(uin: r.uin, wrapped_key: w)
        }
        let _: Out = try await APIClient.shared.request(
            "POST", "/premium/contents",
            body: Body(
                id: contentID.uuidString.lowercased(),
                price_tokens: price,
                recipient_keys: wrapped
            )
        )
    }

    /// K is wrapped per-recipient and POSTed to `/premium/contents` before the envelope.
    /// Recipients fetch wrapped K via `/premium/contents/{id}/unlock` after paying.
    func sendPremiumPhoto(_ image: UIImage, in target: ChatTarget, price: Int, caption: String? = nil, replyTo: ReplyContext? = nil) async throws {
        let recipients = premiumRecipients(for: target)
        guard !recipients.isEmpty else { return }
        let messageID = UUID()
        let ttl = ChatSettingsStore.shared.ttl(for: target.thread)
        let local = Message(
            id: messageID,
            thread: target.thread,
            senderUIN: ownUIN,
            isFromMe: true,
            kind: .premiumPhoto,
            text: caption ?? "",
            mediaID: nil,
            ttlSeconds: ttl,
            replyToID: replyTo?.id,
            replyToSnippet: replyTo?.snippet,
            replyToAuthorName: replyTo?.authorName,
            premiumPriceTokens: price,
            premiumUnlocked: true
        )
        MessageStore.shared.append(local)
        MediaProgressStore.shared.begin(messageID)
        Task { [weak self] in
            guard let self else { return }
            let upload: MediaService.UploadResult
            do {
                upload = try await MediaService.shared.uploadImage(image) { p in
                    MediaProgressStore.shared.set(messageID, value: p)
                }
            } catch {
                MediaProgressStore.shared.clear(messageID)
                MessageStore.shared.updateState(messageID: messageID, thread: target.thread, state: .failed)
                return
            }
            MediaProgressStore.shared.clear(messageID)
            let combined = upload.mediaID + "|" + upload.keyBase64
            MessageStore.shared.updateMediaID(messageID: messageID, thread: target.thread, mediaID: combined)
            // POST wrapped keys before the envelope so a racing /unlock finds the row.
            do {
                try await self.uploadPremiumKeys(
                    contentID: messageID,
                    mediaKeyB64: upload.keyBase64,
                    recipients: recipients,
                    price: price
                )
            } catch {
                MessageStore.shared.updateState(messageID: messageID, thread: target.thread, state: .failed)
                return
            }
            let blurThumb = Self.blurThumbnailB64(from: image)
            let envelope: Envelope = .premiumPhoto(
                id: messageID,
                mediaID: upload.mediaID,
                price: price,
                blurThumbnailB64: blurThumb,
                caption: caption,
                ttl: ttl,
                replyTo: replyTo
            )
            switch target {
            case .peer(let c):
                try? await self.sendEnvelope(envelope, to: c, localID: messageID)
            case .group(let g):
                try? await self.sendGroupEnvelope(envelope, to: g, localID: messageID)
            case .randomPeer:
                break
            }
        }
    }

    func sendPremiumVideo(processed: VideoProcessor.Output, in target: ChatTarget, price: Int, caption: String? = nil, replyTo: ReplyContext? = nil) async throws {
        let recipients = premiumRecipients(for: target)
        guard !recipients.isEmpty else { return }
        let messageID = UUID()
        let ttl = ChatSettingsStore.shared.ttl(for: target.thread)
        let local = Message(
            id: messageID,
            thread: target.thread,
            senderUIN: ownUIN,
            isFromMe: true,
            kind: .premiumVideo,
            text: caption ?? "",
            mediaID: nil,
            thumbnailB64: processed.thumbnailB64,
            durationSec: processed.durationSec,
            ttlSeconds: ttl,
            replyToID: replyTo?.id,
            replyToSnippet: replyTo?.snippet,
            replyToAuthorName: replyTo?.authorName,
            premiumPriceTokens: price,
            premiumUnlocked: true
        )
        MessageStore.shared.append(local)
        MediaProgressStore.shared.begin(messageID)
        Task { [weak self] in
            guard let self else { return }
            defer { try? FileManager.default.removeItem(at: processed.url) }
            let upload: MediaService.UploadResult
            do {
                upload = try await MediaService.shared.uploadFile(at: processed.url) { p in
                    MediaProgressStore.shared.set(messageID, value: p)
                }
            } catch {
                MediaProgressStore.shared.clear(messageID)
                MessageStore.shared.updateState(messageID: messageID, thread: target.thread, state: .failed)
                return
            }
            MediaProgressStore.shared.clear(messageID)
            let combined = upload.mediaID + "|" + upload.keyBase64
            MessageStore.shared.updateMediaID(messageID: messageID, thread: target.thread, mediaID: combined)
            do {
                try await self.uploadPremiumKeys(
                    contentID: messageID,
                    mediaKeyB64: upload.keyBase64,
                    recipients: recipients,
                    price: price
                )
            } catch {
                MessageStore.shared.updateState(messageID: messageID, thread: target.thread, state: .failed)
                return
            }
            let envelope: Envelope = .premiumVideo(
                id: messageID,
                mediaID: upload.mediaID,
                price: price,
                blurThumbnailB64: processed.thumbnailB64,
                durationSec: processed.durationSec,
                caption: caption,
                ttl: ttl,
                replyTo: replyTo
            )
            switch target {
            case .peer(let c):
                try? await self.sendEnvelope(envelope, to: c, localID: messageID)
            case .group(let g):
                try? await self.sendGroupEnvelope(envelope, to: g, localID: messageID)
            case .randomPeer:
                break
            }
        }
    }

    /// Idempotent server-side — re-calling on paid content returns K without recharging.
    func unlockPremium(message: Message) async throws -> Int {
        struct Out: Decodable {
            let wrapped_key: String
            let price_tokens: Int
            let paid_just_now: Bool
            let wallet: Wallet
        }
        let response: Out = try await APIClient.shared.request(
            "POST", "/premium/contents/\(message.id.uuidString.lowercased())/unlock"
        )
        let mediaKeyB64 = try crypto.unwrapKey(response.wrapped_key)
        MessageStore.shared.unlockPremium(
            messageID: message.id, thread: message.thread, mediaKeyB64: mediaKeyB64
        )
        ItemsService.shared.setWalletTokens(response.wallet.tokens)
        return response.wallet.tokens
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

    private func sendGroupEnvelope(_ envelope: Envelope, to group: RCQGroup, localID: UUID?) async throws {
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
        case .photo(let id, _, _, _, _, _, _): return id
        case .video(let id, _, _, _, _, _, _, _, _): return id
        case .voice(let id, _, _, _, _, _, _): return id
        case .systemNotice(let id, _): return id
        case .premiumPhoto(let id, _, _, _, _, _, _, _): return id
        case .premiumVideo(let id, _, _, _, _, _, _, _, _): return id
        default: return nil
        }
    }

    private func playSentSound(for envelope: Envelope) {
        switch envelope {
        case .text, .photo, .voice, .premiumPhoto, .premiumVideo: SoundService.shared.play(.messageSent)
        default: break
        }
    }

    // MARK: - ingest

    struct IngestOutcome {
        let thread: ThreadID
        /// True only for brand-new content; false for dedup, control envelopes, visits.
        let isNewContent: Bool
    }

    /// `nil` = drop silently (decrypt failed, blocked sender, random-routed, or visit).
    @discardableResult
    func ingest(envelope ws: WebSocketService.EnvelopePacket) -> IngestOutcome? {
        do {
            // Hand off NSE-decrypted plaintext if present — decrypting v=2
            // twice would advance the Double Ratchet twice and fail.
            let decrypted: DecryptedEnvelope
            if let cached = PushDecryptCache.consume(ciphertextB64: ws.payload) {
                decrypted = cached
            } else {
                decrypted = try crypto.decrypt(envelopeB64: ws.payload)
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
                case .photo(let id, let mediaID, let mediaKey, let caption, _, _, let reply):
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
                        replyToAuthorName: Self.resolveRandomReplyAuthor(reply: reply)
                    )
                    RandomChatService.shared.append(m)
                    SoundService.shared.play(.messageIncoming)
                case .video(let id, let mediaID, let mediaKey, let thumb, let dur, let caption, _, _, let reply):
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
                        replyToAuthorName: Self.resolveRandomReplyAuthor(reply: reply)
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
            case .photo(let id, let mediaID, let mediaKey, let caption, let envTTL, let fwd, let reply):
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
                    replyToAuthorName: reply?.authorName
                ))
            case .video(let id, let mediaID, let mediaKey, let thumb, let dur, let caption, let envTTL, let fwd, let reply):
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
                    replyToAuthorName: reply?.authorName
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
            case .deleteForEveryone(let targetID):
                MessageStore.shared.deleteLocal(messageID: targetID, thread: thread)
            case .readReceipt(let ids):
                MessageStore.shared.markRead(messageIDs: ids, thread: thread)
            case .reaction(let targetID, let asset):
                MessageStore.shared.applyReaction(
                    targetID: targetID, thread: thread,
                    uin: decrypted.senderUIN, asset: asset
                )
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
            case .premiumPhoto(let id, let mediaID, let price, let thumb, let caption, let envTTL, let fwd, let reply):
                // Empty key half (`<id>|`) keeps the media renderer's split parser happy until unlock.
                inserted = MessageStore.shared.append(Message(
                    id: id,
                    thread: thread,
                    senderUIN: decrypted.senderUIN,
                    isFromMe: decrypted.senderUIN == ownUIN,
                    kind: .premiumPhoto, text: caption ?? "",
                    mediaID: mediaID + "|",
                    sentAt: ws.serverTime,
                    deliveryState: .delivered,
                    receivedWhileAway: ws.offline,
                    thumbnailB64: thumb,
                    ttlSeconds: envTTL ?? localTTL,
                    forwardedFromName: fwd,
                    replyToID: reply?.id,
                    replyToSnippet: reply?.snippet,
                    replyToAuthorName: reply?.authorName,
                    premiumPriceTokens: price,
                    premiumUnlocked: false
                ))
            case .premiumVideo(let id, let mediaID, let price, let thumb, let dur, let caption, let envTTL, let fwd, let reply):
                inserted = MessageStore.shared.append(Message(
                    id: id,
                    thread: thread,
                    senderUIN: decrypted.senderUIN,
                    isFromMe: decrypted.senderUIN == ownUIN,
                    kind: .premiumVideo, text: caption ?? "",
                    mediaID: mediaID + "|",
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
                    premiumPriceTokens: price,
                    premiumUnlocked: false
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
            return IngestOutcome(thread: thread, isNewContent: inserted)
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
                switch outcome.thread {
                case .peer(let uin):
                    if !ContactService.shared.contacts.contains(where: { $0.uin == uin }) {
                        sawUnknownPeer = true
                    }
                    ContactService.shared.incrementUnread(for: uin)
                case .group(let id):
                    GroupService.shared.incrementUnread(id)
                }
            }
            if sawUnknownPeer {
                await ContactService.shared.refresh()
            }
        } catch { }
    }
}

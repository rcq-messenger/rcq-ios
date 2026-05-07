import Foundation
import os.log
import UIKit

/// Send + receive layer. Uses CryptoService to encrypt/decrypt. The HTTP send hits
/// `/messages/sealed` (anonymous — server has no idea who sent it). Group sends fan
/// out via `/messages/group-sealed`. Server only sees recipient + ciphertext.
///
/// 1:1 traffic rides on the real `SignalCryptoService` (CryptoKit ECIES +
/// Ed25519 sealed-sender, Stage 1). Group traffic still uses the legacy
/// `LegacyGroupCryptoService` until per-recipient encryption + Sender Keys
/// land — that's Stage 2 work and is documented loudly on the relevant
/// send/ingest call sites.
@MainActor
final class MessageService {
    static let shared = MessageService()

    /// Stage-2 sealed-sender crypto. Used for both 1:1 and group traffic —
    /// group sends fan out per-recipient, each ciphertext sealed to one
    /// member's identity key. Built when `configure()` runs after auth
    /// bootstrap; force-unwrapped because sends/ingests can't happen
    /// before that point.
    private var crypto: CryptoService!
    private(set) var ownUIN: Int = 0

    private static let log = OSLog(subsystem: "app.rcq.client", category: "MessageService")

    private init() {}

    func configure(ownUIN: Int) {
        self.ownUIN = ownUIN
        // Rebuild the crypto service around the X25519 + Ed25519 private keys
        // that AuthService.bootstrapIfNeeded already wrote to the Keychain
        // (either fresh on first registration, or stored long ago). On the
        // off chance the Keychain was wiped out from under us, bootstrap a
        // throwaway identity so encrypt/decrypt at least don't crash —
        // AuthService's 404/401 recovery on the next `/users/me` round-trip
        // will force a real re-register.
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
        // Detach encrypt + POST — the caller (ChatViewModel.send) awaits
        // this method and the chat composer hangs until it returns. By
        // returning right after the optimistic append, the bubble paints
        // on the next frame instead of after Stage 3 session fetch +
        // crypto + HTTP roundtrip (which together can run 100–500ms on a
        // cold session, and 5–15ms even hot — visible "ICQ-era" lag).
        // Failure is reflected back through MessageStore.updateState
        // inside sendEnvelope, so we can swallow the error here.
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
        // Detach upload + crypto + POST so the bubble paints immediately
        // with its progress strip. Caller doesn't wait on the multi-second
        // upload — they see the bubble on the next frame, the progress
        // bar fills as bytes ship, and the delivery state flips once the
        // server confirms. Same fire-and-forget pattern as the text path.
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

    /// Encrypt + upload a recorded voice message and ship the envelope.
    /// The `.m4a` file at `fileURL` is consumed (deleted on success or
    /// failure) so callers don't need a separate cleanup pass.
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
        // Same detach pattern as sendPhoto. The local file cleanup moved
        // inside the Task so it doesn't race the upload. Caller returns
        // immediately; UI shows the voice bubble with progress strip.
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
        // Detach — same rationale as sendPhoto. Bubble + thumbnail render
        // immediately; the upload/encrypt/POST runs in the background.
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

    /// Re-send `message` to a 1:1 destination, baking the original
    /// author's nickname into the envelope so the recipient renders
    /// "Forwarded from <name>" attribution. Per spec we don't
    /// propagate the original sender's UIN — nickname-only keeps a
    /// forwarded message from doubling as a contact-discovery vector.
    /// The forwarder becomes the apparent sender (their UIN +
    /// signature go on the wire as usual).
    func forward(message: Message, authorName: String, toContact contact: Contact) async throws {
        let thread = ThreadID.peer(uin: contact.uin)
        let newID = UUID()
        let envelope = forwardEnvelope(from: message, newID: newID, authorName: authorName, ttlForThread: thread)
        let local = forwardLocalMessage(from: message, newID: newID, in: thread, authorName: authorName)
        MessageStore.shared.append(local)
        try await sendEnvelope(envelope, to: contact, localID: local.id)
    }

    /// Group fan-out variant. Same envelope, fanned per-member via
    /// the existing v=1/v=2 group path.
    func forward(message: Message, authorName: String, toGroup group: RCQGroup) async throws {
        let thread = ThreadID.group(id: group.id)
        let newID = UUID()
        let envelope = forwardEnvelope(from: message, newID: newID, authorName: authorName, ttlForThread: thread)
        let local = forwardLocalMessage(from: message, newID: newID, in: thread, authorName: authorName)
        MessageStore.shared.append(local)
        try await sendGroupEnvelope(envelope, to: group, localID: local.id)
    }

    /// Build an envelope that carries the same content as `source`
    /// but under `newID`, with the destination thread's TTL setting
    /// and `authorName` as forwarded-from attribution. Caller passes
    /// the id explicitly so the local Message we append sits under
    /// the same id and `updateState`/`tombstone` plumbing keeps
    /// working.
    private func forwardEnvelope(from source: Message, newID: UUID, authorName: String, ttlForThread thread: ThreadID) -> Envelope {
        let ttl = ChatSettingsStore.shared.ttl(for: thread)
        switch source.kind {
        case .photo:
            // mediaID stored as "<id>|<key>" — split back out so the
            // forwarded envelope carries the same combined token a
            // first-hand send produces.
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

    /// Edit the body text of a previously-sent text bubble. Applies
    /// the change locally first (optimistic), then ships an `.edit`
    /// envelope so the recipient's MessageStore mirrors the new
    /// text + edited-at timestamp. v1 only supports text bubbles —
    /// callers must gate this themselves (UI does, via the "Edit"
    /// menu item only appearing on own text rows).
    func edit(message: Message, newText: String, to contact: Contact) async throws {
        let now = Date()
        let thread = ThreadID.peer(uin: contact.uin)
        MessageStore.shared.applyEdit(messageID: message.id, thread: thread, newText: newText, editedAt: now)
        // Saved-Messages short-circuit — same shape as the regular
        // sendEnvelope path. No wire send because there's no peer
        // to notify.
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
        // Random chat is in-memory only; rebuild the row in the
        // ephemeral buffer so the bubble re-renders. Wire path
        // mirrors regular send so the receiver applies via the
        // same `.edit` ingest branch (random ingest is currently a
        // no-op for `.edit` — that's fine for v1, the sender-side
        // local update is the visible part).
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
            // Direct mutation through a private helper would be
            // cleaner; for now we use the existing append+dedup path
            // which is idempotent on UUID — but that adds rather
            // than replaces. Use the deleteMessage + append pattern
            // to swap. Could be refactored if edit-in-random becomes
            // a hot path.
            RandomChatService.shared.deleteMessage(id: message.id)
            RandomChatService.shared.append(msg)
        }
        try await sendRandomEnvelope(.edit(targetID: message.id, text: newText), to: peer, localID: nil)
    }

    /// Local + remote delete. **Optimistic**: drop the local row
    /// FIRST so the soft-delete fade fires the instant the user taps,
    /// then ship the envelope in the background. The previous
    /// post-await order made groups feel broken — encrypting +
    /// shipping per-recipient blobs to a 5-person group took 200-500ms
    /// of wall-clock during which the user's bubble sat untouched, so
    /// the eventual fade looked like a delayed pop instead of a
    /// reaction to their tap.
    func deleteForEveryone(message: Message, to contact: Contact) async throws {
        MessageStore.shared.deleteLocal(messageID: message.id, thread: .peer(uin: contact.uin))
        try await sendEnvelope(
            .deleteForEveryone(targetID: message.id),
            to: contact,
            localID: nil
        )
    }

    /// Random-chat variant of `deleteForEveryone`. Same wire
    /// shape as the contact path — sealed `.deleteForEveryone`
    /// envelope through the random tunnel — but the local copy
    /// lives in `RandomChatService.messages`, not `MessageStore`.
    func deleteForEveryone(message: Message, toRandom peer: RandomPeer) async throws {
        RandomChatService.shared.deleteMessage(id: message.id)
        try await sendRandomEnvelope(
            .deleteForEveryone(targetID: message.id),
            to: peer, localID: nil
        )
    }

    // MARK: - sending (random chat)

    /// Send a text message inside an active random-chat session. Reuses the
    /// sealed-sender wire (server is type-agnostic — it just relays the blob)
    /// but routes the local copy through `RandomChatService.messages`, NOT
    /// `MessageStore`. Random sessions are ephemeral by design — when the
    /// pair ends, the messages vanish without ever touching CoreData.
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

    /// Photo into the active random-chat session. Mirrors
    /// `sendPhoto(_:to: Contact)` but writes the local copy into
    /// `RandomChatService.messages` (in-memory, ephemeral) instead of
    /// `MessageStore`. Media still uploads to the regular media bucket
    /// so the recipient can fetch + decrypt the same way.
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

    /// Encrypt + ship a generic envelope to the random peer. Pulled
    /// out so photo/video paths share the same network shape as
    /// `send(text:toRandom:)` without duplicating each step. Uses
    /// the v=1 ECIES path — random peers don't expose a
    /// `signal_identity_key` (they're discovered fresh, not fetched
    /// by UIN), so Stage 3 v=2 isn't applicable here.
    ///
    /// `localID` is non-nil for content envelopes (text/photo/
    /// video) where we want to flip a previously-appended
    /// outbound bubble's delivery state on success/failure. For
    /// "side-channel" envelopes — reactions, deletes — there's no
    /// local row to update; pass nil and the helper just ships
    /// the blob.
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
        // Detach — group fan-out encryption can balloon to N×crypto
        // rounds (one per member). Holding the caller across that turns
        // a 10-person group send into a noticeable hang. Bubble paints
        // immediately, status flips when the fan-out + POST settles.
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
        // Same optimistic order as the 1:1 path. Group fan-out is
        // strictly slower (TaskGroup of N per-recipient encrypts +
        // one POST), so without the upfront local drop the deleter
        // sees no animation until the slowest member's libsignal
        // session encrypt finishes — typically the difference between
        // "bubble fades smoothly" and "bubble pops a beat later".
        MessageStore.shared.deleteLocal(messageID: message.id, thread: .group(id: group.id))
        try await sendGroupEnvelope(
            .deleteForEveryone(targetID: message.id), to: group, localID: nil
        )
    }

    // MARK: - premium content (paywalled media)

    /// Recipient + identity-key tuple for the per-recipient ECIES key
    /// wrap. Built once from the chat target so the wrap loop doesn't
    /// rebuild PeerBundle on every iteration.
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
            // Random chat is ephemeral by design — no wallet identity
            // to charge, and the peer pair doesn't survive the session.
            // Premium content doesn't make sense there.
            return []
        }
    }

    /// Wrap K for every recipient + POST `/premium/contents` so the
    /// server holds the wrapped forms behind the paywall. Same shape
    /// for both 1:1 and group sends — just the recipient list differs.
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

    /// Send a paywalled photo. Mirrors `sendPhoto` (encrypt + upload
    /// the media via the existing flow, then ship a sealed envelope)
    /// with two extras: K is wrapped per-recipient and uploaded to
    /// `/premium/contents` BEFORE the envelope flies, and the envelope
    /// carries no `mediaKey` (recipients fetch the wrapped K via
    /// `/premium/contents/{id}/unlock` after paying).
    ///
    /// Local copy is appended unlocked — sender always sees their own
    /// content. The wire envelope reaches recipients as a locked
    /// bubble until they pay.
    func sendPremiumPhoto(_ image: UIImage, in target: ChatTarget, price: Int, caption: String? = nil, replyTo: ReplyContext? = nil) async throws {
        let recipients = premiumRecipients(for: target)
        guard !recipients.isEmpty else { return }
        let messageID = UUID()
        let ttl = ChatSettingsStore.shared.ttl(for: target.thread)
        // Sender sees the unlocked bubble immediately (we generated K
        // and have the plaintext-equivalent media handle locally).
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
            // Patch the local row with the full mediaID|key pack so the
            // sender's bubble can decrypt + render the photo just like a
            // regular .photo message.
            let combined = upload.mediaID + "|" + upload.keyBase64
            MessageStore.shared.updateMediaID(messageID: messageID, thread: target.thread, mediaID: combined)
            // Wrap K per recipient + POST to backend BEFORE the envelope
            // so a recipient who races to /unlock right after the WS
            // event arrives finds the row instead of 404'ing.
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
            // For the sender's local thumbnail rendering — generate a
            // small downscaled JPEG. Receivers blur this for the locked
            // placeholder; sender doesn't render it (their bubble shows
            // the full photo via the cached media).
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

    /// Same model as `sendPremiumPhoto` for video — the existing
    /// VideoProcessor.Output already carries a poster thumbnail we
    /// can reuse for the blur placeholder.
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

    /// Recipient-side unlock. Charges the wallet (server-side, atomic
    /// with the receipt insert), unwraps K with our identity private
    /// key, and patches the local row so subsequent renders show the
    /// real media. Idempotent on the server: re-calling unlock on a
    /// previously-paid content returns the wrapped K without charging
    /// again. Returns the new wallet balance so the caller can show
    /// the spend in the UI without a separate inventory refresh.
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
        // Mirror the authoritative wallet from the server reply so
        // the UI reflects the spend immediately — same pattern as
        // marketplace buys + Crash settlements.
        ItemsService.shared.setWalletTokens(response.wallet.tokens)
        return response.wallet.tokens
    }

    /// Tiny base64 JPEG used as the locked-state blur source. We
    /// downscale aggressively (max 64px on the long edge) so even
    /// before SwiftUI's `.blur(radius:)` is applied, the preview
    /// reveals only general colors / shapes — no recognizable
    /// content. Heavily blurred client-side on render.
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

    /// Acknowledge a batch of received message ids. 1:1 only — group-wide read
    /// receipts would mean broadcasting per-sender ack to N members, which gets
    /// noisy fast. For groups we just clear the unread counter and stop.
    func markRead(messages: [Message], in target: ChatTarget) async {
        let received = messages.filter { !$0.isFromMe && $0.deliveryState != .read }
        guard !received.isEmpty else { return }
        let ids = received.map(\.id)
        switch target {
        case .peer(let contact):
            // Mark locally so we don't re-ack on next open.
            MessageStore.shared.markRead(messageIDs: ids, thread: .peer(uin: contact.uin))
            do {
                try await sendEnvelope(.readReceipt(targetIDs: ids), to: contact, localID: nil)
            } catch { }
        case .group:
            // Local-only read in groups for now.
            MessageStore.shared.markRead(messageIDs: ids, thread: target.thread)
        case .randomPeer:
            // Read receipts in anonymous chat would leak engagement metadata
            // back to the stranger. Skip.
            break
        }
    }

    // MARK: - reactions

    func toggleReaction(on message: Message, asset: String, in target: ChatTarget) async {
        let me = ownUIN
        let current = message.reactions[me]
        let newAsset: String? = (current == asset) ? nil : asset
        // Apply locally first for snappy UI. Random chat keeps its
        // own in-memory buffer; everything else flows through the
        // persistent MessageStore.
        if case .randomPeer = target {
            RandomChatService.shared.applyReaction(targetID: message.id, uin: me, asset: newAsset)
        } else {
            MessageStore.shared.applyReaction(
                targetID: message.id, thread: target.thread, uin: me, asset: newAsset
            )
        }
        // Fan out so the other side updates.
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
        // Saved Messages — sending to our own UIN. Short-circuit: the
        // local Message is already in MessageStore (the upstream
        // `send`/`sendPhoto` paths appended before calling here), so
        // we just flip its delivery state to delivered and stop. No
        // ciphertext, no /messages/sealed POST, no server queue —
        // saved-messages stay 100% local on this device.
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

    /// Decide v=1 vs v=2 and encrypt accordingly. Falls back to v=1 if
    /// the peer hasn't uploaded a libsignal bundle yet, or if Stage 3
    /// session establishment fails for any reason. Always returns a
    /// blob the existing transport (`/messages/sealed`) can ship.
    private func encryptForPeer(envelope: Envelope, peer: PeerBundle, peerSignalIdentityKey: String?) async throws -> String {
        guard let psk = peerSignalIdentityKey, !psk.isEmpty else {
            // Stage 2-only peer — straight v=1.
            return try crypto.encrypt(envelope: envelope, for: peer)
        }
        // Stage 3 path: ensure session, then v=2 encrypt. Any failure
        // here (network, malformed bundle, identity-store error) drops
        // back to v=1 so the message still ships. Stage 3 is a perf
        // and security win, not a hard requirement per message.
        do {
            try await SignalCryptoService.ensureStage3Session(forPeerUIN: peer.uin)
            return try crypto.encryptStage3(envelope: envelope, for: peer)
        } catch {
            print("[MessageService] Stage 3 encrypt for \(peer.uin) failed (\(error)) — falling back to v=1")
            return try crypto.encrypt(envelope: envelope, for: peer)
        }
    }

    private func sendGroupEnvelope(_ envelope: Envelope, to group: RCQGroup, localID: UUID?) async throws {
        // Group fan-out: encrypt the envelope ONCE PER MEMBER (skipping
        // ourselves — we already keep the local copy in MessageStore from
        // the upstream send call). Per-member encryption picks v=2 (Stage 3
        // hybrid: outer ECIES + inner libsignal session) when the member
        // has uploaded a libsignal bundle, otherwise falls back to v=1
        // (Stage 2 ECIES) so a stage-2-only member still gets the message.
        //
        // We deliberately skip libsignal Sender Keys for groups: those
        // need either a server-signed SenderCertificate (heavy server
        // crypto, not in this stage) or a leaked sender_uin in the
        // outer wire (regresses the sealed-sender property Stage 2
        // already shipped). Per-member v=2 keeps sealed-sender intact at
        // the cost of N libsignal session encrypts instead of one
        // groupEncrypt — acceptable for typical group sizes.
        struct Entry: Encodable { let to_uin: Int; let payload: String }
        // Parallel fan-out — earlier serial loop made a 10-person group
        // pay 10× the per-peer encryption time. With TaskGroup the
        // wall-clock cost collapses to roughly the slowest single
        // member's Stage-3 session establishment (still bound by the
        // shared SignalProtocolDB write lock for new sessions, but
        // cached sessions encrypt fully in parallel).
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
                        // One member's pubkey malformed — skip them, don't
                        // fail the whole send. Their copy is lost for this
                        // message; everyone else still gets it.
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

    /// Last time we pinged each (target) UIN with a `.visit` envelope this session.
    /// In-memory only — app restart resets it, which is fine: a viewer who reopens
    /// the app and views the same profile counts as one fresh visit, not spam.
    private var lastVisitFiredAt: [Int: Date] = [:]
    /// Don't re-fire `.visit` to the same target more often than this. Receiver
    /// dedups too (in `VisitStore`), but cheap belt-and-suspenders avoids the
    /// network round-trip on tap-spamming open/close on the same profile.
    private static let visitThrottle: TimeInterval = 60 * 60

    /// Fire-and-forget: tell `targetUIN` that we just looked at their profile.
    /// Sealed-sender, so the server only sees recipient + opaque blob. Caller
    /// passes the target's identity + signing keys (both on hand from
    /// `GET /users/.../info`). Throttled per (own-session, target) so re-opens
    /// within the hour don't spam.
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
            // Fire-and-forget — a missed visit is just a missed +1 on the
            // recipient's counter. Don't surface it.
            lastVisitFiredAt[targetUIN] = nil
        }
    }

    /// Pluck out the carrying message id from an envelope when one exists. Used by
    /// the block-bounce path: we need the id of the message we're rejecting to put
    /// in our bounce envelope.
    /// In random chat the sender embeds the *sender-side*
    /// `authorName` ("You" if they're replying to their own
    /// bubble, "Stranger" if to the peer's). On the receiving
    /// end that mapping inverts: a "You" from the wire really
    /// means "the original message was the *sender's* bubble"
    /// — which from this client's vantage point is the
    /// stranger. So we ignore `reply.authorName` entirely and
    /// rebuild the label by looking up the parent in our local
    /// random buffer: own bubble → "You", peer's → "Stranger".
    /// Falls back to whatever was on the wire if the parent
    /// can't be found (e.g. it was deleted-for-everyone before
    /// this reply arrived).
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

    /// Outcome of an `ingest()` call. Callers (AppState's WS event
    /// dispatcher, `fetchOfflineQueue`) need to know not just which
    /// thread the envelope landed in but also whether it represents
    /// new content — without that, a queue-drain that re-delivers an
    /// already-stored message would still bump unread / play a
    /// sound, inflating badges past the real unread count.
    struct IngestOutcome {
        let thread: ThreadID
        /// True only when a brand-new content row landed in
        /// `MessageStore`. False for: dedup'd content (same UUID
        /// already stored), ephemeral / control envelopes
        /// (read receipt, reaction, delete, bounce), and visits.
        let isNewContent: Bool
    }

    /// Decrypt an inbound envelope from the WS layer. Returns the
    /// resulting thread + new-content flag so AppState can route
    /// side-effects (badge, sound). `nil` means "drop silently" —
    /// decrypt failed, blocked sender, random-chat routed, or
    /// non-thread-routed envelope (visit).
    @discardableResult
    func ingest(envelope ws: WebSocketService.EnvelopePacket) -> IngestOutcome? {
        do {
            // Stage-2: 1:1 AND group envelopes both ride on the same ECIES
            // path. The sender encrypts per-recipient (one ciphertext per
            // group member), so each member's wire payload is structurally
            // identical to a 1:1 envelope addressed to them. Sender info
            // lives inside the ciphertext via Ed25519 sealed-sender on
            // every kind of envelope.
            //
            // First, check whether the NSE already decrypted this same
            // ciphertext to render the push preview. For v=2 (libsignal)
            // payloads that's load-bearing — calling `crypto.decrypt`
            // twice on the same wire bytes advances the Double Ratchet
            // twice and the second call fails. The cache hand-off keeps
            // libsignal at exactly one decrypt per envelope.
            let decrypted: DecryptedEnvelope
            if let cached = PushDecryptCache.consume(ciphertextB64: ws.payload) {
                decrypted = cached
            } else {
                decrypted = try crypto.decrypt(envelopeB64: ws.payload)
            }
            let thread: ThreadID = ws.groupID.map { .group(id: $0) } ?? .peer(uin: decrypted.senderUIN)

            // Random-chat routing: if the sender is our currently-matched
            // anonymous peer, the envelope belongs in `RandomChatService` —
            // ephemeral and unpersisted — not the regular MessageStore. We
            // only do this for 1:1 (no `groupID`) and for content envelopes
            // that make sense in random chat (text for v1; photo/video etc.
            // would land later if we choose to allow them).
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
                    // Read-receipts, visits, system notices etc.
                    // don't make sense in an ephemeral random
                    // session — drop silently.
                    break
                }
                return nil
            }

            // Block-list enforcement, client side. The server can't enforce it under
            // sealed sender — only we know who actually sent this envelope. We drop
            // the inbound silently AND bounce a tombstone back so the blocked sender's
            // bubble flips to `.failed` (gives them an indication, not a leak).
            let senderContact = ContactService.shared.contacts.first(where: { $0.uin == decrypted.senderUIN })
            if let blocked = senderContact?.blocked, blocked {
                if let messageID = Self.messageID(in: decrypted.envelope), let contact = senderContact {
                    Task { try? await self.sendEnvelope(.bounce(targetID: messageID), to: contact, localID: nil) }
                }
                return nil
            }

            // Disappearing-message TTL precedence: sender's envelope ttl wins
            // (their setting at send time), otherwise fall back to the
            // recipient's local thread setting so each side can shorten the
            // lifespan unilaterally.
            let localTTL = ChatSettingsStore.shared.ttl(for: thread)
            // Tracks whether `MessageStore.append` actually inserted
            // a new row or whether it deduped against an existing
            // UUID. Only content envelopes (text/photo/video/system)
            // ever flip this true; control envelopes (delete / read /
            // reaction / bounce) leave it false because the unread /
            // sound side-effects shouldn't fire for those anyway.
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
                // Drop the row outright on the receiving side too — no
                // "Message deleted" placeholder, the bubble just disappears.
                MessageStore.shared.deleteLocal(messageID: targetID, thread: thread)
            case .readReceipt(let ids):
                // Sender's bubbles in *our* thread with this peer flip to .read.
                MessageStore.shared.markRead(messageIDs: ids, thread: thread)
            case .reaction(let targetID, let asset):
                MessageStore.shared.applyReaction(
                    targetID: targetID, thread: thread,
                    uin: decrypted.senderUIN, asset: asset
                )
            case .bounce(let targetID):
                MessageStore.shared.updateState(messageID: targetID, thread: thread, state: .failed)
            case .visit(let at):
                // Profile-view ping. Receiver-only side effect: bump the local
                // visit log. We deliberately don't append to MessageStore — it's
                // not a chat event and shouldn't show up in any thread.
                VisitStore.shared.record(viewer: decrypted.senderUIN, at: at)
                return nil
            case .edit(let targetID, let newText):
                // Sender's edit lands on a row we already have. Apply
                // it to MessageStore so the bubble re-renders with the
                // updated text + the "(edited)" affordance. No new
                // unread / sound side-effects — `isNewContent` stays
                // false because nothing fresh appeared in the thread.
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
                // Locked bubble: store the mediaID with empty key
                // (`<id>|`) so the existing media renderer's parser
                // doesn't crash when it splits on `|`. The unlock flow
                // patches in the real key + flips `premiumUnlocked`.
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
            // Diagnostic: log successful ingest with key fields so
            // when a user reports "message didn't appear" we can see
            // in Console.app whether decrypt actually ran AND under
            // which sender UIN / thread the message landed. Without
            // this we have to guess between "decrypt failed silently"
            // and "stored under a different thread than the user
            // expected".
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
            // Decrypt / verify failures land here. Most common cause:
            // sender's contact list cached the recipient's old
            // identity_key (after the recipient reinstalled or
            // re-registered). Surface the error to Console.app so
            // we don't lose visibility — the previous silent return
            // made it impossible to tell the difference between
            // "nothing arrived" and "arrived but couldn't decrypt".
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
            // Track UINs that ingested under a thread we don't have a
            // contact for. If any landed, force a contact-list refresh
            // after the drain — covers the case where a peer was added
            // (or re-registered with a new UIN) while we were offline,
            // so a tap on the push notification can find their row in
            // the freshly-pulled list.
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
                // Only bump unread for content that actually landed
                // in the store. The HTTP queue drain races with the
                // server's WS `_on_connect` flush, so the same row
                // can be ingested twice (once via WS push with
                // `offline=true`, once via this HTTP fetch). The new-
                // content flag stops both paths from each adding
                // their own +1 to the badge.
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
        } catch {
            // Silent — server will retry on next reconnect.
        }
    }
}

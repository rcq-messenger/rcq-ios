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
        // The room-log marks are per account and per island: an account
        // switch starts from what the next drain's `cursors` say.
        groupLogAcked = [:]
        pendingLiveAcks = [:]
        liveAckFlush?.cancel()
        liveAckFlush = nil
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
        // The countdown the peer runs must start where OUR copy's starts. A
        // retry hours after the failed send would otherwise stamp itself at
        // seal time and hand the peer a fresh lifetime this device's own row
        // will not get. `sentAt` on an outgoing row IS the compose time.
        let composedTS = Int(message.sentAt.timeIntervalSince1970)

        let envelope: Envelope? = {
            switch message.kind {
            case .text:
                return .text(id: message.id, text: message.text, ttl: ttl, ts: composedTS, replyTo: reply)
            case .photo, .video, .file, .voice:
                guard let combined = message.mediaID,
                      let pipe = combined.firstIndex(of: "|") else { return nil }
                let mediaID = String(combined[..<pipe])
                let key = String(combined[combined.index(after: pipe)...])
                let caption: String? = message.text.isEmpty ? nil : message.text
                switch message.kind {
                case .photo:
                    return .photo(id: message.id, mediaID: mediaID, mediaKey: key, caption: caption, ttl: ttl, ts: composedTS, replyTo: reply, albumID: message.albumID, spoiler: message.isSpoiler)
                case .video:
                    return .video(id: message.id, mediaID: mediaID, mediaKey: key, thumbnailB64: message.thumbnailB64 ?? "", durationSec: message.durationSec, caption: caption, ttl: ttl, ts: composedTS, replyTo: reply, albumID: message.albumID, spoiler: message.isSpoiler)
                case .file:
                    return .file(id: message.id, mediaID: mediaID, mediaKey: key, fileName: message.fileName ?? "file", mime: message.fileMime ?? "application/octet-stream", sizeBytes: message.fileSizeBytes ?? 0, caption: caption, ttl: ttl, ts: composedTS, replyTo: reply)
                case .voice:
                    return .voice(id: message.id, mediaID: mediaID, mediaKey: key, durationSec: message.durationSec, ttl: ttl, ts: composedTS, replyTo: reply)
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
        // Saved Messages has no peer to notify, but the account's OTHER
        // devices hold the note too (it arrived there as a carbon), so the
        // edit must not stop here: sendEnvelope short-circuits a send to self
        // into exactly the carbon-only mirror this needs.
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
                senderSentAt: msg.senderSentAt,
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
        struct Body: Encodable { let to_uin: Int; let envelope_type: String; let cls: Int; let payload: String }
        struct Out: Decodable { let delivered: Bool; let queued: Bool }
        let etype = envelopeType(for: envelope)
        do {
            let _: Out = try await APIClient.shared.request(
                "POST", "/messages/sealed",
                body: Body(to_uin: me, envelope_type: etype, cls: rcqMessageClass(etype), payload: blob),
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
        // A delete-for-everyone rides along for the same reason an edit does:
        // the group fan-out skips self and a 1:1 delete only goes to the peer,
        // so a retraction made on one of the user's devices never reached the
        // user's other devices in either direction. The receive side APPLIES
        // this control carbon (tombstones the row) instead of filing it.
        case .deleteForEveryone: return true
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
        struct Body: Encodable { let to_uin: Int; let envelope_type: String; let cls: Int; let payload: String }
        struct Out: Decodable { let delivered: Bool; let queued: Bool }
        do {
            let _: Out = try await APIClient.shared.request(
                "POST", "/messages/sealed",
                body: Body(to_uin: me, envelope_type: "carbon", cls: rcqMessageClass("carbon"), payload: blob),
                authenticated: false,
                retries: 1
            )
        } catch { }
    }

    /// Tell my OTHER devices that I read a thread (megalist A2). The marker
    /// rides inside the same self-carbon a sent message uses, so the island
    /// sees the sealed self-addressed blob it has always seen. The outer type
    /// is "read", which the island already files as EPHEMERAL: it reaches my
    /// other devices live and through their queues but never pushes a banner
    /// to my own sleeping phone, and "read" is a token the island reads on
    /// every peer receipt anyway. Nothing new is learned, which was the
    /// condition this feature had to meet.
    ///
    /// Never for Saved Messages (I am the peer there). Best effort: a lost
    /// marker only means the other device clears its badge when it is next
    /// opened, exactly as it did before.
    func sendReadMarker(toPeer: Int?, toGroup: Int?) async {
        let me = ownUIN
        if let p = toPeer, p == me { return }
        guard toPeer != nil || toGroup != nil else { return }
        guard let mine = try? crypto.bootstrapIdentity() else { return }
        let selfBundle = PeerBundle(uin: me, identityKey: mine.identityKey, signingKey: mine.signingKey)
        let at = Int64(Date().timeIntervalSince1970 * 1000)
        let carbon: Envelope = .carbon(to: toPeer, gid: toGroup, env: .readMark(at: at))
        guard let blob = try? crypto.encrypt(envelope: carbon, for: selfBundle) else { return }
        struct Body: Encodable { let to_uin: Int; let envelope_type: String; let cls: Int; let payload: String }
        struct Out: Decodable { let delivered: Bool; let queued: Bool }
        do {
            let _: Out = try await APIClient.shared.request(
                "POST", "/messages/sealed",
                body: Body(to_uin: me, envelope_type: "read", cls: rcqMessageClass("read"), payload: blob),
                authenticated: false,
                retries: 1
            )
        } catch { }
    }

    /// Another device of this account read `thread` up to `at` (A2). Recount
    /// rather than clear: a message that landed AFTER that moment is still
    /// unread here, so a marker crossing paths with a fresh message cannot
    /// swallow it, and the badge only ever shrinks - an out-of-order marker
    /// can never un-read a thread.
    private func applyRemoteRead(thread: ThreadID, at: Int64) {
        let cutoff = Date(timeIntervalSince1970: Double(at) / 1000)
        let rows = MessageStore.shared.messages(for: thread)
        let after = rows.filter { !$0.isFromMe && $0.sentAt > cutoff }.count
        switch thread {
        case .peer(let uin):
            let current = UnreadStore.shared.unread(forPeer: uin)
            guard current > 0, after < current else { return }
            if after == 0 { ContactService.shared.clearUnread(for: uin) }
            else { UnreadStore.shared.setPeer(uin, after) }
        case .group(let id):
            let current = UnreadStore.shared.unread(forGroup: id)
            guard current > 0, after < current else { return }
            if after == 0 { GroupService.shared.clearUnread(id) }
            else { UnreadStore.shared.setGroup(id, after) }
        }
    }

    /// Ask a member (the owner, in practice) for a room's state key.
    func sendRoomKeyAsk(gid: Int, to member: RCQGroupMember) async {
        let bundle = PeerBundle(uin: member.uin, identityKey: member.identityKey, signingKey: member.signingKey)
        guard let blob = try? crypto.encrypt(envelope: .gsKnack(gid: gid), for: bundle) else { return }
        struct Body: Encodable { let to_uin: Int; let envelope_type: String; let cls: Int; let payload: String }
        struct Out: Decodable { let delivered: Bool; let queued: Bool }
        _ = try? await APIClient.shared.request(
            "POST", "/messages/sealed",
            body: Body(to_uin: member.uin, envelope_type: "sknack", cls: rcqMessageClass("sknack"), payload: blob),
            authenticated: false,
            retries: 1
        ) as Out
    }

    /// Hand a room key to one member, sealed 1:1 under the skdm outer type -
    /// critical class, same as the web. Serves both the gsknack answer and
    /// the add-member hand-off.
    func sendRoomKey(gid: Int, held: (ver: Int64, key: String), to asker: RCQGroupMember) async {
        await answerRoomKeyAsk(gid: gid, held: held, asker: asker)
    }

    /// Answer a room-key ask (stage 6 phase 2): seal our gskey 1:1 to the
    /// asker under the skdm outer type - critical class, same as the web.
    private func answerRoomKeyAsk(gid: Int, held: (ver: Int64, key: String), asker: RCQGroupMember) async {
        let bundle = PeerBundle(uin: asker.uin, identityKey: asker.identityKey, signingKey: asker.signingKey)
        let env: Envelope = .gsKey(gid: gid, ver: held.ver, key: held.key)
        guard let blob = try? crypto.encrypt(envelope: env, for: bundle) else { return }
        struct Body: Encodable { let to_uin: Int; let envelope_type: String; let cls: Int; let payload: String }
        struct Out: Decodable { let delivered: Bool; let queued: Bool }
        _ = try? await APIClient.shared.request(
            "POST", "/messages/sealed",
            body: Body(to_uin: asker.uin, envelope_type: "skdm", cls: rcqMessageClass("skdm"), payload: blob),
            authenticated: false,
            retries: 1
        ) as Out
    }

    /// Hand my profile key to one asker. The twin of [answerRoomKeyAsk], and
    /// the peer bundle comes from the roster because only a contact should be
    /// asking - a stranger gets the lettered tile, which is the point.
    private func answerProfileKeyAsk(to uin: Int, keyB64: String) async {
        guard let c = ContactService.shared.contacts.first(where: { $0.uin == uin }),
              !c.identityKey.isEmpty else { return }
        let bundle = PeerBundle(uin: uin, identityKey: c.identityKey, signingKey: c.signingKey)
        guard let blob = try? crypto.encrypt(envelope: .pkey(key: keyB64), for: bundle) else { return }
        struct Body: Encodable { let to_uin: Int; let envelope_type: String; let cls: Int; let payload: String }
        struct Out: Decodable { let delivered: Bool; let queued: Bool }
        _ = try? await APIClient.shared.request(
            "POST", "/messages/sealed",
            body: Body(to_uin: uin, envelope_type: "skdm", cls: rcqMessageClass("skdm"), payload: blob),
            authenticated: false,
            retries: 1
        ) as Out
    }

    /// Files one CONTENT envelope (text/photo/video/voice/file/location) into
    /// `thread` outside the normal ingest switch. Two callers: a multi-device
    /// carbon (senderUIN = me, isFromMe true) and the stranger-quarantine
    /// release (senderUIN = the accepted stranger, isFromMe false).
    /// MessageStore dedups by id, so the origin device's own carbon and any
    /// queue redelivery are no-ops.
    @discardableResult
    private func appendContentMessage(
        inner: Envelope, thread: ThreadID, senderUIN: Int, isFromMe: Bool, serverTime: Date
    ) -> Bool {
        let me = senderUIN
        switch inner {
        case .text(let id, let text, let ttl, let ts, let fwd, let reply):
            return MessageStore.shared.append(Message(
                id: id, thread: thread, senderUIN: me, isFromMe: isFromMe,
                kind: .text, text: text, sentAt: serverTime, deliveryState: .delivered,
                receivedWhileAway: false, ttlSeconds: ttl,
                senderSentAt: Self.inboundAnchor(envTTL: ttl, ts: ts, receipt: serverTime),
                forwardedFromName: fwd,
                replyToID: reply?.id, replyToSnippet: reply?.snippet, replyToAuthorName: reply?.authorName
            ))
        case .photo(let id, let mediaID, let mediaKey, let caption, let ttl, let ts, let fwd, let reply, let album, let spoiler):
            return MessageStore.shared.append(Message(
                id: id, thread: thread, senderUIN: me, isFromMe: isFromMe,
                kind: .photo, text: caption ?? "", mediaID: mediaID + "|" + mediaKey,
                sentAt: serverTime, deliveryState: .delivered,
                receivedWhileAway: false, ttlSeconds: ttl,
                senderSentAt: Self.inboundAnchor(envTTL: ttl, ts: ts, receipt: serverTime),
                forwardedFromName: fwd,
                replyToID: reply?.id, replyToSnippet: reply?.snippet, replyToAuthorName: reply?.authorName,
                albumID: album, isSpoiler: spoiler
            ))
        case .video(let id, let mediaID, let mediaKey, let thumb, let dur, let caption, let ttl, let ts, let fwd, let reply, let album, let spoiler):
            return MessageStore.shared.append(Message(
                id: id, thread: thread, senderUIN: me, isFromMe: isFromMe,
                kind: .video, text: caption ?? "", mediaID: mediaID + "|" + mediaKey,
                sentAt: serverTime, deliveryState: .delivered,
                receivedWhileAway: false, thumbnailB64: thumb, durationSec: dur,
                ttlSeconds: ttl,
                senderSentAt: Self.inboundAnchor(envTTL: ttl, ts: ts, receipt: serverTime),
                forwardedFromName: fwd,
                replyToID: reply?.id, replyToSnippet: reply?.snippet, replyToAuthorName: reply?.authorName,
                albumID: album, isSpoiler: spoiler
            ))
        case .voice(let id, let mediaID, let mediaKey, let dur, let ttl, let ts, let fwd, let reply):
            return MessageStore.shared.append(Message(
                id: id, thread: thread, senderUIN: me, isFromMe: isFromMe,
                kind: .voice, text: "", mediaID: mediaID + "|" + mediaKey,
                sentAt: serverTime, deliveryState: .delivered,
                receivedWhileAway: false, durationSec: dur, ttlSeconds: ttl,
                senderSentAt: Self.inboundAnchor(envTTL: ttl, ts: ts, receipt: serverTime),
                forwardedFromName: fwd,
                replyToID: reply?.id, replyToSnippet: reply?.snippet, replyToAuthorName: reply?.authorName
            ))
        case .file(let id, let mediaID, let mediaKey, let fname, let mime, let size, let caption, let ttl, let ts, let fwd, let reply):
            return MessageStore.shared.append(Message(
                id: id, thread: thread, senderUIN: me, isFromMe: isFromMe,
                kind: .file, text: caption ?? "", mediaID: mediaID + "|" + mediaKey,
                sentAt: serverTime, deliveryState: .delivered,
                receivedWhileAway: false, ttlSeconds: ttl,
                senderSentAt: Self.inboundAnchor(envTTL: ttl, ts: ts, receipt: serverTime),
                forwardedFromName: fwd,
                replyToID: reply?.id, replyToSnippet: reply?.snippet, replyToAuthorName: reply?.authorName,
                fileName: fname, fileMime: mime, fileSizeBytes: size
            ))
        case .location(let id, let lat, let lng, let caption, let ttl, let ts, let fwd, let reply):
            return MessageStore.shared.append(Message(
                id: id, thread: thread, senderUIN: me, isFromMe: isFromMe,
                kind: .location, text: caption ?? "", sentAt: serverTime, deliveryState: .delivered,
                receivedWhileAway: false, ttlSeconds: ttl,
                senderSentAt: Self.inboundAnchor(envTTL: ttl, ts: ts, receipt: serverTime),
                forwardedFromName: fwd,
                replyToID: reply?.id, replyToSnippet: reply?.snippet, replyToAuthorName: reply?.authorName,
                latitude: lat, longitude: lng
            ))
        default:
            return false
        }
    }

    /// Release a same-island stranger's held messages into their thread after
    /// the user accepted the request (Privacy quarantine, host "" rows). The
    /// held payload is the DECRYPTED envelope JSON - the v=2 ratchet consumed
    /// the ciphertext at quarantine time, so unlike a cross-island row it can
    /// never be re-fed through ingest. Only content kinds are ever held, so
    /// appendContentMessage covers every possible row; dedup by id makes a
    /// double release harmless. Quiet on purpose: no sound, no badge - the
    /// user is looking at these messages as they land.
    @discardableResult
    func releaseHeldStranger(_ request: CrossIslandRequestsStore.Request) -> Int {
        var released = 0
        for h in request.msgs {
            guard let env = try? JSONDecoder().decode(Envelope.self, from: Data(h.payload.utf8)) else { continue }
            if appendContentMessage(
                inner: env, thread: .peer(uin: request.uin), senderUIN: request.uin,
                isFromMe: false, serverTime: h.sentAt ?? request.firstAt
            ) { released += 1 }
        }
        return released
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
                            cls: rcqMessageClass(envType),
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
            // Only when nothing rescued it above: a copy that landed on another
            // home is a delivered message, not a refusal to explain (#836).
            SendRefusalStore.shared.note(error)
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
        struct Body: Encodable { let to_uin: Int; let envelope_type: String; let cls: Int; let payload: String }
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
                    body: Body(to_uin: c.uin, envelope_type: "homerec", cls: rcqMessageClass("homerec"), payload: blob),
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
        // Stage 2: mirror the island's `_cls_for` so the row is classified by the
        // sender, not guessed. Equals the island's derivation for every type we
        // send today, so push/retention behaviour is unchanged. Additive.
        let cls: Int
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
        // Stage 2: `cls` mirrors the island's `_cls_for` (skdm/sknack -> 2, the
        // rest -> 1); additive, unchanged behaviour for every type sent today.
        struct Body: Encodable { let group_id: Int; let envelope_type: String; let cls: Int; let payloads: [Entry] }
        struct BroadcastBody: Encodable { let group_id: Int; let envelope_type: String; let cls: Int; let payload: String }
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
                            body: Body(group_id: group.id, envelope_type: "skdm", cls: rcqMessageClass("skdm"), payloads: skdmEntries), authenticated: false, retries: 1)
                    }
                }
                out = try await APIClient.shared.request("POST", "/messages/group-broadcast",
                    body: BroadcastBody(group_id: group.id, envelope_type: envType, cls: rcqMessageClass(envType), payload: gmsg), authenticated: true, retries: 2)
                GroupSenderKeyStore.shared.markDistributed(ownUin: ownUIN, gid: group.id, uins: skdmTargets.map { $0.uin })
                GroupSenderKeyStore.shared.advanceOwn(ownUin: ownUIN, gid: group.id)
                // Legacy members (not yet updated) still get their per-member copy.
                let legacy = sendable.filter { !$0.senderKeys }
                if !legacy.isEmpty {
                    var legacyEntries: [Entry] = []
                    for m in legacy { if let e = await legacySeal(m) { legacyEntries.append(e) } }
                    if !legacyEntries.isEmpty {
                        let _: Out = try await APIClient.shared.request("POST", "/messages/group-sealed",
                            body: Body(group_id: group.id, envelope_type: envType, cls: rcqMessageClass(envType), payloads: legacyEntries), authenticated: authPost, retries: 1)
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
                    body: Body(group_id: group.id, envelope_type: envType, cls: rcqMessageClass(envType), payloads: entries), authenticated: authPost, retries: 2)
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
            // The room's own rules land here: the newcomer waiting period and
            // slow mode are both refusals of THIS post, and until #836 they
            // reached the person as a red bubble with no sentence attached.
            SendRefusalStore.shared.note(error)
            throw error
        }
    }

    // MARK: - sender-keys receive helpers

    /// What became of a `gmsg` broadcast on the way in.
    private enum GmsgOpen {
        case opened(DecryptedEnvelope)
        /// The kid is unknown here: a NACK went out (debounced) and the raw
        /// row is worth keeping until the SKDM lands. The room-log drain
        /// holds it; the live socket and the legacy queue leave it for
        /// redelivery as before.
        case keyMissing(kid: String, epoch: Int, index: Int)
        /// My own echo, a replay, an epoch mismatch, a bad signature: no
        /// redelivery will ever open this copy.
        case dropped
    }

    /// Surfaced through `ingest`'s `decryptError` so a caller that acks can
    /// tell "hold this" from "drop this" without opening the wire itself.
    enum GmsgOpenError: Error {
        case keyMissing(kid: String, epoch: Int, index: Int)
    }

    /// Decode a `gmsg` broadcast via the stored chain. `.opened` carries the
    /// inner envelope + real sender; `.dropped` when the message is mine
    /// (carbon handles it), a replay, or unverifiable; `.keyMissing` when it
    /// is pending an SKDM (a NACK is fired then).
    private func openIncomingGmsg(_ payloadB64: String, gid: Int) -> GmsgOpen {
        guard let hdr = SenderKeys.parseGmsgHeader(payloadB64) else { return .dropped }
        if GroupSenderKeyStore.shared.ownsKid(ownUin: ownUIN, hdr.kid) { return .dropped } // my own echoed broadcast
        guard let key = GroupSenderKeyStore.shared.deriveInbound(ownUin: ownUIN, kid: hdr.kid, epoch: hdr.epoch, index: hdr.index) else {
            if !GroupSenderKeyStore.shared.knowsKid(ownUin: ownUIN, hdr.kid) {
                sendSknack(gid: gid, kid: hdr.kid)
                return .keyMissing(kid: hdr.kid, epoch: hdr.epoch, index: hdr.index)
            }
            return .dropped
        }
        guard let opened = SenderKeys.openGmsg(payloadB64, gid: gid, mk: key.mk, expectedSpubB64: key.spub) else { return .dropped }
        guard opened.verified else {
            print("[MessageService] gmsg sig did not verify; dropping gid=\(gid) kid=\(hdr.kid)")
            return .dropped
        }
        return .opened(DecryptedEnvelope(senderUIN: key.senderUin, envelope: opened.envelope))
    }

    /// Replay the broadcasts the room-log drain held for `kid` now that its
    /// SKDM was accepted: each raw row goes back through `ingest`, the normal
    /// decode path, in arrival order. A row that still does not open (the
    /// SKDM was for a newer epoch) is dropped by `openIncomingGmsg` itself
    /// and cannot NACK-storm: the kid is known now. What lands counts as
    /// drained content (unread, badge), never as a banner: it is backlog.
    private func replayHeldGmsg(kid: String) {
        let held = GroupSenderKeyStore.shared.takeHeldGmsg(ownUin: ownUIN, kid: kid)
        for h in held {
            let packet = WebSocketService.EnvelopePacket(
                type: "gmsg", payload: h.payload, serverTime: h.serverTime, offline: true, groupID: h.gid
            )
            // Only new content counts: a held broadcast can be a reaction,
            // a receipt or an edit (every envelope kind rides `gmsg`), or a
            // row another path stored meanwhile, and none of those is an
            // unread message or a number on the icon.
            if let outcome = ingest(envelope: packet), outcome.isNewContent { noteDrainedContent(outcome) }
        }
    }

    /// Per-kid ask ledger: attempts + last ask. The flat ten-minute window
    /// turned a DEAD kid (owner deleted their account; nobody alive can
    /// answer) into a forever machine - one 24/7 install re-asked a
    /// 971-member room every window, 366 whole-room fan-outs in 12h,
    /// measured on prod 30.08. The window doubles per unanswered ask and
    /// past the ladder the kid is written off for a week; an SKDM that
    /// finally lands clears its record. The island additionally budgets
    /// sknack at 10/hour, so an old build in this loop degrades to silence.
    private static var sknackLedger: [String: (n: Int, at: Date)] = [:]
    private static let sknackLadder: [TimeInterval] = [600, 1800, 7200, 21600, 86400]

    private func sknackAllowed(_ kid: String) -> Bool {
        let now = Date()
        guard let rec = Self.sknackLedger[kid] else {
            Self.sknackLedger[kid] = (1, now)
            return true
        }
        let wait = rec.n >= Self.sknackLadder.count ? 7 * 86400 : Self.sknackLadder[rec.n - 1]
        if now.timeIntervalSince(rec.at) < wait { return false }
        Self.sknackLedger[kid] = (min(rec.n + 1, Self.sknackLadder.count + 1), now)
        return true
    }

    func sknackAnswered(_ kid: String) {
        Self.sknackLedger[kid] = nil
    }

    /// Fire one recovery request for an unknown kid to the group's capable
    /// members (we don't know whose kid it is). Ladder-debounced per kid.
    private func sendSknack(gid: Int, kid: String) {
        guard sknackAllowed(kid) else { return }
        struct Entry: Encodable { let to_uin: Int; let payload: String }
        struct Body: Encodable { let group_id: Int; let envelope_type: String; let cls: Int; let payloads: [Entry] }
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
                body: Body(group_id: gid, envelope_type: "sknack", cls: rcqMessageClass("sknack"), payloads: entries), authenticated: false, retries: 0)
        }
    }

    /// Answer a recovery request: if I own this group's chain, re-seal a current
    /// SKDM to the requester so they can read going forward.
    private func answerSknack(gid: Int, requesterUIN: Int, kid: String) {
        guard GroupSenderKeyStore.shared.ownKidForGroup(ownUin: ownUIN, gid: gid) == kid,
              let snap = GroupSenderKeyStore.shared.ownChainSnapshot(ownUin: ownUIN, gid: gid) else { return }
        struct Entry: Encodable { let to_uin: Int; let payload: String }
        struct Body: Encodable { let group_id: Int; let envelope_type: String; let cls: Int; let payloads: [Entry] }
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
                body: Body(group_id: gid, envelope_type: "skdm", cls: rcqMessageClass("skdm"), payloads: [Entry(to_uin: m.uin, payload: blob)]), authenticated: false, retries: 0)
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
                        cls: rcqMessageClass("visit"),
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

    /// Where an inbound disappearing row starts counting from, or nil to keep
    /// counting from the local timestamp the way this client always has.
    ///
    /// `receipt` is what the row's `sentAt` will be: the island's deposit time
    /// for a queued envelope, this instant for anything handed over live.
    ///
    /// ⚠ A `ts` that arrives WITHOUT a `ttl` is ignored. The timer in force is
    /// then the reader's own thread setting, and the sender does not get to
    /// move the start of a clock the reader set for themselves. It also mirrors
    /// the send side, which never writes one without the other.
    nonisolated static func inboundAnchor(envTTL: Int?, ts: Int?, receipt: Date) -> Date? {
        guard envTTL != nil else { return nil }
        return ChatSettingsStore.senderSentAt(ts: ts, receipt: receipt)
    }

    static func messageID(in envelope: Envelope) -> UUID? {
        switch envelope {
        case .text(let id, _, _, _, _, _): return id
        case .photo(let id, _, _, _, _, _, _, _, _, _): return id
        case .video(let id, _, _, _, _, _, _, _, _, _, _, _): return id
        case .voice(let id, _, _, _, _, _, _, _): return id
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
        case .text(_, let text, _, _, _, _): return text
        case .photo(_, _, _, let caption, _, _, _, _, _, _): return caption?.isEmpty == false ? caption! : "📷"
        case .video(_, _, _, _, _, let caption, _, _, _, _, _, _): return caption?.isEmpty == false ? caption! : "🎬"
        case .voice: return "🎤"
        case .file(_, _, _, let fname, _, _, _, _, _, _, _): return "📎 \(fname)"
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
        wantedRequeue = true
        return nil
    }

    /// Raised by `requeueHostlessControl` for the ingest that just ran, and by
    /// nothing else. Cleared at the top of every `ingest`, read by the legacy
    /// queue drain right after.
    ///
    /// ⚠ A nil answer from `ingest` covers two very different things: "opened
    /// it and deliberately kept nothing" (a blocked sender, our own echo) and
    /// "could not deal with it YET". Only the second may not be acked. The
    /// drain used to treat every nil as the second, so a message from someone
    /// the user blocked came back on every single drain until the queue TTL
    /// expired it, thirty days later. `@MainActor` on this class is what makes
    /// one flag enough: an ingest and the read that follows it cannot be
    /// interleaved with another.
    private var wantedRequeue = false

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
        wantedRequeue = false
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
                // Sender-keys broadcast: not a sealed envelope, decoded via the chain.
                guard let gid = ws.groupID else { return nil }
                switch openIncomingGmsg(ws.payload, gid: gid) {
                case .opened(let opened):
                    decrypted = opened
                case .keyMissing(let kid, let epoch, let index):
                    // Named so the room-log drain can hold the row and ack
                    // it; every other caller reads nil as it always did.
                    decryptError = GmsgOpenError.keyMissing(kid: kid, epoch: epoch, index: index)
                    return nil
                case .dropped:
                    return nil
                }
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
                // The same device id checked against the cached device list:
                // one the list does not know is an install the peer linked
                // after we read it, and our next send would skip it for the
                // rest of the list's life. Fire-and-forget into the actor.
                let from = decrypted.senderUIN
                Task { await SignalCryptoService.noteInboundDevice(forPeerUIN: from, deviceId: dev) }
            }

            // Room state key hand-off / ask-back (stage 6 phase 2): the same
            // outer types as the sender-key plumbing, split by inner kind.
            if case .gsKey(let gid, let ver, let key) = decrypted.envelope {
                // Roster gate: only a fellow member's key is worth holding.
                let g = GroupService.shared.groups.first(where: { $0.id == gid })
                let fromMember = g?.members.contains(where: { $0.uin == decrypted.senderUIN }) ?? false
                if fromMember || decrypted.senderUIN == ownUIN {
                    if RoomKeyStore.shared.put(gid, ver: ver, keyB64: key, replaceEqual: true) {
                        Task { await GroupService.shared.refresh() }
                    }
                }
                return IngestOutcome(thread: thread, isNewContent: false, wasInNSECache: fromNSE)
            }
            // Profile key hand-off / ask-back. Same carriers as the room keys
            // above, split by the inner kind.
            if case .pkey(let key) = decrypted.envelope {
                // Filed against the SEALED sender, never against anything the
                // wire claimed - otherwise one account could publish a face as
                // another. Refreshing the roster repaints the avatars.
                if ProfileKeyStore.shared.put(decrypted.senderUIN, keyB64: key) {
                    Task { await ContactService.shared.refresh() }
                }
                return IngestOutcome(thread: thread, isNewContent: false, wasInNSECache: fromNSE)
            }
            if case .pkeyAsk = decrypted.envelope {
                // Only the owner can answer this one, so there is no roster
                // gate: whoever asked either gets my key or nothing.
                if let mine = ProfileKeyStore.shared.mine {
                    Task { [weak self] in
                        await self?.answerProfileKeyAsk(to: decrypted.senderUIN, keyB64: mine)
                    }
                }
                return IngestOutcome(thread: thread, isNewContent: false, wasInNSECache: fromNSE)
            }
            if case .gsKnack(let gid) = decrypted.envelope {
                if let g = GroupService.shared.groups.first(where: { $0.id == gid }),
                   let asker = g.members.first(where: { $0.uin == decrypted.senderUIN }),
                   !asker.identityKey.isEmpty,
                   let held = RoomKeyStore.shared.key(gid) {
                    Task { [weak self] in
                        await self?.answerRoomKeyAsk(gid: gid, held: held, asker: asker)
                    }
                }
                return IngestOutcome(thread: thread, isNewContent: false, wasInNSECache: fromNSE)
            }

            // Sender-keys distribution / recovery (never rendered). SKDM binds
            // the chain to its authenticated sender; SKNACK asks the kid owner to
            // re-distribute. Both ride the per-member sealed path.
            if case .skdm(let gid, let kid, let epoch, let index, let ck) = decrypted.envelope {
                if let sk = decrypted.senderSigningKey,
                   GroupSenderKeyStore.shared.acceptSkdm(ownUin: ownUIN, kid: kid, gid: gid, senderUIN: decrypted.senderUIN, spub: sk, epoch: epoch, index: index, ck: ck) {
                    // The key the held broadcasts were waiting for.
                    sknackAnswered(kid)
                    replayHeldGmsg(kid: kid)
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
                switch inner {
                // Control carbons APPLY to the referenced row instead of being
                // filed as one. An edit made on another of my devices mutates
                // the row here, including an OUTGOING row that device authored;
                // a delete-for-everyone tombstones it. Both are quiet no-ops
                // when the row is unknown, and deleteLocal still records the
                // hidden tombstone so a late redelivery of the deleted message
                // stays dead.
                case .edit(let targetID, let newText):
                    MessageStore.shared.applyEdit(
                        messageID: targetID, thread: dest,
                        newText: newText, editedAt: ws.serverTime
                    )
                case .deleteForEveryone(let targetID):
                    MessageStore.shared.deleteLocal(messageID: targetID, thread: dest)
                case .readMark(let at):
                    // I read this thread on another device (A2): drop the
                    // badge here too, minus whatever landed after that moment.
                    applyRemoteRead(thread: dest, at: at)
                default:
                    appendContentMessage(
                        inner: inner, thread: dest, senderUIN: ownUIN, isFromMe: true, serverTime: ws.serverTime
                    )
                }
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
                case .text(let id, let text, _, _, _, let reply):
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
                case .photo(let id, let mediaID, let mediaKey, let caption, _, _, _, let reply, let album, let spoiler):
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
                case .video(let id, let mediaID, let mediaKey, let thumb, let dur, let caption, _, _, _, let reply, let album, let spoiler):
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
                case .voice(let id, let mediaID, let mediaKey, let dur, _, _, _, let reply):
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
                case .file(let id, let mediaID, let mediaKey, let fname, let mime, let size, let caption, _, _, _, let reply):
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
                case .location(let id, let lat, let lng, let caption, _, _, _, let reply):
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
            // ⚠⚠ Never ourselves, in either gate. A carbon of a message sent
            // from the user's other device arrives FROM the user's own uin, so
            // a single stray entry — the user adding and then removing their
            // own number, Saved Messages, a stale row from an older build —
            // silently kills every own-message sync there is, with nothing on
            // screen to explain it and no way back. Android had exactly this
            // hole and it is the other half of #835.
            let isSelf = decrypted.senderUIN == ownUIN
            let isBlocked = !isSelf
                && (BlockedContactsStore.shared.contains(decrypted.senderUIN) || (senderContact?.blocked ?? false))
            if isBlocked {
                if let messageID = Self.messageID(in: decrypted.envelope), let contact = senderContact {
                    Task { try? await self.sendEnvelope(.bounce(targetID: messageID), to: contact, localID: nil) }
                }
                return nil
            }
            // User removed this contact (ICQ-style mutual delete). Server
            // can't filter sealed messages by sender; we silently drop on
            // ingest so no banner, no sound, no chat-list reappearance.
            if !isSelf, RemovedContactsStore.shared.contains(decrypted.senderUIN) {
                return nil
            }
            // Same-island opt-in stranger quarantine (Privacy -> strangers to
            // requests; default OFF). Mirrors web-chat's stranger-requests.ts:
            // only CONTENT kinds are held (control traffic from an unknown
            // sender flows on and no-ops below - there is no message for it
            // to belong to); never for self, an allowed stranger, a contact,
            // or a peer we ever WROTE to; fail OPEN with no roster. host ""
            // marks a same-island row in the shared request store. Blocked
            // strangers never get this far (the BlockedContactsStore drop
            // above already ate them silently).
            //
            // Placement is load-bearing twice over: ABOVE the auto-surface so
            // a quarantined sender is not upserted into the visible contact
            // list, and returning here also skips the delivered receipt at the
            // bottom ON PURPOSE - a held message must not confirm to a
            // stranger that it landed in front of a human.
            if ws.groupID == nil, Multihome.isOwnHost(decrypted.senderHost),
               StrangerQuarantine.shared.shouldQuarantine(
                   myUIN: ownUIN, senderUIN: decrypted.senderUIN, envelope: decrypted.envelope
               ),
               let plain = try? JSONEncoder().encode(decrypted.envelope) {
                CrossIslandRequestsStore.shared.hold(
                    uin: decrypted.senderUIN, host: "",
                    payload: String(decoding: plain, as: UTF8.self),
                    preview: Self.requestPreview(for: decrypted.envelope),
                    sentAt: ws.serverTime
                )
                // Held and persisted - ACK the queue row; no badge, no banner.
                return IngestOutcome(thread: thread, isNewContent: false, wasInNSECache: fromNSE)
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
            case .text(let id, let text, let envTTL, let ts, let fwd, let reply):
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
                    senderSentAt: Self.inboundAnchor(envTTL: envTTL, ts: ts, receipt: ws.serverTime),
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
            case .photo(let id, let mediaID, let mediaKey, let caption, let envTTL, let ts, let fwd, let reply, let album, let spoiler):
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
                    senderSentAt: Self.inboundAnchor(envTTL: envTTL, ts: ts, receipt: ws.serverTime),
                    forwardedFromName: fwd,
                    replyToID: reply?.id,
                    replyToSnippet: reply?.snippet,
                    replyToAuthorName: reply?.authorName,
                    albumID: album,
                    isSpoiler: spoiler
                ))
            case .video(let id, let mediaID, let mediaKey, let thumb, let dur, let caption, let envTTL, let ts, let fwd, let reply, let album, let spoiler):
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
                    senderSentAt: Self.inboundAnchor(envTTL: envTTL, ts: ts, receipt: ws.serverTime),
                    forwardedFromName: fwd,
                    replyToID: reply?.id,
                    replyToSnippet: reply?.snippet,
                    replyToAuthorName: reply?.authorName,
                    albumID: album,
                    isSpoiler: spoiler
                ))
            case .voice(let id, let mediaID, let mediaKey, let dur, let envTTL, let ts, let fwd, let reply):
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
                    senderSentAt: Self.inboundAnchor(envTTL: envTTL, ts: ts, receipt: ws.serverTime),
                    forwardedFromName: fwd,
                    replyToID: reply?.id,
                    replyToSnippet: reply?.snippet,
                    replyToAuthorName: reply?.authorName
                ))
            case .file(let id, let mediaID, let mediaKey, let fname, let mime, let size, let caption, let envTTL, let ts, let fwd, let reply):
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
                    senderSentAt: Self.inboundAnchor(envTTL: envTTL, ts: ts, receipt: ws.serverTime),
                    forwardedFromName: fwd,
                    replyToID: reply?.id,
                    replyToSnippet: reply?.snippet,
                    replyToAuthorName: reply?.authorName,
                    fileName: fname,
                    fileMime: mime,
                    fileSizeBytes: size
                ))
            case .location(let id, let lat, let lng, let caption, let envTTL, let ts, let fwd, let reply):
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
                    senderSentAt: Self.inboundAnchor(envTTL: envTTL, ts: ts, receipt: ws.serverTime),
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
                // The window is read on demand; a retraction can land in a
                // chat nobody has opened this session, and the authorisation
                // check below needs the target row.
                MessageStore.shared.ensureLoaded(thread)
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
            case .poll(let id, _, _, _, _, _):
                // Polls are removed (14a) and the island now answers 410
                // feature_removed, so there is no tally to fetch and no ballot
                // to cast. A peer on an old build still sends them, though, and
                // a removed feature has to ANSWER rather than vanish: the row is
                // still filed, still in the right place in the thread, and
                // `MessageRow` draws it as "no longer supported".
                //
                // Nothing off the wire is kept. The question and the options
                // used to be re-encoded into `text` as JSON for the bubble to
                // parse; nothing parses it any more, and storing the body of a
                // feature we just took away would only be a thing to leak.
                inserted = MessageStore.shared.append(Message(
                    id: id,
                    thread: thread,
                    senderUIN: decrypted.senderUIN,
                    isFromMe: decrypted.senderUIN == ownUIN,
                    kind: .poll, text: "",
                    sentAt: ws.serverTime,
                    deliveryState: .delivered,
                    receivedWhileAway: ws.offline
                ))
            case .relayShare(let id, let relay, _):
                // In-chat bridge sharing: a contact handed us a relay to augment
                // our transport pool. Store the rcq-relay:// token in `text`;
                // ChatView renders it as an Add card.
                //
                // ⚠ A descriptor THIS build cannot parse (a transport added
                // after it shipped, a vless row with no uuid) still gets a row,
                // with an empty token: `RelayShareBubble` draws it as
                // "relay.share.invalid". Returning nil here instead used to
                // mean the offline drain read it as "do not ACK", so the island
                // handed the same row back on every reconnect until the queue
                // TTL, while the user was told nothing and lost a relay they
                // were handed.
                let token = ContactRelayStore.relayFromWire(relay)
                    .map { ContactRelayStore.relayToToken($0) } ?? ""
                inserted = MessageStore.shared.append(Message(
                    id: id,
                    thread: thread,
                    senderUIN: decrypted.senderUIN,
                    isFromMe: decrypted.senderUIN == ownUIN,
                    kind: .relay, text: token,
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
            case .readMark:
                // A2 marker: only ever arrives WRAPPED in a carbon, which is
                // intercepted above. A bare one is not something any client
                // sends, so it files nothing.
                break
            case .gsKey, .gsKnack:
                // Stage 6 phase 2: intercepted before this switch (the room
                // key branch). Present only for exhaustiveness.
                break
            case .pkey, .pkeyAsk:
                // Profile keys: intercepted before this switch, same as the
                // room keys above. Present only for exhaustiveness.
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
               let insertedID = MessageStore.shared.messages(for: thread).last?.id {
                if drainBatch != nil {
                    // Inside a drain page: collect, and confirm the whole page
                    // to each peer in ONE envelope when it ends. A backlog of
                    // fifty messages used to be fifty seals and fifty POSTs,
                    // fired from inside the loop that was already holding the
                    // main actor. `.deliveredReceipt` has always carried a
                    // list; nothing on the wire changes.
                    drainBatch?.receipts[peerUIN, default: []].append(insertedID)
                } else if let contact = ContactService.shared.contacts.first(where: { $0.uin == peerUIN }) {
                    Task { [weak self] in
                        try? await self?.sendEnvelope(
                            .deliveredReceipt(targetIDs: [insertedID]), to: contact, localID: nil
                        )
                    }
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

    /// Envelope types whose value is the MOMENT, not the payload: losing one
    /// costs nothing a user could point at, so an undecryptable copy is
    /// buried rather than redelivered for 30 days.
    private static let ephemeralControlTypes: Set<String> = ["visit", "read", "sknack", "secscreen", "bounce"]

    private static func isEphemeralControlType(_ t: String) -> Bool {
        ephemeralControlTypes.contains(t)
    }

    /// A failure no redelivery can ever fix, on ANY device. The founder's
    /// 31.08 log showed the cost of hoarding these: dozens of rows failing
    /// with missingSignedPreKey(1) / missingPreKey / "decryption failed" /
    /// an OLD client's `read` without `targetIDs` were refetched, re-parsed
    /// and re-failed on EVERY app open, for up to 30 days, and the drain
    /// re-chewing them was a visible part of "тянет все данные каждый раз".
    ///
    /// What qualifies, and why it is safe to bury each:
    /// - a prekey/signed-prekey the envelope was sealed for no longer
    ///   exists locally: the ratchet cannot regress, redelivery replays the
    ///   exact same bytes into the exact same wall;
    /// - libsignal `invalidMessage` (a Whisper/PreKey message that does not
    ///   decrypt): out-of-order delivery is already covered by the message
    ///   key cache, so what remains is a copy for keys we will never hold;
    /// - `DecodingError`: the DECRYPT SUCCEEDED and the inner payload is a
    ///   schema this build cannot parse - the bytes will parse the same way
    ///   tomorrow.
    /// Held gmsg (keyMissing) never reaches this: the drain parks those for
    /// replay before the generic failure path.
    private static func isPermanentlyUnreadable(_ error: Error) -> Bool {
        if error is DecodingError { return true }
        if let storeError = error as? SignalProtocolStoreError {
            switch storeError {
            case .missingPreKey, .missingSignedPreKey, .missingKyberPreKey:
                return true
            case .noLocalIdentity:
                // Transient by design: the store is closed while PIN-locked.
                return false
            }
        }
        if let signalError = error as? SignalError, case .invalidMessage = signalError {
            return true
        }
        return false
    }

    // MARK: - one drain at a time

    /// The tail of the chain of drains of this island's mailbox. Every drain
    /// runs on it, one after another: the legacy queue and then the room
    /// log, never two side by side. Each reader moves the island's cursors
    /// for the rows IT was served, and two readers of one cursor is how a
    /// row gets acked that only the other one has seen. Each caller waits
    /// for its own drain, so a push wake still returns when its rows are in
    /// (the background budget is spent on that). Never awaited from inside
    /// `ingest`: the drain would be waiting on itself.
    private var drainTail: Task<Void, Never>?

    /// One uninterrupted stretch of a drain is bounded by a CLOCK, not a row
    /// count (D3). A fixed 25 rows was "a frame's worth of work" only for the
    /// envelopes it was measured on: a chunk of sender-keys rows with cold
    /// sessions runs several times longer, and a page of them froze the chat
    /// list on entry exactly the way the unchunked drain used to. The chunk
    /// now ends when the clock says the frame is spent. The floor keeps the
    /// per-chunk costs (one fsync, one roster publish, one icon write)
    /// amortised over real work when every row is expensive; the ceiling
    /// keeps a chunk of trivial rows from holding a transaction open long.
    private static let drainChunkMaxRows = 25
    private static let drainChunkMinRows = 4
    private static let drainChunkBudgetNs: UInt64 = 12_000_000

    /// What a page of a drain owes the rest of the app, held until the page
    /// ends instead of being paid per row.
    ///
    /// Every one of these was a full round trip of its own: `incrementUnread`
    /// republishes the whole roster (and the chat list re-partitions it in
    /// `body`), `BadgeCounter.increment` rewrites a JSON file in the App Group,
    /// `syncIcon` reads it back, and the delivered receipt was one sealed
    /// envelope and one POST **per message**. Paid once per page they are the
    /// same numbers on screen and one round trip each.
    private struct DrainBatch {
        /// Message ids to confirm receipt of, per peer.
        var receipts: [Int: [UUID]] = [:]
        var peerUnread: [Int: Int] = [:]
        var groupUnread: [Int: Int] = [:]
        /// App-icon slots, keyed the way `BadgeCounter` keys them.
        var badge: [String: Int] = [:]
    }

    /// Non-nil only while a drain page is being walked. `ingest` and
    /// `noteDrainedContent` read it to decide between accumulating and acting;
    /// the live socket path never sees one, so live delivery is unchanged.
    ///
    /// Protected by the main actor: `MessageService` is `@MainActor`, every
    /// writer of this property is a synchronous stretch between suspension
    /// points, and `serialisedDrain` guarantees only one drain walks a page at
    /// a time.
    private var drainBatch: DrainBatch?

    /// Returns true when THIS caller opened the page. A caller that did not
    /// must neither flush nor discard it: the scope that opened it will.
    private func beginDrainBatch() -> Bool {
        guard drainBatch == nil else { return false }
        drainBatch = DrainBatch()
        return true
    }

    /// Throw the chunk's bookkeeping away without applying it. Only for a
    /// chunk that never reached disk (the fetch itself threw): a chunk that
    /// did is flushed before the drain yields, precisely because a discard
    /// after `MessageDB.endBatch` is unrecoverable. Redelivery does not undo
    /// it — `insertIfAbsent` recognises the row, `isNewContent` comes back
    /// false, and the unread bump the discard dropped is never made again.
    private func discardDrainBatch(_ owns: Bool) {
        guard owns else { return }
        drainBatch = nil
    }

    /// Apply everything the page accumulated, in one pass each.
    private func flushDrainBatch(_ owns: Bool) {
        guard owns, let batch = drainBatch else { return }
        drainBatch = nil
        ContactService.shared.applyUnreadDeltas(batch.peerUnread)
        GroupService.shared.applyUnreadDeltas(batch.groupUnread)
        if !batch.badge.isEmpty {
            BadgeCounter.increment(deltas: batch.badge)
            BadgeCounter.syncIcon()
        }
        for (peerUIN, ids) in batch.receipts {
            guard !ids.isEmpty,
                  let contact = ContactService.shared.contacts.first(where: { $0.uin == peerUIN })
            else { continue }
            Task { [weak self] in
                try? await self?.sendEnvelope(
                    .deliveredReceipt(targetIDs: ids), to: contact, localID: nil
                )
            }
        }
    }

    /// Run `body` as the next link of the one drain chain, and hand back what
    /// it returned.
    ///
    /// This is what makes `drainBatch` safe: exactly one drain walks a page at
    /// a time. Not private, because a drain does not have to live in this type
    /// — the room logs on a visited island and on a backup home are walked by
    /// `CrossIslandGroups`, against the same single batch slot, and used to run
    /// beside the queue drain from `Multihome`'s poll loop.
    func serialisedDrain<T: Sendable>(_ body: @escaping @MainActor () async -> T) async -> T {
        let previous = drainTail
        let work = Task { @MainActor () -> T in
            await previous?.value
            return await body()
        }
        // The tail is what the NEXT link waits on, and it has to be Void to
        // chain links that return different things.
        drainTail = Task { @MainActor in _ = await work.value }
        return await work.value
    }

    /// Drain this island's mailbox: the legacy queue, then (Stage 5) the
    /// room log on an island that keeps one. Serialised; see above.
    func fetchOfflineQueue() async {
        await serialisedDrain { await self.drainQueueThenLog() }
    }

    private func drainQueueThenLog() async {
        if PanicPINService.shared.isLocked || PanicPINService.shared.isDecoy { return }
        // Multihoming v1: make sure the backup-island poll is running (no-op
        // without backup homes; idempotent). Independent of the primary fetch
        // below: when the primary island is down, that loop IS delivery.
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
            // Stage 2: the island now serves a retention/push class and a durable
            // per-mailbox sequence alongside the legacy fields. Both optional so an
            // older island (or the federation queue) that omits them still decodes.
            // The cursor and ack stay on `id` (below); `seq` is a stable ordering
            // token captured for future dedup, never a contiguity check. A gap in
            // `seq` is NORMAL (one deposit per recipient device draws from the one
            // mailbox counter, and this device drains only its own rows), so it is
            // never treated as a missed message.
            let cls: Int?
            let seq: Int?
        }
        let myDeviceId = SignalProtocolStores.shared.localDeviceId
        var ownsBatch = false
        do {
            // Which account this drain belongs to. Checked again after every
            // pause below: the loop is no longer atomic on the main actor, and
            // a switch mid-drain must not credit these rows, these counters or
            // this ACK to whoever is signed in now.
            //
            // ⚠ Captured BEFORE the fetch, never after it. Read afterwards,
            // both of these name whoever is signed in when the reply lands,
            // so a page belonging to the outgoing account arrives already
            // stamped with the incoming one and every check below compares it
            // against itself and passes. That is not theory: `contactreq`
            // rows walk straight into the account that never asked for them
            // (founder, 30.08). The fetch is the longest pause in the whole
            // function, which makes it the likeliest place to be switched
            // under, not the safest.
            //
            // ⚠ The account id, not `ownUIN`, is what answers that question.
            // `AccountManager.setActive` rebinds the id BEFORE the reboot
            // repoints MessageDB at the next account's SQLite file, while
            // `MessageService.configure(ownUIN:)` is not reached until well
            // inside the following `boot()`, so for the whole of that window
            // `ownUIN` still reads as the outgoing account and waves the drain
            // straight into the incoming account's store. (Two accounts on two
            // islands can also carry the same uin, which `ownUIN` cannot tell
            // apart at all.) Kept alongside it rather than instead of it: uin 0
            // means "no identity yet" and is worth catching too.
            let account = ownUIN
            let accountID = AccountManager.shared.activeAccountID
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
            // Back from the longest pause in the function. These rows were
            // asked for by whoever was signed in above; if that is no longer
            // who is signed in now, they belong to nobody here. Dropping them
            // costs nothing: without an ACK the island holds them, and the
            // account that owns them collects them on its own next drain.
            guard ownUIN == account,
                  AccountManager.shared.activeAccountID == accountID,
                  !PanicPINService.shared.isLocked,
                  !PanicPINService.shared.isDecoy
            else { return }
            var sawUnknownPeer = false
            // Track which rows landed locally so we can ACK them. Two
            // arrays because OfflineMessage.id and OfflineGroupMessage.id
            // are per-table auto-increment integers on the server and
            // can collide; we split by group_id.
            var ackedDirectIDs: [Int] = []
            var ackedGroupIDs: [Int] = []
            var cursor = 0
            while cursor < rows.count {
                // Per CHUNK, not per page: what the chunk owes the rest of the
                // app is paid as soon as its rows are on disk (below), because
                // anything still owed when the drain is interrupted can never
                // be paid later. See `discardDrainBatch`.
                ownsBatch = beginDrainBatch()
                // One SQLite transaction, and one fsync, for the whole chunk.
                // Opened and closed inside the synchronous stretch: a batch is
                // never left open across a suspension point, so nothing that
                // lands from the socket while this drain waits can be acked to
                // the island while it is still only in a context.
                MessageDB.shared.beginBatch()
                // The cursor moves at the TOP of the iteration, so every
                // `continue` below has already paid it; the clock decides at
                // the bottom whether the chunk goes on. See drainChunkBudgetNs.
                let chunkT0 = DispatchTime.now().uptimeNanoseconds
                var chunkRows = 0
                while cursor < rows.count, chunkRows < Self.drainChunkMaxRows {
                    let r = rows[cursor]
                    cursor += 1
                    chunkRows += 1
                    defer {
                        if chunkRows >= Self.drainChunkMinRows,
                           DispatchTime.now().uptimeNanoseconds - chunkT0 > Self.drainChunkBudgetNs {
                            // Budget spent: fall out of the row loop at the
                            // bottom of this iteration.
                            chunkRows = Self.drainChunkMaxRows
                        }
                    }
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
                        if decryptError == nil, !wantedRequeue {
                            // Opened fine, and we deliberately kept nothing: a
                            // blocked or removed sender, a quarantined stranger,
                            // our own echo. There is nothing a later drain would
                            // do differently, so acking is not a loss — and NOT
                            // acking meant the island handed the same row back on
                            // every drain for the thirty days of the queue TTL.
                            // `wantedRequeue` is the one deliberate drop that has
                            // to stay: a cross-island control envelope still
                            // waiting for its `from_host`.
                            if r.group_id == nil { ackedDirectIDs.append(r.id) } else { ackedGroupIDs.append(r.id) }
                        } else if let decryptError, Self.isUnreadableHere(decryptError),
                           r.to_device_id == nil, r.group_id == nil, myDeviceId != 1 {
                            ackedDirectIDs.append(r.id)
                        } else if let decryptError, Self.isPermanentlyUnreadable(decryptError) {
                            // Bury what no redelivery can fix (see the
                            // classifier) instead of re-chewing it every open.
                            if r.group_id == nil { ackedDirectIDs.append(r.id) } else { ackedGroupIDs.append(r.id) }
                        } else if Self.isEphemeralControlType(r.envelope_type) {
                            // An undecryptable CONTROL envelope is dead weight
                            // whatever the error: a visit ping, a read marker
                            // or a recovery ask from days ago carries nothing
                            // a user could miss, and hoarding six of them was
                            // six re-decrypt failures on every single open
                            // (the founder's 31.08 log, type=sknack rows).
                            if r.group_id == nil { ackedDirectIDs.append(r.id) } else { ackedGroupIDs.append(r.id) }
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
                    if case .peer(let uin) = outcome.thread,
                       !ContactService.shared.contacts.contains(where: { $0.uin == uin }) {
                        sawUnknownPeer = true
                    }
                    // Unread + app-icon bookkeeping, accumulated for the page
                    // rather than applied per row. See `noteDrainedContent`.
                    noteDrainedContent(outcome)
                }
                MessageDB.shared.endBatch()
                // The counters and the receipts for the rows that just went to
                // disk, before anything can interrupt the walk. Batched over
                // the chunk (one roster publish, one icon write, one receipt
                // envelope per peer) rather than over the whole page: a page's
                // worth of bookkeeping held across a suspension point is a
                // page's worth of unread counts lost the moment the drain has
                // to give up, and redelivery cannot bring them back.
                flushDrainBatch(ownsBatch)
                ownsBatch = false
                // No early `break` on the last chunk, deliberately. Skipping
                // out here to save one `Task.yield()` also skipped the account
                // check below, so a page that fitted in a single chunk was
                // ingested and ACKed without ever being checked, and the ACK
                // itself (a second network call, with the CURRENT token and
                // base URL) went out on behalf of whoever was signed in by
                // then. The empty final pass costs a frame; the check it
                // carries is what stops the ACK crossing accounts.
                // Hand the main actor back so the interface can draw a frame
                // between chunks. This is the whole point: the loop used to
                // run to the end without a single suspension point, which is
                // exactly as long as the chat list was frozen for.
                await Task.yield()
                // Back on the main actor, but not necessarily in the same
                // world. An account switch rebinds the token and reopens
                // MessageDB on another file; the decoy swaps the store out
                // from under us; a panic-PIN lock drops the data key while
                // leaving the REAL store in place, so every field written from
                // here on would go to disk in plaintext (`sealField` with a nil
                // key is a passthrough) into the very file the PIN exists to
                // seal. Either way these rows belong to a session that no
                // longer exists: stop, and leave the rest queued for the drain
                // that follows. Everything already on disk has been accounted
                // for above; nothing is left to discard.
                guard ownUIN == account,
                      AccountManager.shared.activeAccountID == accountID,
                      !PanicPINService.shared.isLocked,
                      !PanicPINService.shared.isDecoy
                else { return }
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
        } catch {
            // The only throwing call is the fetch, above the loop, so today
            // there is no open chunk here; this keeps one from outliving the
            // drain if that ever stops being true.
            discardDrainBatch(ownsBatch)
        }
        // Stage 5: rooms on an island that keeps a log per room are drained
        // from it, next to the queue above rather than instead of it. Both
        // are read on every drain: the queue still carries 1:1 rows and the
        // room rows written before this account read the log for the first
        // time. A failed queue fetch does not skip the log.
        await drainOwnGroupLogIfAdvertised()
    }

    // MARK: - Stage 5: the room log

    /// One row of a room's log, as served by /messages/group-log/fetch.
    /// Same envelope types and payloads as the legacy group rows of
    /// /messages/queue: `gmsg` broadcasts plus the rows sealed to this member
    /// (`skdm`, `sknack`, `reaction`, legacy per-member `message`...).
    struct GroupLogRow: Decodable {
        let gid: Int
        let seq: Int
        let envelope_type: String
        let cls: Int?
        let payload: String
        let received_at: Date
    }

    /// The log position this device is known to stand at, per room, on our
    /// own island: the fetch's `cursors`, our own acks, and after a complete
    /// drain the island's `heads`. Only a live frame reads it, to decide
    /// whether its `seq` is the very next one and may be acked on the spot.
    /// The island's cursor is authoritative; this is a local echo of it and
    /// is dropped with the account. Keyed by LOCAL group id (own island only:
    /// the live socket is ours).
    private var groupLogAcked: [Int: Int] = [:]
    /// Live acks coalesce for a moment so a burst of posts is one call.
    private var pendingLiveAcks: [Int: Int] = [:]
    private var liveAckFlush: Task<Void, Never>?

    /// A row that keeps failing to open and so pins its room's cursor. One
    /// per LOCAL room (a foreign room lives under a negative alias, so one
    /// map serves every island). `drain` is the last drain that counted it:
    /// a blocked row is re-served on every page of a drain, and a page is
    /// not a new attempt.
    private struct GroupLogStall {
        let seq: Int
        /// How it failed, so a row that starts failing differently starts
        /// its count over.
        let way: String
        var strikes: Int
        var drain: Int
    }
    private var groupLogStalls: [Int: GroupLogStall] = [:]
    private var groupLogDrainSerial = 0
    /// Consecutive drains a row may fail the same way before this device
    /// gives up on it and moves the cursor past it.
    private static let groupLogStrikeLimit = 3

    /// Name one drain: one walk of an island's log pages. Handed to
    /// `ingestGroupLogRows` so a blocked row is struck once per drain.
    func beginGroupLogDrain() -> Int {
        groupLogDrainSerial += 1
        return groupLogDrainSerial
    }

    /// What a page of log rows came to, keyed by the ISLAND's room id (the
    /// one it acks by): per room the seq the cursor may move to, and the
    /// rooms a row stopped in front of.
    struct GroupLogIngest {
        var upto: [Int: Int] = [:]
        var blocked = Set<Int>()
    }

    /// The room log alone, on the same chain as the full drain and never
    /// beside it. For the moments the queue need not be read again: a room
    /// just joined or created, whose cursor should exist on the island
    /// before anyone posts in it (the island seeds it on membership; this
    /// is the cheap second line).
    func fetchGroupLog() async {
        await serialisedDrain { await self.drainOwnGroupLogIfAdvertised() }
    }

    /// Drain every room's log on our own island, then ack what landed.
    /// A no-op on an island that does not advertise `group_log`: such an
    /// island keeps serving room rows through /messages/queue and must never
    /// see these calls. Runs only from the drain chain (see `serialisedDrain`).
    private func drainOwnGroupLogIfAdvertised() async {
        guard AppState.shared.serverCapabilities.groupLog else { return }
        if PanicPINService.shared.isLocked || PanicPINService.shared.isDecoy { return }
        struct FetchIn: Encodable { let limit: Int }
        struct FetchOut: Decodable {
            let rows: [GroupLogRow]
            // JSON objects keyed by the room id as a string. Decoded as
            // [String: Int] on purpose: JSONDecoder reads [Int: Int] from an
            // ARRAY of alternating keys and values, not from an object.
            let heads: [String: Int]
            let cursors: [String: Int]
            let more: Bool
        }
        // `rooms` omitted = every room this account is in, from the island's
        // stored cursor for this device: one round trip for all rooms. A
        // device's first read of a room starts at its head (no backlog for a
        // fresh install), the same rule as the 1:1 watermark.
        //
        // The loop continues while the island says `limit` cut it short, but
        // only while an ack moved a cursor: the fetch reads from the island's
        // cursor, so a pass that acked nothing, or whose ack did not land,
        // would read the same rows again. Twenty pages is the most one drain
        // walks; the next drain picks up a deeper backlog.
        // Pinned to the account the drain started for: a switch while a
        // page is in flight rebinds the token and empties the marks, and a
        // page read under the old account must not write marks, or acks,
        // under the new one.
        let account = ownUIN
        let drain = beginGroupLogDrain()
        var blockedRooms = Set<Int>()
        var passes = 0
        while passes < 20 {
            passes += 1
            let out: FetchOut
            do {
                out = try await APIClient.shared.request(
                    "POST", "/messages/group-log/fetch", body: FetchIn(limit: 500)
                )
            } catch {
                return
            }
            guard ownUIN == account else { return }
            for (gid, cursor) in out.cursors {
                if let id = Int(gid) { groupLogAcked[id] = max(groupLogAcked[id] ?? 0, cursor) }
            }
            let got = await ingestGroupLogRows(out.rows, drain: drain)
            // The walk above can now be interrupted by an account switch, and
            // the marks and acks below are per account.
            guard ownUIN == account else { return }
            blockedRooms.formUnion(got.blocked)
            let advancing = got.upto.filter { $0.value > (out.cursors[String($0.key)] ?? 0) }
            if !advancing.isEmpty {
                // An ack that did not land ends the drain rather than
                // re-fetching the same page: the rows are on disk, the
                // island serves them once more next time, the dedupe absorbs
                // the repeat.
                guard await ackGroupLog(advancing), ownUIN == account else { return }
                for (gid, upto) in advancing { groupLogAcked[gid] = max(groupLogAcked[gid] ?? 0, upto) }
            }
            if !out.more {
                // A complete drain: this device now stands at the head of
                // every room, not merely at the last row it was served. Rows
                // sealed to OTHER members take seqs on the same axis and are
                // never served here, so the head is usually past our last
                // row, and a live frame right behind the head would
                // otherwise look like a gap forever. A room a row is still
                // blocking keeps its mark at the ack: a live ack past the
                // head would bury that row under the cursor.
                for (gid, head) in out.heads {
                    guard let id = Int(gid), !blockedRooms.contains(id) else { continue }
                    groupLogAcked[id] = max(groupLogAcked[id] ?? 0, head)
                }
                return
            }
            // `more` with nothing acked: the island would hand out this very
            // page again.
            if advancing.isEmpty { return }
        }
    }

    /// Feed log rows through the SAME ingest as the legacy group rows of the
    /// queue (decrypt, dedupe by message UUID, store, unread). EVERY row is
    /// ingested, as on the legacy drain: a row that fails to open stops only
    /// the ack behind it, never the rows behind it, which land now and are
    /// absorbed by the UUID dedupe and the chain position when the island
    /// serves them again. Returns, per room, the seq the room's cursor may
    /// move to: the highest seq of the CONTIGUOUS handled prefix, in the
    /// spirit of the legacy ack. A row is handled when it was persisted,
    /// recognised as a duplicate, dropped for good (own echo, replay), or a
    /// `gmsg` whose sender key has not arrived: that one is held on disk and
    /// replayed when its SKDM lands, so it never pins the room's cursor. A
    /// row that failed to open for any other reason is re-served in front
    /// of the cursor on the next drain; once it has failed the same way on
    /// `groupLogStrikeLimit` consecutive drains it is taken as unreadable
    /// on this device and acked, so one bad row never silences a room (nor,
    /// past a page of its room, every room with a higher id).
    /// `localGid` maps the island's room id to the id the rest of the app
    /// files the thread under (a foreign room lives under a negative alias);
    /// the returned acks are keyed by the ISLAND's id, the one it acks by.
    ///
    /// Walked in chunks with the main actor handed back between them, and with
    /// one SQLite transaction and one round of counter bookkeeping per chunk:
    /// a log page is up to five hundred rows, and running all of them without
    /// a suspension point is the same freeze the legacy queue drain used to
    /// be. An account switch (or the decoy store swapping in) mid-walk ends
    /// the page and reports NOTHING handled, so the caller acks nothing under
    /// a session these rows do not belong to.
    func ingestGroupLogRows(_ rows: [GroupLogRow], drain: Int, localGid: (Int) -> Int = { $0 }) async -> GroupLogIngest {
        var result = GroupLogIngest()
        var seen: [Int: Int] = [:]   // island gid -> local gid, for the stall bookkeeping
        // See the queue drain: the account ID is the token that moves when the
        // account does, `ownUIN` lags it by most of a boot.
        let account = ownUIN
        let accountID = AccountManager.shared.activeAccountID
        var cursor = 0
        while cursor < rows.count {
            // Per chunk, flushed as soon as the chunk is on disk. See the
            // queue drain and `discardDrainBatch`. Clock-bounded like the
            // queue drain (D3): the cursor moves at the top so `continue`
            // is safe, the clock decides at the bottom.
            let ownsBatch = beginDrainBatch()
            MessageDB.shared.beginBatch()
            let chunkT0 = DispatchTime.now().uptimeNanoseconds
            var chunkRows = 0
            while cursor < rows.count, chunkRows < Self.drainChunkMaxRows {
                let r = rows[cursor]
                cursor += 1
                chunkRows += 1
                defer {
                    if chunkRows >= Self.drainChunkMinRows,
                       DispatchTime.now().uptimeNanoseconds - chunkT0 > Self.drainChunkBudgetNs {
                        chunkRows = Self.drainChunkMaxRows
                    }
                }
                let gid = localGid(r.gid)
                seen[r.gid] = gid
                let env = WebSocketService.EnvelopePacket(
                    type: r.envelope_type, payload: r.payload, serverTime: r.received_at,
                    offline: true, groupID: gid
                )
                var decryptError: Error?
                let outcome = ingest(envelope: env, decryptError: &decryptError)
                var handled = outcome != nil || decryptError == nil
                if !handled, r.envelope_type == "gmsg",
                   case .keyMissing(let kid, let epoch, let index)? = decryptError as? GmsgOpenError {
                    GroupSenderKeyStore.shared.holdGmsg(ownUin: ownUIN, .init(
                        gid: gid, kid: kid, epoch: epoch, index: index, payload: r.payload, serverTime: r.received_at
                    ))
                    handled = true
                }
                if !handled, !result.blocked.contains(r.gid), let error = decryptError {
                    // The row in front of this room's cursor. Later failures in
                    // the same room are behind it and get their own turn once
                    // the cursor reaches them.
                    handled = strikeGroupLogRow(localGid: gid, seq: r.seq, error: error, drain: drain)
                }
                if handled, !result.blocked.contains(r.gid) {
                    result.upto[r.gid] = max(result.upto[r.gid] ?? 0, r.seq)
                } else if !handled {
                    result.blocked.insert(r.gid)
                }
                if let outcome, outcome.isNewContent { noteDrainedContent(outcome) }
            }
            MessageDB.shared.endBatch()
            flushDrainBatch(ownsBatch)
            guard cursor < rows.count else { break }
            await Task.yield()
            // The account switched, the decoy store came up, or the panic PIN
            // locked and took the data key with it (leaving the real store in
            // place, so every further write would land in plaintext). Give the
            // page up; the island still holds its cursor, so the drain that
            // follows re-reads from here.
            guard ownUIN == account,
                  AccountManager.shared.activeAccountID == accountID,
                  !PanicPINService.shared.isLocked,
                  !PanicPINService.shared.isDecoy
            else { return GroupLogIngest() }
        }
        // A room whose page went through whole has nothing in front of its
        // cursor any more: whatever was counted against it opened, or the
        // island no longer serves it.
        for (islandGid, gid) in seen where !result.blocked.contains(islandGid) {
            groupLogStalls[gid] = nil
        }
        return result
    }

    /// A row in front of its room's cursor failed to open. Counted once per
    /// drain; on the `groupLogStrikeLimit`th consecutive drain it fails the
    /// same way, it is given up on here. Returns true when the row is to be
    /// acked past as unreadable on this device.
    private func strikeGroupLogRow(localGid gid: Int, seq: Int, error: Error, drain: Int) -> Bool {
        let way = String(describing: error)
        let stall: GroupLogStall
        if var known = groupLogStalls[gid], known.seq == seq, known.way == way {
            if known.drain != drain {
                known.strikes += 1
                known.drain = drain
            }
            stall = known
        } else {
            stall = GroupLogStall(seq: seq, way: way, strikes: 1, drain: drain)
        }
        guard stall.strikes >= Self.groupLogStrikeLimit else {
            groupLogStalls[gid] = stall
            return false
        }
        os_log(
            "group log: row gid=%d seq=%d failed the same way on %d drains, unreadable here, acking past it",
            log: Self.log, type: .error, gid, seq, stall.strikes
        )
        groupLogStalls[gid] = nil
        return true
    }

    /// Unread and app-icon bookkeeping for content a drain (not the live
    /// socket) landed: the chat list counter and the icon, never a banner or
    /// a sound, the same as the legacy queue drain does for its rows.
    private func noteDrainedContent(_ outcome: IngestOutcome) {
        let viewing = MessageBannerService.shared.isViewing(outcome.thread)
        guard !viewing else { return }
        // BadgeCounter (the app-icon counter) was already bumped by the NSE
        // for any message the user got a push for. Only envelopes that landed
        // strictly via socket or queue, with no push, are counted here.
        let bumpIcon = !outcome.wasInNSECache
        if drainBatch != nil {
            switch outcome.thread {
            case .peer(let uin):
                drainBatch?.peerUnread[uin, default: 0] += 1
                if bumpIcon { drainBatch?.badge[BadgeCounter.threadKey(peerUIN: uin), default: 0] += 1 }
            case .group(let id):
                drainBatch?.groupUnread[id, default: 0] += 1
                if bumpIcon { drainBatch?.badge[BadgeCounter.threadKey(groupID: id), default: 0] += 1 }
            }
            return
        }
        switch outcome.thread {
        case .peer(let uin):
            ContactService.shared.incrementUnread(for: uin)
            if bumpIcon {
                BadgeCounter.increment(threadKey: BadgeCounter.threadKey(peerUIN: uin))
            }
        case .group(let id):
            GroupService.shared.incrementUnread(id)
            if bumpIcon {
                BadgeCounter.increment(threadKey: BadgeCounter.threadKey(groupID: id))
            }
        }
        BadgeCounter.syncIcon()
    }

    /// Move this device's cursor forward in each room, one call for all of
    /// them. Returns whether the island took it. A lost ack costs a re-served
    /// page, never a message: the rows are on disk, the UUID dedupe absorbs
    /// the repeat, and the next ack moves the cursor. Backwards acks are
    /// ignored by the island, so a stale one is harmless.
    private func ackGroupLog(_ acks: [Int: Int]) async -> Bool {
        guard !acks.isEmpty else { return true }
        struct AckRoom: Encodable { let gid: Int; let upto: Int }
        struct AckIn: Encodable { let rooms: [AckRoom] }
        struct AckOut: Decodable { let deleted: Int }
        let body = AckIn(rooms: acks.map { AckRoom(gid: $0.key, upto: $0.value) })
        do {
            let _: AckOut = try await APIClient.shared.request("POST", "/messages/group-log/ack", body: body)
            return true
        } catch {
            return false
        }
    }

    /// A live `gmsg` frame that the island logged at `seq` has been dealt
    /// with. When it is the very next row after where this device is known
    /// to stand, ack it so the next fetch does not serve it again; the acks
    /// coalesce for a moment so a burst of posts is one call. Anything else
    /// is left to the next drain, which settles it through `heads`: a `seq`
    /// at or below the mark is a row the drain already took, and a gap
    /// proves nothing either way. Rows sealed to OTHER members (their
    /// SKDMs, a reaction from a legacy client) take seqs on the same axis
    /// and are invisible to this member, so a jump of two can be one post
    /// this socket missed or one row that was never ours; no guess is made
    /// here, and no drain is run for it. Nothing is acked for a room with
    /// no mark yet either: the drain gets there first.
    func noteLiveGroupLogRow(gid: Int, seq: Int) {
        guard AppState.shared.serverCapabilities.groupLog else { return }
        guard let acked = groupLogAcked[gid], seq == acked + 1 else { return }
        groupLogAcked[gid] = seq
        pendingLiveAcks[gid] = max(pendingLiveAcks[gid] ?? 0, seq)
        liveAckFlush?.cancel()
        liveAckFlush = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self else { return }
            let acks = self.pendingLiveAcks
            self.pendingLiveAcks = [:]
            _ = await self.ackGroupLog(acks)
        }
    }
}

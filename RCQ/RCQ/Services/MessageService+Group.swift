import Foundation
import UIKit

/// Group-send pipeline extracted from `MessageService` to keep the
/// main file focused on 1:1 + low-level paths. Group fan-out is the
/// largest single send-pipeline (encrypt-per-recipient × N members
/// for every message kind), so isolating it removes the bulk of
/// `MessageService.swift`'s line count and recompile cost.
extension MessageService {
    // MARK: - sending (group)

    func send(text: String, to group: RCQGroup, replyTo: ReplyContext? = nil) async throws {
        SmokeTracker.shared.tick(.sendMessageGroup)
        if replyTo != nil { SmokeTracker.shared.tick(.replyToMessage) }
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

    /// Broadcast a previously-created group poll to all members. The
    /// caller has already hit `POST /groups/{id}/polls` and got back
    /// `pollID`; this just packages the question + options into an
    /// `Envelope.poll` and runs the standard group fan-out so every
    /// member's chat surfaces a fresh `PollBubble`.
    func sendPoll(
        envelopeID: UUID,
        pollID: Int,
        question: String,
        options: [String],
        singleChoice: Bool,
        anonymous: Bool,
        to group: RCQGroup
    ) async throws {
        // Local optimistic insert — mirror the JSON payload the
        // ingest path produces on the receiving side so the
        // sender's own bubble looks identical to peers'.
        let payload = PollPayload(
            question: question,
            options: options,
            singleChoice: singleChoice,
            anonymous: anonymous
        )
        let encoded = (try? JSONEncoder().encode(payload))
            .flatMap { String(data: $0, encoding: .utf8) } ?? question
        let local = Message(
            id: envelopeID,
            thread: .group(id: group.id),
            senderUIN: ownUIN,
            isFromMe: true,
            kind: .poll,
            text: encoded,
            pollID: pollID
        )
        MessageStore.shared.append(local)
        Task { [weak self] in
            try? await self?.sendGroupEnvelope(
                .poll(
                    id: envelopeID,
                    pollID: pollID,
                    question: question,
                    options: options,
                    singleChoice: singleChoice,
                    anonymous: anonymous
                ),
                to: group,
                localID: envelopeID
            )
        }
    }

    func sendPhoto(_ image: UIImage, to group: RCQGroup, caption: String? = nil, replyTo: ReplyContext? = nil, albumID: UUID? = nil) async throws {
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
            replyToAuthorName: replyTo?.authorName,
            albumID: albumID
        )
        MessageStore.shared.append(local)
        MediaProgressStore.shared.begin(local.id)
        Task { [weak self] in
            guard let self else { return }
            let upload: MediaService.UploadResult
            do {
                upload = try await MediaService.shared.uploadImage(image, peerHost: group.host) { p in
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
                .photo(id: local.id, mediaID: upload.mediaID, mediaKey: upload.keyBase64, caption: caption, ttl: ttl, replyTo: replyTo, albumID: albumID),
                to: group, localID: local.id
            )
        }
    }

    /// Group GIF send. Same envelope shape as `sendPhoto`; raw bytes
    /// flow through `uploadGIF`.
    func sendGIF(data: Data, preview: UIImage, to group: RCQGroup, caption: String? = nil, replyTo: ReplyContext? = nil, albumID: UUID? = nil) async throws {
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
            replyToAuthorName: replyTo?.authorName,
            albumID: albumID
        )
        MessageStore.shared.append(local)
        MediaProgressStore.shared.begin(local.id)
        Task { [weak self] in
            guard let self else { return }
            let upload: MediaService.UploadResult
            do {
                upload = try await MediaService.shared.uploadGIF(data: data, peerHost: group.host) { p in
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
                .photo(id: local.id, mediaID: upload.mediaID, mediaKey: upload.keyBase64, caption: caption, ttl: ttl, replyTo: replyTo, albumID: albumID),
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
                upload = try await MediaService.shared.uploadFile(at: fileURL, peerHost: group.host) { p in
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

    func sendFile(
        fileURL: URL,
        fileName: String,
        mime: String,
        sizeBytes: Int,
        to group: RCQGroup,
        caption: String? = nil,
        replyTo: ReplyContext? = nil,
    ) async throws {
        let ttl = ChatSettingsStore.shared.ttl(for: .group(id: group.id))
        let local = Message(
            thread: .group(id: group.id),
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
                upload = try await MediaService.shared.uploadFile(at: fileURL, peerHost: group.host) { p in
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
                .file(
                    id: local.id,
                    mediaID: upload.mediaID, mediaKey: upload.keyBase64,
                    fileName: fileName, mime: mime, sizeBytes: sizeBytes,
                    caption: caption,
                    ttl: ttl,
                    replyTo: replyTo
                ),
                to: group, localID: local.id
            )
        }
    }

    func sendLocation(
        latitude: Double,
        longitude: Double,
        to group: RCQGroup,
        caption: String? = nil,
        replyTo: ReplyContext? = nil,
    ) async throws {
        let ttl = ChatSettingsStore.shared.ttl(for: .group(id: group.id))
        let local = Message(
            thread: .group(id: group.id),
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
        try await sendGroupEnvelope(
            .location(
                id: local.id,
                lat: latitude, lng: longitude,
                caption: caption,
                ttl: ttl,
                replyTo: replyTo
            ),
            to: group, localID: local.id
        )
    }

    func sendVideo(
        from sourceURL: URL,
        previewThumbnailB64: String,
        to group: RCQGroup,
        caption: String? = nil,
        replyTo: ReplyContext? = nil,
        albumID: UUID? = nil,
    ) async throws {
        let ttl = ChatSettingsStore.shared.ttl(for: .group(id: group.id))
        let local = Message(
            thread: .group(id: group.id),
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
                MessageStore.shared.updateState(messageID: local.id, thread: .group(id: group.id), state: .failed)
                return
            }
            MessageStore.shared.updateVideoMeta(
                messageID: local.id, thread: .group(id: group.id),
                thumbnailB64: processed.thumbnailB64, durationSec: processed.durationSec,
            )
            let upload: MediaService.UploadResult
            do {
                upload = try await MediaService.shared.uploadFile(at: processed.url, peerHost: group.host) { p in
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
                    replyTo: replyTo,
                    albumID: albumID
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

}

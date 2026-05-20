import Foundation
import UIKit

/// Random-chat send pipeline extracted from `MessageService` to keep
/// the main file focused on the 1:1 + low-level path. Random chat
/// has its own message-store (`RandomChatService.messages`,
/// in-memory only — never persisted) and a distinct envelope wrapper
/// shipped through `/messages/random-sealed`, so the surface is
/// largely standalone and ports cleanly into its own extension.
extension MessageService {
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

    func sendPhoto(_ image: UIImage, toRandom peer: RandomPeer, caption: String? = nil, replyTo: ReplyContext? = nil, albumID: UUID? = nil) async throws {
        let local = Message(
            thread: .peer(uin: peer.uin),
            senderUIN: ownUIN,
            isFromMe: true,
            kind: .photo,
            text: caption ?? "",
            mediaID: nil,
            replyToID: replyTo?.id,
            replyToSnippet: replyTo?.snippet,
            replyToAuthorName: replyTo?.authorName,
            albumID: albumID
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
            .photo(id: local.id, mediaID: upload.mediaID, mediaKey: upload.keyBase64, caption: caption, replyTo: replyTo, albumID: albumID),
            to: peer,
            localID: local.id
        )
    }

    /// Random-chat GIF send. Same envelope shape as `sendPhoto`; the
    /// raw bytes flow through `uploadGIF`.
    func sendGIF(data: Data, preview: UIImage, toRandom peer: RandomPeer, caption: String? = nil, replyTo: ReplyContext? = nil, albumID: UUID? = nil) async throws {
        let local = Message(
            thread: .peer(uin: peer.uin),
            senderUIN: ownUIN,
            isFromMe: true,
            kind: .photo,
            text: caption ?? "",
            mediaID: nil,
            replyToID: replyTo?.id,
            replyToSnippet: replyTo?.snippet,
            replyToAuthorName: replyTo?.authorName,
            albumID: albumID
        )
        RandomChatService.shared.append(local)
        MediaProgressStore.shared.begin(local.id)
        let upload: MediaService.UploadResult
        do {
            upload = try await MediaService.shared.uploadGIF(data: data) { p in
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
            .photo(id: local.id, mediaID: upload.mediaID, mediaKey: upload.keyBase64, caption: caption, replyTo: replyTo, albumID: albumID),
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

    func sendVideo(processed: VideoProcessor.Output, toRandom peer: RandomPeer, caption: String? = nil, replyTo: ReplyContext? = nil, albumID: UUID? = nil) async throws {
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
            replyToAuthorName: replyTo?.authorName,
            albumID: albumID
        )
        RandomChatService.shared.append(local)
        defer { try? FileManager.default.removeItem(at: processed.url) }
        MediaProgressStore.shared.begin(local.id)
        let plaintextSize = (try? FileManager.default.attributesOfItem(atPath: processed.url.path)[.size] as? Int) ?? 0
        let payJetons = MediaService.jetonCost(forBytes: plaintextSize)
        let upload: MediaService.UploadResult
        do {
            upload = try await MediaService.shared.uploadFile(at: processed.url, payJetons: payJetons) { p in
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
                replyTo: replyTo,
                albumID: albumID
            ),
            to: peer,
            localID: local.id
        )
    }

    func sendRandomEnvelope(_ envelope: Envelope, to peer: RandomPeer, localID: UUID?) async throws {
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

}

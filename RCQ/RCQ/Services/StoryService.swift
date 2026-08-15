import AVFoundation
import Combine
import CryptoKit
import Foundation
import UIKit

/// Owns the story feed + posting flow.
@MainActor
final class StoryService: ObservableObject {
    static let shared = StoryService()

    @Published private(set) var feed: [StoryGroup] = []
    @Published private(set) var isPosting: Bool = false
    @Published private(set) var lastError: String?

    private var bag = Set<AnyCancellable>()

    private init() {
        WebSocketService.shared.events
            .sink { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.onWSEvent(event)
                }
            }
            .store(in: &bag)
    }

    // MARK: - Feed

    /// Drop the feed on entering a decoy session. Every group in it is a real
    /// contact's name and picture, and it is fetched by the REAL session, so
    /// nothing rebuilds it under duress — `refresh()` bails out below.
    func clearForDecoy() {
        feed = []
        lastError = nil
    }

    func refresh() async {
        if PanicPINService.shared.isDecoy { return }
        do {
            let resp: StoryFeedResponse = try await APIClient.shared.request(
                "GET", "/stories/feed"
            )
            self.feed = resp.groups
        } catch {
            print("[StoryService] feed refresh failed: \(error)")
        }
    }

    func group(forUIN uin: Int) -> StoryGroup? {
        feed.first(where: { $0.ownerUIN == uin })
    }

    // MARK: - Posting

    func postPhoto(_ image: UIImage, caption: String?, anonymous: Bool) async {
        isPosting = true
        defer { isPosting = false }
        do {
            let upload = try await MediaService.shared.uploadImage(image)
            try await commitStoryRow(
                mediaID: upload.mediaID,
                keyB64: upload.keyBase64,
                kind: .photo,
                caption: caption,
                anonymous: anonymous,
                durationSec: nil
            )
            await refresh()
        } catch {
            lastError = "story.error.post_failed".localized
            print("[StoryService] postPhoto failed: \(error)")
        }
    }

    func postVideo(_ url: URL, caption: String?, anonymous: Bool) async {
        isPosting = true
        defer { isPosting = false }
        do {
            let durationSec = await videoDuration(at: url)
            let upload = try await MediaService.shared.uploadFile(at: url)
            try await commitStoryRow(
                mediaID: upload.mediaID,
                keyB64: upload.keyBase64,
                kind: .video,
                caption: caption,
                anonymous: anonymous,
                durationSec: durationSec
            )
            await refresh()
        } catch {
            lastError = "story.error.post_failed".localized
            print("[StoryService] postVideo failed: \(error)")
        }
    }

    private struct PostBody: Encodable {
        let media_id: String
        let media_kind: String
        let media_key_b64: String
        let caption: String?
        let is_anonymous: Bool
        let duration_sec: Int?
    }

    private func commitStoryRow(
        mediaID: String,
        keyB64: String,
        kind: Story.MediaKind,
        caption: String?,
        anonymous: Bool,
        durationSec: Int?
    ) async throws {
        let body = PostBody(
            media_id: mediaID,
            media_kind: kind.rawValue,
            media_key_b64: keyB64,
            caption: caption?.isEmpty == true ? nil : caption,
            is_anonymous: anonymous,
            duration_sec: durationSec
        )
        let _: StoryPostResponse = try await APIClient.shared.request(
            "POST", "/stories", body: body
        )
    }

    private func videoDuration(at url: URL) async -> Int? {
        let asset = AVURLAsset(url: url)
        do {
            let dur = try await asset.load(.duration)
            return Int(CMTimeGetSeconds(dur).rounded())
        } catch {
            return nil
        }
    }

    // MARK: - Viewing

    func markViewed(_ storyID: String) {
        var changed = false
        feed = feed.map { group in
            var g = group
            g = StoryGroup(
                ownerUIN: group.ownerUIN,
                ownerNickname: group.ownerNickname,
                isAnonymous: group.isAnonymous,
                stories: group.stories.map { s in
                    if s.id == storyID, !s.viewed {
                        changed = true
                        return Story(
                            id: s.id,
                            ownerUIN: s.ownerUIN,
                            ownerNickname: s.ownerNickname,
                            mediaID: s.mediaID,
                            mediaKind: s.mediaKind,
                            mediaKeyB64: s.mediaKeyB64,
                            caption: s.caption,
                            isAnonymous: s.isAnonymous,
                            durationSec: s.durationSec,
                            postedAt: s.postedAt,
                            expiresAt: s.expiresAt,
                            viewCount: s.viewCount + 1,
                            viewed: true
                        )
                    }
                    return s
                }
            )
            return g
        }
        guard changed else { return }
        Task {
            let _: EmptyResponse? = try? await APIClient.shared.request(
                "POST", "/stories/\(storyID)/view"
            )
        }
    }

    // MARK: - Deletion

    func delete(_ storyID: String) async {
        do {
            let _: EmptyResponse = try await APIClient.shared.request(
                "DELETE", "/stories/\(storyID)"
            )
            await refresh()
        } catch {
            lastError = "story.error.delete_failed".localized
            print("[StoryService] delete failed: \(error)")
        }
    }

    func loadViewers(for storyID: String) async -> [StoryViewer] {
        do {
            let resp: StoryViewersResponse = try await APIClient.shared.request(
                "GET", "/stories/\(storyID)/viewers"
            )
            return resp.viewers
        } catch {
            return []
        }
    }

    // MARK: - WS

    private func onWSEvent(_ event: WebSocketService.Event) {
        switch event {
        case .storyPosted, .storyDeleted, .opened:
            Task { await self.refresh() }
        default:
            break
        }
    }
}

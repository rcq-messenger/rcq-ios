import Combine
import Foundation
import SwiftUI

/// Per-thread message lists, persisted in CoreData via `MessageDB`.
@MainActor
final class MessageStore: ObservableObject {
    static let shared = MessageStore()

    @Published private(set) var threads: [ThreadID: [Message]] = [:]
    /// Rows fading out before removal. `withAnimation` doesn't propagate through the @Published → Combine → @Published chain.
    @Published private(set) var fadingOutIDs: Set<UUID> = []

    private static let softDeleteDuration: TimeInterval = 0.32

    private var sweepTimer: Timer?

    private init() {
        rehydrate()
        sweepExpired()
        startSweepTimer()
    }

    private func rehydrate() {
        let all = MessageDB.shared.fetchAll()
        threads = Dictionary(grouping: all, by: { $0.thread })
    }

    private func startSweepTimer() {
        sweepTimer?.invalidate()
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sweepExpired() }
        }
    }

    /// Drop messages whose `sentAt + ttlSeconds` has passed.
    func sweepExpired() {
        let now = Date()
        for (thread, msgs) in threads {
            let kept = msgs.filter { msg in
                guard let ttl = msg.ttlSeconds, ttl > 0 else { return true }
                return msg.sentAt.addingTimeInterval(TimeInterval(ttl)) >= now
            }
            if kept.count != msgs.count {
                let toDelete = msgs.filter { keep in !kept.contains(where: { $0.id == keep.id }) }
                withAnimation(.easeInOut(duration: 0.25)) {
                    threads[thread] = kept
                }
                for msg in toDelete {
                    MessageDB.shared.deleteRow(id: msg.id)
                }
            }
        }
    }

    func messages(for thread: ThreadID) -> [Message] {
        threads[thread] ?? []
    }

    /// Idempotent insert. Returns `true` for a new row, `false` if id already present.
    @discardableResult
    func append(_ message: Message) -> Bool {
        var t = threads[message.thread, default: []]
        if t.contains(where: { $0.id == message.id }) { return false }
        t.append(message)
        threads[message.thread] = t
        MessageDB.shared.insert(message)
        return true
    }

    func updateState(messageID: UUID, thread: ThreadID, state: DeliveryState) {
        guard var t = threads[thread],
              let idx = t.firstIndex(where: { $0.id == messageID }) else { return }
        t[idx].deliveryState = state
        threads[thread] = t
        MessageDB.shared.updateState(id: messageID, state: state)
    }

    /// No-op if missing, not a text bubble, or tombstoned.
    func applyEdit(messageID: UUID, thread: ThreadID, newText: String, editedAt: Date) {
        guard var t = threads[thread],
              let idx = t.firstIndex(where: { $0.id == messageID })
        else { return }
        let m = t[idx]
        guard m.kind == .text, !m.deletedForEveryone else { return }
        t[idx] = Message(
            id: m.id, thread: m.thread, senderUIN: m.senderUIN,
            isFromMe: m.isFromMe, kind: m.kind, text: newText,
            mediaID: m.mediaID, sentAt: m.sentAt,
            deliveryState: m.deliveryState, receivedWhileAway: m.receivedWhileAway,
            deletedForEveryone: m.deletedForEveryone,
            reactions: m.reactions,
            thumbnailB64: m.thumbnailB64,
            durationSec: m.durationSec,
            ttlSeconds: m.ttlSeconds,
            forwardedFromName: m.forwardedFromName,
            replyToID: m.replyToID,
            replyToSnippet: m.replyToSnippet,
            replyToAuthorName: m.replyToAuthorName,
            editedAt: editedAt,
            premiumPriceTokens: m.premiumPriceTokens,
            premiumUnlocked: m.premiumUnlocked,
            albumID: m.albumID
        )
        threads[thread] = t
        MessageDB.shared.updateText(id: messageID, text: newText, editedAt: editedAt)
    }

    /// Patch in the recovered media key and flip `premiumUnlocked`.
    func unlockPremium(messageID: UUID, thread: ThreadID, mediaKeyB64: String) {
        guard var t = threads[thread],
              let idx = t.firstIndex(where: { $0.id == messageID }) else { return }
        let m = t[idx]
        guard m.kind == .premiumPhoto || m.kind == .premiumVideo else { return }
        if m.premiumUnlocked { return }
        // mediaID format on receive: "<server_media_id>|" — splice key into the second segment.
        let baseMediaID = (m.mediaID ?? "").components(separatedBy: "|").first ?? ""
        let newMediaID = baseMediaID + "|" + mediaKeyB64
        t[idx].mediaID = newMediaID
        t[idx].premiumUnlocked = true
        threads[thread] = t
        MessageDB.shared.updatePremiumUnlocked(id: messageID, mediaID: newMediaID)
    }

    /// Patch in the canonical thumbnail + durationSec once VideoProcessor
    /// finishes. Used by the optimistic-send path: bubble appears
    /// instantly with the picker's quick first-frame thumb, then the
    /// processed thumbnail (and the real durationSec) lands a few
    /// seconds later when compression is done.
    func updateVideoMeta(messageID: UUID, thread: ThreadID, thumbnailB64: String, durationSec: Double) {
        guard var t = threads[thread],
              let idx = t.firstIndex(where: { $0.id == messageID }) else { return }
        t[idx].thumbnailB64 = thumbnailB64
        t[idx].durationSec = durationSec
        threads[thread] = t
        MessageDB.shared.updateVideoMeta(id: messageID, thumbnailB64: thumbnailB64, durationSec: durationSec)
    }

    /// Patch in the server media id once the upload finishes.
    func updateMediaID(messageID: UUID, thread: ThreadID, mediaID: String) {
        guard var t = threads[thread],
              let idx = t.firstIndex(where: { $0.id == messageID }) else { return }
        // In-place mutation preserves every field automatically — the
        // pre-`var mediaID` rebuild path silently dropped fileName /
        // fileMime / lat / lng on file + location bubbles.
        t[idx].mediaID = mediaID
        threads[thread] = t
        MessageDB.shared.updateMediaID(id: messageID, mediaID: mediaID)
    }

    /// Delete locally with two-phase fade. See `fadingOutIDs`.
    func deleteLocal(messageID: UUID, thread: ThreadID) {
        let exists = threads[thread]?.contains(where: { $0.id == messageID }) ?? false
        guard exists else {
            MessageDB.shared.deleteRow(id: messageID)
            return
        }
        fadingOutIDs.insert(messageID)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.softDeleteDuration) { [weak self] in
            guard let self else { return }
            self.fadingOutIDs.remove(messageID)
            guard var t = self.threads[thread] else { return }
            t.removeAll(where: { $0.id == messageID })
            self.threads[thread] = t
            MessageDB.shared.deleteRow(id: messageID)
        }
    }

    func markRead(messageIDs: [UUID], thread: ThreadID) {
        guard var t = threads[thread] else { return }
        let idSet = Set(messageIDs)
        var changed = false
        for i in t.indices where idSet.contains(t[i].id) && t[i].deliveryState != .read {
            t[i].deliveryState = .read
            MessageDB.shared.updateState(id: t[i].id, state: .read)
            changed = true
        }
        if changed { threads[thread] = t }
    }

    /// Idempotent. Toggle decisions live in `MessageService.toggleReaction`.
    func applyReaction(targetID: UUID, thread: ThreadID, uin: Int, asset: String?) {
        guard var t = threads[thread] else { return }
        guard let idx = t.firstIndex(where: { $0.id == targetID }) else { return }
        var reactions = t[idx].reactions
        if let asset {
            reactions[uin] = asset
        } else {
            reactions.removeValue(forKey: uin)
        }
        t[idx].reactions = reactions
        withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
            threads[thread] = t
        }
        MessageDB.shared.updateReactions(id: targetID, reactions: reactions)
    }

    /// Apply a deleteForEveryone tombstone. Row stays as a placeholder.
    func tombstone(messageID: UUID, thread: ThreadID) {
        guard var t = threads[thread] else { return }
        guard let idx = t.firstIndex(where: { $0.id == messageID }) else { return }
        let m = t[idx]
        let tomb = Message(
            id: m.id, thread: m.thread, senderUIN: m.senderUIN,
            isFromMe: m.isFromMe, kind: m.kind, text: "",
            mediaID: nil, sentAt: m.sentAt,
            deliveryState: m.deliveryState, receivedWhileAway: m.receivedWhileAway,
            deletedForEveryone: true,
            ttlSeconds: m.ttlSeconds
        )
        withAnimation(.easeInOut(duration: 0.3)) {
            t[idx] = tomb
            threads[thread] = t
        }
        MessageDB.shared.markDeletedForEveryone(id: messageID)
    }

    func clearThread(_ thread: ThreadID) {
        threads[thread] = nil
        MessageDB.shared.deleteThread(thread)
    }

    func clearAll() {
        threads = [:]
        MessageDB.shared.deleteAll()
    }
}

import Combine
import Foundation
import SwiftUI

/// Per-thread message lists, persisted in CoreData via [MessageDB]. Threads are keyed
/// by `ThreadID` so 1:1 chats and group chats live side by side without colliding.
@MainActor
final class MessageStore: ObservableObject {
    static let shared = MessageStore()

    @Published private(set) var threads: [ThreadID: [Message]] = [:]
    /// Rows currently animating out before they're actually pulled
    /// from `threads`. SwiftUI views opt-in by collapsing height +
    /// fading opacity when an id appears here. The `withAnimation`
    /// transaction inside `deleteLocal` doesn't reliably propagate
    /// to ChatViewModel-derived bindings (the @Published → Combine
    /// → @Published assign chain swallows the transaction by the
    /// time SwiftUI re-renders), so we drive removal animations
    /// from a separate published flag instead. A bound view's
    /// `.animation(.easeInOut, value: isFadingOut)` fires reliably
    /// without depending on transaction inheritance.
    @Published private(set) var fadingOutIDs: Set<UUID> = []

    /// How long a row stays in `fadingOutIDs` before its message is
    /// actually pulled from `threads`. Matches the row's fade
    /// duration so the visual transition completes before the data
    /// disappears underneath it.
    private static let softDeleteDuration: TimeInterval = 0.32

    private var sweepTimer: Timer?

    private init() {
        rehydrate()
        // Drain any expired rows that the previous launch couldn't reach
        // (app suspended past their TTL), then sweep periodically while
        // we're alive.
        sweepExpired()
        startSweepTimer()
    }

    /// Load every persisted message into the in-memory cache. Called once at init.
    private func rehydrate() {
        let all = MessageDB.shared.fetchAll()
        threads = Dictionary(grouping: all, by: { $0.thread })
    }

    /// Disappearing-message sweeper. Runs every 30s while the app is alive.
    /// Resolution is fine for typical TTLs (1 minute and up); finer than that
    /// would burn battery for no real win.
    private func startSweepTimer() {
        sweepTimer?.invalidate()
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sweepExpired() }
        }
    }

    /// Drop messages whose `sentAt + ttlSeconds` has passed. Touches every
    /// thread's array so the SwiftUI bindings re-render exactly once per
    /// affected thread, not per row.
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

    /// Append a freshly-arrived message. Returns `true` if this is a
    /// new row, `false` if a row with the same UUID already lives in
    /// the thread (idempotent insert). Callers use the return value
    /// to scope side-effects — unread counters, sounds, push fan-out
    /// — to actual new content. Without this distinction the offline-
    /// queue redrain and the WS server-side queue flush race would
    /// each bump unread for the same message, inflating badges past
    /// the real unread count.
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

    /// Apply an edit envelope to a message in this thread. Replaces
    /// the body text + stamps `editedAt`. No-op if the message
    /// isn't in our store, isn't a text bubble (edits don't touch
    /// media captions in v1), or has been tombstoned. Used by both
    /// the local sender (echo of the outgoing edit) and the
    /// receiver's ingest.
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
            premiumUnlocked: m.premiumUnlocked
        )
        threads[thread] = t
        MessageDB.shared.updateText(id: messageID, text: newText, editedAt: editedAt)
    }

    /// Premium-content unlock — patches in the just-recovered media key
    /// and flips `premiumUnlocked` so subsequent renders skip the
    /// locked overlay and decrypt the media blob normally. Persists
    /// to MessageDB so a restart doesn't ask the user to pay again.
    /// No-op if the row isn't actually a premium message or has
    /// already been unlocked (idempotent).
    func unlockPremium(messageID: UUID, thread: ThreadID, mediaKeyB64: String) {
        guard var t = threads[thread],
              let idx = t.firstIndex(where: { $0.id == messageID }) else { return }
        let m = t[idx]
        guard m.kind == .premiumPhoto || m.kind == .premiumVideo else { return }
        if m.premiumUnlocked { return }
        // mediaID was stored as "<server_media_id>|" with empty key
        // on receive — splice the freshly-unwrapped key in so the
        // existing media renderer's `mediaID + "|" + key` parser
        // works without a separate locked-vs-unlocked branch.
        let baseMediaID = (m.mediaID ?? "").components(separatedBy: "|").first ?? ""
        let newMediaID = baseMediaID + "|" + mediaKeyB64
        let updated = Message(
            id: m.id, thread: m.thread, senderUIN: m.senderUIN,
            isFromMe: m.isFromMe, kind: m.kind, text: m.text,
            mediaID: newMediaID, sentAt: m.sentAt,
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
            editedAt: m.editedAt,
            premiumPriceTokens: m.premiumPriceTokens,
            premiumUnlocked: true
        )
        t[idx] = updated
        threads[thread] = t
        MessageDB.shared.updatePremiumUnlocked(id: messageID, mediaID: newMediaID)
    }

    /// Patch in the server media id once the upload finishes. Lets the local bubble
    /// flip from placeholder to the actual photo without going through the server.
    func updateMediaID(messageID: UUID, thread: ThreadID, mediaID: String) {
        guard var t = threads[thread],
              let idx = t.firstIndex(where: { $0.id == messageID }) else { return }
        let m = t[idx]
        // CRITICAL: pass through ALL fields (especially premium*) —
        // the early version of this helper reconstructed Message with
        // only the basics, which silently zeroed `premiumPriceTokens`
        // and `premiumUnlocked` on the sender's bubble after upload
        // completed. The bubble then flipped from "unlocked photo I
        // just sent" to "locked premium bubble priced 0", because
        // `premiumUnlocked` defaulted back to false and the price
        // showed `?? 0`. Always carry forward the full record.
        t[idx] = Message(
            id: m.id, thread: m.thread, senderUIN: m.senderUIN,
            isFromMe: m.isFromMe, kind: m.kind, text: m.text,
            mediaID: mediaID, sentAt: m.sentAt,
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
            editedAt: m.editedAt,
            premiumPriceTokens: m.premiumPriceTokens,
            premiumUnlocked: m.premiumUnlocked
        )
        threads[thread] = t
        MessageDB.shared.updateMediaID(id: messageID, mediaID: mediaID)
    }

    /// Delete locally only. Used by "Delete for me" and by the
    /// receive side of "Delete for everyone". Two-phase so the row
    /// gets a visible fade-out instead of just popping out of the
    /// LazyVStack — see `fadingOutIDs` for why we don't rely on a
    /// `withAnimation`-wrapped synchronous removal.
    func deleteLocal(messageID: UUID, thread: ThreadID) {
        let exists = threads[thread]?.contains(where: { $0.id == messageID }) ?? false
        guard exists else {
            // No live row to fade — most likely already removed by a
            // race (concurrent delete + queue redrain). Just clean DB.
            MessageDB.shared.deleteRow(id: messageID)
            return
        }
        // Phase 1: flag the row. Bound MessageRow re-renders with
        // collapsed height + zero opacity, animated by its own
        // `.animation(value: isFadingOut)` modifier.
        fadingOutIDs.insert(messageID)
        // Phase 2: pull the row from `threads` after the fade's
        // visual duration. By then the row is invisible / zero-height,
        // so the actual array removal triggers no perceivable shift.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.softDeleteDuration) { [weak self] in
            guard let self else { return }
            self.fadingOutIDs.remove(messageID)
            guard var t = self.threads[thread] else { return }
            t.removeAll(where: { $0.id == messageID })
            self.threads[thread] = t
            MessageDB.shared.deleteRow(id: messageID)
        }
    }

    /// Bump received messages from the given peer to `.read`. Called after the
    /// sender of those messages acks they've been seen.
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

    /// Set or clear a reaction for `uin` on the message. **Idempotent** — passing
    /// the same asset twice keeps it in place (rather than toggling off), which
    /// matters for group fan-out: the sender receives an echo of their own
    /// reaction and shouldn't have it silently inverted. Toggle decisions live
    /// upstream in `MessageService.toggleReaction`.
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

    /// Apply a deleteForEveryone tombstone — stays in the thread but renders as a
    /// placeholder. We keep the row so the conversation flow remains coherent. The
    /// flip animates so the user sees it happen.
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

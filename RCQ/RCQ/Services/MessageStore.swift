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
    /// Per-thread flag: `true` while at least one older row exists in
    /// CoreData that hasn't been pulled into the in-memory window yet.
    /// Drives the ChatView "load earlier" affordance + scroll-up hook.
    @Published private(set) var hasOlderInDB: [ThreadID: Bool] = [:]

    /// How many rows we keep in memory per thread by default. App
    /// launch fetches this many for every known thread; ChatView's
    /// scroll-up gesture extends the window by `loadOlderPageSize`.
    static let initialWindowSize: Int = 100
    static let loadOlderPageSize: Int = 50

    private static let softDeleteDuration: TimeInterval = 0.32

    private var sweepTimer: Timer?

    private init() {
        if PanicPINService.shared.lockState == .unlocked {
            rehydrate()
        }
        sweepExpired()
        startSweepTimer()
    }

    private func rehydrate() {
        // Old path used `fetchAll()` and grouped, which forced every
        // message ever stored into memory at app launch. That is fine
        // for users with a few short chats and ruinous for active
        // groups where 200 members trade thousands of messages a day.
        // Now we discover the set of threads first and pull only the
        // most recent `initialWindowSize` for each.
        var loaded: [ThreadID: [Message]] = [:]
        var hasMore: [ThreadID: Bool] = [:]
        for t in MessageDB.shared.fetchThreadIDs() {
            let tail = MessageDB.shared.fetchRecent(thread: t, limit: Self.initialWindowSize)
            loaded[t] = tail
            if let oldest = tail.first {
                hasMore[t] = MessageDB.shared.hasOlder(thread: t, before: oldest.sentAt)
            } else {
                hasMore[t] = false
            }
        }
        threads = loaded
        hasOlderInDB = hasMore
    }

    /// Pull the next page of older messages for `thread` from CoreData
    /// and prepend them to the in-memory window. Returns how many were
    /// loaded; 0 means we hit the start of history.
    @discardableResult
    func loadOlder(for thread: ThreadID) -> Int {
        guard let current = threads[thread], let oldest = current.first else { return 0 }
        let older = MessageDB.shared.fetchOlder(
            thread: thread,
            before: oldest.sentAt,
            limit: Self.loadOlderPageSize,
        )
        if older.isEmpty {
            hasOlderInDB[thread] = false
            return 0
        }
        var merged = older
        merged.append(contentsOf: current)
        threads[thread] = merged
        let newOldest = merged.first?.sentAt ?? oldest.sentAt
        hasOlderInDB[thread] = MessageDB.shared.hasOlder(thread: thread, before: newOldest)
        return older.count
    }

    func reloadFromDB() {
        rehydrate()
        sweepExpired()
    }

    func clearInMemory() {
        threads = [:]
        fadingOutIDs = []
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
                let keptIDs = Set(kept.map(\.id))
                let toDelete = msgs.filter { !keptIDs.contains($0.id) }
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
    /// Returns true only for content this device has never held.
    ///
    /// ⚠ Newness is decided by the STORE, not by the window in memory. This
    /// used to ask `threads`, which keeps the last hundred rows per thread, so
    /// a re-delivered envelope older than that window was treated as brand new:
    /// it bumped the unread count and was appended at the END of the thread,
    /// far from its own timestamp. "Старое сообщение всплыло внизу
    /// непрочитанным" needs no deletion at all — every envelope is offered to
    /// this client at least twice by design.
    func append(_ message: Message) -> Bool {
        var t = threads[message.thread, default: []]
        if t.contains(where: { $0.id == message.id }) { return false }
        guard MessageDB.shared.insertIfAbsent(message) else { return false }
        t.append(message)
        threads[message.thread] = t
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
        let editableKinds: [MessageKind] = [.text, .photo, .video, .file]
        guard editableKinds.contains(m.kind), !m.deletedForEveryone else { return }
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
            albumID: m.albumID
        )
        threads[thread] = t
        MessageDB.shared.updateText(id: messageID, text: newText, editedAt: editedAt)
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
    ///
    /// The row leaves the chat and leaves the export, but its id stays in the
    /// database as a hidden tombstone. Nothing is shown in its place. That id is
    /// the only thing standing between a deleted message and its own re-delivery:
    /// every envelope is offered to this client at least twice by design (a
    /// carbon of your own send, plus the at-least-once queue drain), and
    /// `MessageDB.insert` recognises a copy only by an id it still has. Removing
    /// the row was report #415 — the message came back after a restart, unread,
    /// and in its pre-edit wording, because edits are never carboned.
    func deleteLocal(messageID: UUID, thread: ThreadID) {
        let exists = threads[thread]?.contains(where: { $0.id == messageID }) ?? false
        guard exists else {
            MessageDB.shared.markDeletedLocally(id: messageID)
            return
        }
        fadingOutIDs.insert(messageID)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.softDeleteDuration) { [weak self] in
            guard let self else { return }
            self.fadingOutIDs.remove(messageID)
            guard var t = self.threads[thread] else { return }
            t.removeAll(where: { $0.id == messageID })
            self.threads[thread] = t
            MessageDB.shared.markDeletedLocally(id: messageID)
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

    /// Apply a reaction located by its target message id across ALL threads
    /// (1:1 + group). Used for self-echoes: a reaction you made on another
    /// device, sealed to your own identity, arrives with only the target id and
    /// no reliable thread (the sender is yourself, so the thread would resolve
    /// to your own peer thread, not where the message lives). The id is a
    /// globally-unique UUID, so it matches exactly one message. Returns the
    /// thread it landed in (for the reaction-inbox ping), or nil if not found.
    @discardableResult
    func applyReactionAnywhere(targetID: UUID, uin: Int, asset: String?) -> ThreadID? {
        for (thread, msgs) in threads where msgs.contains(where: { $0.id == targetID }) {
            applyReaction(targetID: targetID, thread: thread, uin: uin, asset: asset)
            return thread
        }
        return nil
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

    /// Soft account-switch reset: drop the in-memory thread cache WITHOUT
    /// deleting any rows. History lives in a per-account SQLite file
    /// (`rcq-history-<accountID>-v8.sqlite`) that must survive so switching back
    /// resumes the conversation. Use [clearAll] only for a true burn/migrate.
    func resetInMemory() {
        threads = [:]
    }
}

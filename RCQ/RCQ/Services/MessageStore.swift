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

    /// How many rows we keep in memory per thread by default. Read when a
    /// thread is first asked for (see `ensureLoaded`), not at launch; ChatView's
    /// scroll-up gesture extends the window by `loadOlderPageSize`.
    static let initialWindowSize: Int = 100
    static let loadOlderPageSize: Int = 50

    private static let softDeleteDuration: TimeInterval = 0.32

    private var sweepTimer: Timer?

    /// Threads whose window has been read from CoreData this session.
    ///
    /// Not the same question as `threads[t] != nil`: a live message landing in
    /// a chat nobody has opened creates a one-row window, and opening that chat
    /// must still go and fetch the hundred rows behind it.
    private var loadedThreads: Set<ThreadID> = []

    /// Timer ticks since the last DB-wide expiry sweep. Seeded AT the interval
    /// so the FIRST tick runs one: launch itself must not pay for it.
    ///
    /// ⚠ Seeded at the interval, not at `Int.max`. `Int.max` reads like "high
    /// enough to fire immediately" and does the exact opposite: the tick below
    /// increments it, `Int.max` wraps to `Int.min`, and the comparison is false
    /// for the rest of the process. The DB sweep then never ran at all, and a
    /// disappearing message in a chat the user never opened outlived its
    /// deadline on disk until the day that chat was opened.
    private var ticksSinceDBSweep = MessageStore.dbSweepEveryTicks
    /// One DB sweep per this many 30 s ticks.
    private static let dbSweepEveryTicks = 10

    private init() {
        // Nothing is read here any more. Launch used to walk every thread in
        // the database and pull a hundred rows for each, on the main actor,
        // before the chat list could paint, for windows the user would open at
        // most one of. Windows are read when something asks for one; see
        // `ensureLoaded`.
        startSweepTimer()
    }

    /// Read this thread's window from CoreData, once per session.
    ///
    /// Every reader and every mutator of a thread goes through here first, so
    /// "the window is in memory" holds exactly where it used to hold after the
    /// launch-time rehydrate. Anything that skipped it would silently no-op on
    /// a chat that has not been opened yet.
    func ensureLoaded(_ thread: ThreadID) {
        // Behind the panic PIN there is no data key, so every sealed field
        // would read back as an empty string and the window would cache that.
        // The launch-time rehydrate this replaces had the same guard.
        guard PanicPINService.shared.lockState == .unlocked else { return }
        guard !loadedThreads.contains(thread) else { return }
        loadWindow(thread)
    }

    /// Whether this thread's window has been read from CoreData yet, for a
    /// view that has to tell "this chat is empty" apart from "this chat has
    /// not been read off disk yet". Safe to ask from a `body`: `loadWindow`
    /// always assigns `threads[thread]`, so the answer changing republishes.
    func isLoaded(_ thread: ThreadID) -> Bool {
        loadedThreads.contains(thread)
    }

    /// Every thread in the database, windowed. Only for readers that genuinely
    /// search across all chats (the search overlay); nothing on the launch path
    /// may call this.
    func ensureAllLoaded() {
        guard PanicPINService.shared.lockState == .unlocked else { return }
        for t in MessageDB.shared.fetchThreadIDs() where !loadedThreads.contains(t) {
            loadWindow(t)
        }
    }

    private func loadWindow(_ thread: ThreadID) {
        let tail = MessageDB.shared.fetchRecent(thread: thread, limit: Self.initialWindowSize)
        // Expired rows are dropped on the way in rather than waiting for the
        // next sweep tick, so a disappearing message can never be on screen
        // for the half-minute after its deadline.
        let now = Date()
        var window = tail.filter { msg in
            guard let deadline = msg.expiresAt else { return true }
            return deadline >= now
        }
        if window.count != tail.count {
            let kept = Set(window.map(\.id))
            for msg in tail where !kept.contains(msg.id) {
                MessageDB.shared.deleteRow(id: msg.id)
            }
        }
        // A live row that landed before anyone opened this chat is already in
        // the dictionary; it is normally inside `tail` too (append writes
        // through), so this only catches one that fell outside the window.
        //
        // ⚠ Merged BY TIME, not by arrival. `append` does not load the window
        // first, so a drain can fill a chat nobody has opened with more than
        // `initialWindowSize` rows; `tail` is then the newest hundred and the
        // leftovers here are the OLDEST rows, not the newest. Tacked on the end
        // they left the window out of order, and everything downstream reads it
        // as ordered: `window.first` stopped being the oldest row, so `loadOlder`
        // asked the database for rows the window already held and prepended
        // them a second time (duplicate ids in a `ForEach`), and the long-press
        // preview drew its `suffix(50)` — the oldest fifty — as the recent ones.
        if let live = threads[thread], !live.isEmpty {
            let known = Set(window.map(\.id))
            let missing = live.filter { !known.contains($0.id) }
            if !missing.isEmpty {
                window.append(contentsOf: missing)
                window.sort { $0.sentAt < $1.sentAt }
            }
        }
        threads[thread] = window
        hasOlderInDB[thread] = window.first.map {
            MessageDB.shared.hasOlder(thread: thread, before: $0.sentAt)
        } ?? false
        loadedThreads.insert(thread)
    }

    /// Pull the next page of older messages for `thread` from CoreData
    /// and prepend them to the in-memory window. Returns how many were
    /// loaded; 0 means we hit the start of history.
    @discardableResult
    func loadOlder(for thread: ThreadID) -> Int {
        ensureLoaded(thread)
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
        // Rows the window already holds are dropped rather than prepended a
        // second time: a duplicated id here is a duplicated `RenderUnit.id` in
        // the chat's `ForEach`, which is undefined behaviour in SwiftUI rather
        // than a cosmetic repeat. `fetchOlder` is exclusive on `sentAt`, so
        // with an ordered window this filter takes nothing.
        let held = Set(current.map(\.id))
        var merged = older.filter { !held.contains($0.id) }
        guard !merged.isEmpty else {
            hasOlderInDB[thread] = MessageDB.shared.hasOlder(thread: thread, before: oldest.sentAt)
            return 0
        }
        let added = merged.count
        merged.append(contentsOf: current)
        threads[thread] = merged
        let newOldest = merged.first?.sentAt ?? oldest.sentAt
        hasOlderInDB[thread] = MessageDB.shared.hasOlder(thread: thread, before: newOldest)
        return added
    }

    /// Drop what is held and read it back. Used after a restore from backup
    /// and after a panic-PIN unlock, both of which change what is on disk
    /// under the windows in memory.
    ///
    /// Only the windows that are open come back. It used to be every thread in
    /// the database, which is what made the panic-PIN unlock TAP stall: the
    /// whole rehydrate ran before `lockState` flipped.
    ///
    /// ⚠ Every caller of this either changed which SQLite file is underneath
    /// (account switch, decoy) or restored into the current one, and every one
    /// of the store-swapping callers drops the windows FIRST
    /// (`resetInMemory` / `clearInMemory`). Reloading a thread id read from
    /// one account's store against another's is how a switch would end up
    /// holding empty windows keyed by the previous account's peers.
    func reloadFromDB() {
        let wanted = loadedThreads
        loadedThreads.removeAll()
        threads = [:]
        hasOlderInDB = [:]
        for t in wanted { loadWindow(t) }
        sweepExpired()
        // NOT inline: this used to run inside the PIN-unlock handler, before
        // `lockState` flipped, and it walks the store (see `deleteExpired`).
        // The unlock frame owes the user a painted chat list first; a timer
        // that fires 1.5s late is still hours ahead of the 5-minute sweep
        // tick, and the in-memory `sweepExpired` above already hides any
        // loaded row past its deadline.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self?.sweepExpiredInDB()
        }
    }

    /// Panic-PIN lock. The whole interface behind the lock is torn down with
    /// it (`RCQApp` swaps `ContactListView` for `PINLockView`), so nothing is
    /// waiting for these windows: the chat is built again, and asks again,
    /// after the unlock.
    func clearInMemory() {
        loadedThreads.removeAll()
        threads = [:]
        hasOlderInDB = [:]
        fadingOutIDs = []
    }

    private func startSweepTimer() {
        sweepTimer?.invalidate()
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.sweepExpired()
                // Plain `+=`: the counter is reset by every sweep and so never
                // climbs past the interval, and a wrapping add here is what
                // silently disabled the sweep (see the declaration).
                self.ticksSinceDBSweep += 1
                if self.ticksSinceDBSweep >= Self.dbSweepEveryTicks {
                    self.sweepExpiredInDB()
                }
            }
        }
    }

    /// The other half of `sweepExpired`, for the threads that are not in
    /// memory. Windows are loaded on demand now, so the in-memory pass only
    /// ever sees chats the user has opened; without this, a disappearing
    /// message in an unopened chat would outlive its deadline on disk and be
    /// there waiting the day that chat is opened.
    private func sweepExpiredInDB() {
        ticksSinceDBSweep = 0
        let removed = MessageDB.shared.deleteExpired()
        guard !removed.isEmpty else { return }
        // A window may hold a row the DB pass just deleted (the two agree on
        // the deadline, but the timer between them is not zero).
        for (thread, ids) in removed {
            guard var msgs = threads[thread] else { continue }
            let drop = Set(ids)
            let kept = msgs.filter { !drop.contains($0.id) }
            guard kept.count != msgs.count else { continue }
            msgs = kept
            withAnimation(.easeInOut(duration: 0.25)) {
                threads[thread] = msgs
            }
        }
    }

    /// Drop messages whose deadline has passed.
    ///
    /// The deadline counts from `Message.ttlAnchor`: the sender's own compose
    /// time when the envelope carried one, and `sentAt` when it did not. Rows
    /// written before the wire carried a sender timestamp have no anchor and
    /// keep the deadline they have always had.
    func sweepExpired() {
        let now = Date()
        for (thread, msgs) in threads {
            let kept = msgs.filter { msg in
                guard let deadline = msg.expiresAt else { return true }
                return deadline >= now
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
        ensureLoaded(thread)
        guard var t = threads[thread],
              let idx = t.firstIndex(where: { $0.id == messageID }) else { return }
        t[idx].deliveryState = state
        threads[thread] = t
        MessageDB.shared.updateState(id: messageID, state: state)
    }

    /// No-op if missing, not a text bubble, or tombstoned.
    func applyEdit(messageID: UUID, thread: ThreadID, newText: String, editedAt: Date) {
        ensureLoaded(thread)
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
            senderSentAt: m.senderSentAt,
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
        ensureLoaded(thread)
        guard var t = threads[thread],
              let idx = t.firstIndex(where: { $0.id == messageID }) else { return }
        t[idx].thumbnailB64 = thumbnailB64
        t[idx].durationSec = durationSec
        threads[thread] = t
        MessageDB.shared.updateVideoMeta(id: messageID, thumbnailB64: thumbnailB64, durationSec: durationSec)
    }

    /// Patch in the server media id once the upload finishes.
    func updateMediaID(messageID: UUID, thread: ThreadID, mediaID: String) {
        ensureLoaded(thread)
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
        ensureLoaded(thread)
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
        ensureLoaded(thread)
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

    /// Sender side of the delivery receipt: `.sent` → `.delivered`.
    ///
    /// ⚠ Never downgrades. A read receipt can arrive first — they had the chat
    /// open when the message landed — and a delivery receipt for the same id
    /// must not walk the bubble back a state.
    func markDelivered(messageIDs: [UUID], thread: ThreadID) {
        ensureLoaded(thread)
        guard var t = threads[thread] else { return }
        let idSet = Set(messageIDs)
        var changed = false
        for i in t.indices where idSet.contains(t[i].id) && t[i].deliveryState == .sent {
            t[i].deliveryState = .delivered
            MessageDB.shared.updateState(id: t[i].id, state: .delivered)
            changed = true
        }
        if changed { threads[thread] = t }
    }

    /// Idempotent. Toggle decisions live in `MessageService.toggleReaction`.
    ///
    /// Returns whether this actually CHANGED anything, and the caller is
    /// expected to care. The same envelope reaches us twice by design — once
    /// live over the socket and once from the offline queue, which the backend
    /// keeps a copy in until it is acked — and a message is protected from the
    /// second copy by its UUID dedup. A reaction had no such guard: re-applying
    /// it painted the same heart, which is invisible, but it also re-rang the
    /// unseen-reaction indicator, which is not. Founder saw exactly that: the
    /// heart he had just cleared by opening the chat was back after leaving and
    /// coming in again, for a reaction he had already looked at.
    @discardableResult
    func applyReaction(targetID: UUID, thread: ThreadID, uin: Int, asset: String?) -> Bool {
        ensureLoaded(thread)
        guard var t = threads[thread] else { return false }
        guard let idx = t.firstIndex(where: { $0.id == targetID }) else { return false }
        var reactions = t[idx].reactions
        guard reactions[uin] != asset else { return false }
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
        return true
    }

    /// Apply a reaction located by its target message id across ALL threads
    /// (1:1 + group). Used for self-echoes: a reaction you made on another
    /// device, sealed to your own identity, arrives with only the target id and
    /// no reliable thread (the sender is yourself, so the thread would resolve
    /// to your own peer thread, not where the message lives). The id is a
    /// globally-unique UUID, so it matches exactly one message.
    ///
    /// Returns the thread only when the reaction was NEW — that return value
    /// feeds the unseen-reaction indicator, and a redelivered copy of something
    /// already on the bubble is not news.
    @discardableResult
    func applyReactionAnywhere(targetID: UUID, uin: Int, asset: String?) -> ThreadID? {
        // Which chat the reacted message lives in is asked of the STORE, not
        // of the windows in memory. Scanning memory was right while launch
        // rehydrated every thread; with windows read on demand it would lose
        // the reaction for any chat not opened yet this session.
        if let thread = MessageDB.shared.threadOf(id: targetID) {
            ensureLoaded(thread)
            if threads[thread]?.contains(where: { $0.id == targetID }) == true {
                return applyReaction(targetID: targetID, thread: thread, uin: uin, asset: asset)
                    ? thread
                    : nil
            }
        }
        // Known to the database but older than the window we keep, or unknown
        // entirely. A reaction to an older message used to vanish here — not
        // drawn, and not stored either, so it never appeared when the chat was
        // scrolled up. The row is in the database; put it there and let the
        // next load of that window pick it up. No thread is returned: the
        // indicator points at a message the user cannot be scrolled to yet.
        MessageDB.shared.mergeReaction(id: targetID, uin: uin, asset: asset)
        return nil
    }

    /// Apply a deleteForEveryone tombstone. Row stays as a placeholder.
    func tombstone(messageID: UUID, thread: ThreadID) {
        ensureLoaded(thread)
        guard var t = threads[thread] else { return }
        guard let idx = t.firstIndex(where: { $0.id == messageID }) else { return }
        let m = t[idx]
        let tomb = Message(
            id: m.id, thread: m.thread, senderUIN: m.senderUIN,
            isFromMe: m.isFromMe, kind: m.kind, text: "",
            mediaID: nil, sentAt: m.sentAt,
            deliveryState: m.deliveryState, receivedWhileAway: m.receivedWhileAway,
            deletedForEveryone: true,
            ttlSeconds: m.ttlSeconds,
            senderSentAt: m.senderSentAt
        )
        withAnimation(.easeInOut(duration: 0.3)) {
            t[idx] = tomb
            threads[thread] = t
        }
        MessageDB.shared.markDeletedForEveryone(id: messageID)
    }

    func clearThread(_ thread: ThreadID) {
        threads[thread] = nil
        hasOlderInDB[thread] = nil
        loadedThreads.remove(thread)
        MessageDB.shared.deleteThread(thread)
    }

    func clearAll() {
        threads = [:]
        hasOlderInDB = [:]
        loadedThreads.removeAll()
        MessageDB.shared.deleteAll()
    }

    /// Soft account-switch reset: drop the in-memory thread cache WITHOUT
    /// deleting any rows. History lives in a per-account SQLite file
    /// (`rcq-history-<accountID>-v8.sqlite`) that must survive so switching back
    /// resumes the conversation. Use [clearAll] only for a true burn/migrate.
    func resetInMemory() {
        threads = [:]
        hasOlderInDB = [:]
        loadedThreads.removeAll()
    }
}

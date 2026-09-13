import Foundation

/// The last nickname each group member was seen under, kept after they leave.
///
/// #982: the name above a group bubble was looked up in the CURRENT roster and
/// fell back to the number, and the island hard-deletes a membership row on
/// leave, so everyone who ever left a room turned into a UIN in its history
/// while the quotes of their messages (which carry a stored author name) kept
/// the name. Worse, replying to such a message wrote the UIN into the outgoing
/// quote, so the number reached every member.
///
/// Keyed by island host AND group id AND uin: a uin is issued per island, and
/// a foreign group's id here is a local negative alias. The own island's
/// groups use an empty host (the file is per account, and an account IS its
/// own island), so the key does not move when the transport front does.
///
/// Every roster read overwrites (newest name wins); a member leaving removes
/// nothing. A group's entries go when THIS user leaves or deletes the group,
/// or the group is deleted; all of them go with a burn. Nothing is read or
/// written in a decoy session. On disk it is one `RosterSnapshot` file per
/// account, sealed under the PIN data key like the roster itself.
@MainActor
final class GroupMemberNameStore: ObservableObject {
    static let shared = GroupMemberNameStore()

    /// `groupKey` → uin → nickname, for the account in `account`.
    @Published private(set) var names: [String: [Int: String]] = [:]

    /// The account `names` belongs to. A different active account resets it.
    private var account: UUID?
    /// True once the file for `account` has been read (or found absent).
    /// Nothing is written before that, so a partial map never replaces a
    /// full one on disk.
    private var loaded = false
    private var loadTask: Task<Void, Never>?
    /// Debounced write. Rosters of a big room arrive often and mostly
    /// unchanged; a change is written once, two seconds later.
    private var saveTask: Task<Void, Never>?
    /// The write in flight, off the main thread. Writes are chained so an
    /// older map never lands after a newer one, and `wipe` waits on it.
    private var writeTask: Task<Void, Never>?
    /// Group keys forgotten before the file was read, so the read cannot put
    /// them back.
    private var forgottenBeforeLoad = Set<String>()
    /// Bumped by every reset, so a load or a debounced save that belongs to
    /// the previous state drops itself.
    private var generation = 0

    private init() {}

    static func groupKey(host: String?, groupID: Int) -> String {
        "\((host ?? "").lowercased())|\(groupID)"
    }

    /// Read the file for the active account once, off the main thread. Cheap
    /// to call on every chat open and every roster: it returns at once when
    /// the map is already there or on its way.
    func ensureLoaded() {
        if PanicPINService.shared.isDecoy { return }
        let active = AppGroup.readActiveAccountID()
        if account != active {
            reset()
            account = active
        }
        guard !loaded, loadTask == nil, let id = active else { return }
        // A PIN is set but not unlocked in this process: the file is sealed
        // and unreadable now. Not marking it read keeps a partial map off disk.
        if PanicPINService.shared.isConfigured, PanicPINService.shared.dataKey == nil { return }
        let key = PanicPINService.shared.dataKey
        let gen = generation
        loadTask = Task { [weak self] in
            let disk = await Task.detached(priority: .utility) {
                RosterSnapshot.loadOffMain(.memberNames, as: [String: [Int: String]].self, dataKey: key, accountID: id)
            }.value
            guard let self, gen == self.generation else { return }
            self.loadTask = nil
            self.loaded = true
            // Disk first, then whatever rosters landed while it was read:
            // those are newer. A file that would not open (sealed under a PIN
            // since changed) counts as empty and is rewritten by the next change.
            var merged = disk ?? [:]
            for key in self.forgottenBeforeLoad { merged[key] = nil }
            let pending = self.names
            for (group, members) in pending {
                merged[group, default: [:]].merge(members) { _, newer in newer }
            }
            self.forgottenBeforeLoad = []
            if merged != self.names { self.names = merged }
            if merged != (disk ?? [:]) { self.scheduleSave() }
        }
    }

    /// Take the names from a roster that was just read. Only a change
    /// publishes and schedules a write.
    func record(_ group: RCQGroup) {
        guard !group.members.isEmpty, !PanicPINService.shared.isDecoy else { return }
        ensureLoaded()
        let key = Self.groupKey(host: group.host, groupID: group.id)
        var entry = names[key] ?? [:]
        var changed = false
        for m in group.members where !m.nickname.isEmpty && entry[m.uin] != m.nickname {
            entry[m.uin] = m.nickname
            changed = true
        }
        // Rejoined before the file was read: the fresh roster is the truth.
        forgottenBeforeLoad.remove(key)
        guard changed else { return }
        names[key] = entry
        scheduleSave()
    }

    /// This user left or deleted the group, or it was deleted. Written at
    /// once rather than debounced: this is the one change that removes names.
    func forget(host: String?, groupID: Int) {
        let key = Self.groupKey(host: host, groupID: groupID)
        if !loaded { forgottenBeforeLoad.insert(key) }
        guard names[key] != nil else { return }
        names[key] = nil
        saveTask?.cancel()
        saveTask = nil
        saveSnapshot()
    }

    private func scheduleSave() {
        guard saveTask == nil else { return }
        let gen = generation
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled, gen == self.generation else { return }
            self.saveTask = nil
            self.saveSnapshot()
        }
    }

    /// Write the map now, under the current sealing. Also the reseal hook
    /// for a PIN that was just set or removed (`RosterSnapshot.resealAll`).
    func saveSnapshot() {
        guard loaded, let gate = RosterSnapshot.writeGate(accountID: account) else { return }
        let snapshot = names
        let previous = writeTask
        writeTask = Task.detached(priority: .utility) {
            await previous?.value
            if Task.isCancelled { return }
            RosterSnapshot.saveOffMain(snapshot, as: .memberNames, accountID: gate.accountID, dataKey: gate.dataKey)
        }
    }

    /// Memory only: an account switch (the file stays with its account) and
    /// a decoy session (nothing of the real account may be on screen).
    func clearMemory() {
        reset()
        account = nil
    }

    /// For a burn: drop the map and wait out a write in flight, so the
    /// caller's file delete is the last word on disk.
    func wipe() async {
        reset()
        account = nil
        let pending = writeTask
        writeTask = nil
        pending?.cancel()
        await pending?.value
    }

    private func reset() {
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        saveTask?.cancel()
        saveTask = nil
        loaded = false
        forgottenBeforeLoad = []
        if !names.isEmpty { names = [:] }
    }
}

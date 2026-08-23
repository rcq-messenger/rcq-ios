import Combine
import Foundation

@MainActor
final class ContactListViewModel: ObservableObject {
    @Published var collapsedOnline: Bool = false
    // Offline collapses by default — testers' feedback was that the
    // long list of offline contacts pushed groups + audio rooms
    // off-screen on first open. Online stays expanded so the
    // "who's around right now" surface reads as live.
    //
    // ⚠ NEVER in a decoy session. The whole seeded roster is a handful of
    // contacts and this is the only section they can land in, so the default
    // collapse folded the entire duress view away behind one header — the
    // decoy opened on a chat list with nothing in it, which is the exact
    // outcome the seeding exists to prevent.
    @Published var collapsedOffline: Bool = !PanicPINService.shared.isDecoy
    /// Set once the first `refresh()` resolves. Gates the empty-state
    /// CTA so a cold launch with non-empty contacts doesn't flash the
    /// "Add contact" placeholder for one frame before the contacts
    /// stream populates.
    @Published var hasLoadedOnce: Bool = false

    private let service = ContactService.shared
    private var cancellables = Set<AnyCancellable>()

    @Published var contacts: [Contact] = []
    @Published var pendingCount: Int = 0

    // MARK: - Derived sections
    //
    // ⚠ These are STORED, and they used to be computed properties. That is the
    // difference between deriving the roster once per change and deriving it
    // once per body, and the chat list re-runs its body constantly: fifteen
    // observed objects feed it, `updatePresence` re-emits the whole contacts
    // array on every presence frame, and until this commit every touch-down on
    // a row rewrote a `@State` on the screen itself. Each of those re-runs
    // walked the whole roster four times over and sorted it four more, with
    // `nickname.lowercased()` allocated twice per comparison: O(n log n)
    // string allocations for a frame in which nothing about the roster had
    // changed. The call site made it worse by asking for `.count` and then for
    // the array, which evaluated the same property twice.
    //
    // Now one pass over the roster fills all four, and it runs only when the
    // roster or the archive actually moves.

    /// Online section, filtered by archive state. Archived contacts
    /// drop out of the regular online/offline groups and live under a
    /// dedicated section at the bottom of the list. Cross-island contacts
    /// (`host != nil`) live in their own "Other islands" section, because presence
    /// isn't tracked across islands, so online/offline would be a lie.
    @Published private(set) var online: [Contact] = []

    @Published private(set) var offline: [Contact] = []

    @Published private(set) var offlineUnreadContacts: Int = 0

    /// Archived contacts, cross-island ones included: being archived is the
    /// only question this section asks.
    @Published private(set) var archivedContacts: [Contact] = []

    /// Starred contacts, name-sorted. Self-contacts are suppressed: an account
    /// can momentarily surface itself as a contact, and starring a
    /// chat-with-myself row shouldn't be possible.
    @Published private(set) var favoriteContacts: [Contact] = []

    /// The user's own sections (founder item 1 of 23.08): member key -> the id
    /// of the section holding it, already narrowed to the sections this client
    /// will draw.
    ///
    /// ⚠⚠ EMPTY when the island said it has no vault, and NOT empty when it has
    /// not answered yet. Treating "unknown" as "no vault" spills the members of
    /// a PIN-gated section into Online / Offline / Other islands, by name and
    /// with their unread badges, while the section's own header is dropped. A
    /// chat can only BE filed if the island had a vault when it was filed.
    ///
    /// ⚠ The key carries the HOST. `1234` here and `1234@is2.rcq.app` are two
    /// different people.
    @Published private(set) var sectionIndex: [String: String] = [:]

    /// Contacts filed into a user section, keyed by section id, in the order
    /// the section draws them: unread first, then favourite (which survives
    /// filing as a flag even though it has no section of its own to render
    /// into), then this client's usual name sort.
    ///
    /// Built in the SAME single pass as online / offline / archived, because
    /// the whole point of that pass is that the chat list never walks the
    /// roster again on a body it re-runs constantly.
    @Published private(set) var filedContacts: [String: [Contact]] = [:]

    init() {
        // Seeded, not only subscribed: the service is already holding the
        // roster (from disk on a cold start) when this view model is made,
        // and `assign` alone would paint one empty frame and then re-diff the
        // whole list. Both are `@MainActor`, so no queue hop either.
        contacts = service.contacts
        pendingCount = service.pendingRequests.count
        hasLoadedOnce = service.hydratedFromSnapshot || service.rosterLoaded
        // ⚠ Subscribed to the SERVICE rather than to our own republished
        // `$contacts`. A `@Published` emits in `willSet`, so a sink hung off
        // our own property would see the roster we are replacing, not the one
        // arriving; taking the incoming value from the service leaves no way to
        // read the stale one by accident.
        service.$contacts
            .dropFirst()
            .sink { [weak self] list in
                self?.contacts = list
                self?.repartition(list)
            }
            .store(in: &cancellables)
        service.$pendingRequests
            .dropFirst()
            .map { $0.count }
            .assign(to: &$pendingCount)
        // Archiving and starring re-file rows without the roster changing, so
        // they get the same one-pass treatment rather than being re-derived on
        // every body the way they were when these were computed properties.
        ArchiveStore.shared.$entries
            .dropFirst()
            .sink { [weak self] archived in
                guard let self else { return }
                self.repartition(self.contacts, archived: archived)
            }
            .store(in: &cancellables)
        FavoritesStore.shared.$entries
            .dropFirst()
            .sink { [weak self] starred in
                guard let self else { return }
                self.favoriteContacts = Self.favorites(
                    in: self.contacts, starred: starred, filed: self.sectionIndex
                )
            }
            .store(in: &cancellables)
        // Filing a chat into a section re-files a row without the roster
        // changing, exactly like archiving does, so it gets the same one-pass
        // treatment rather than a filter per body.
        sectionIndex = Self.index(tree: SectionsStore.shared.tree, gate: AppState.shared.vaultCapability)
        repartition(service.contacts)
        SectionsStore.shared.$tree
            .dropFirst()
            .sink { [weak self] tree in
                guard let self else { return }
                self.applySections(tree: tree, gate: AppState.shared.vaultCapability)
            }
            .store(in: &cancellables)
        // ⚠ Two publishers, and each sink takes ITS OWN incoming value and
        // reads the other one settled. `refreshServerInfo` sets `serverInfoRead`
        // and then `serverCapabilities`, and a `@Published` emits in `willSet`,
        // so a sink that read both off `AppState` would see one of them stale.
        AppState.shared.$serverCapabilities
            .dropFirst()
            .sink { [weak self] caps in
                guard let self else { return }
                let read = AppState.shared.serverInfoRead
                self.applySections(tree: SectionsStore.shared.tree, gate: read ? caps.vault : nil)
            }
            .store(in: &cancellables)
        AppState.shared.$serverInfoRead
            .dropFirst()
            .sink { [weak self] read in
                guard let self else { return }
                let vault = AppState.shared.serverCapabilities.vault
                self.applySections(tree: SectionsStore.shared.tree, gate: read ? vault : nil)
            }
            .store(in: &cancellables)
    }

    private func applySections(tree: SectionsTree, gate: Bool?) {
        let next = Self.index(tree: tree, gate: gate)
        guard next != sectionIndex else { return }
        sectionIndex = next
        repartition(contacts, index: next)
    }

    /// member key -> section id, for the sections this client will draw.
    ///
    /// A membership pointing at a section this build does not hold (deleted
    /// elsewhere, not synced yet) is left out here, so the chat falls back to
    /// its derived section: rendering is where a stale membership is forgiven,
    /// never where it is deleted.
    private static func index(tree: SectionsTree, gate: Bool?) -> [String: String] {
        guard gate != false else { return [:] }
        let live = Set(Sections.userSections(tree).map { Sections.id($0) })
        var out: [String: String] = [:]
        for (key, sid) in Sections.memberIndex(tree) where live.contains(sid) {
            out[key] = sid
        }
        return out
    }

    /// One walk over the roster that fills every section it feeds.
    ///
    /// `list` and `archived` are passed in rather than read off `self` for the
    /// `willSet` reason above: whichever of the two just changed arrives as an
    /// argument, and the other is read from the settled property.
    private func repartition(
        _ list: [Contact],
        archived: Set<ArchiveStore.Entry>? = nil,
        index: [String: String]? = nil
    ) {
        let archivedSet = archived ?? ArchiveStore.shared.entries
        let filedIndex = index ?? sectionIndex
        let starred = FavoritesStore.shared.entries
        // Sort keys are built ONCE per contact per pass instead of twice per
        // comparison: the roster is compared O(n log n) times and lowercasing
        // allocates a fresh String every time it is asked.
        var onlineRows: [(row: Contact, key: String)] = []
        var offlineRows: [(row: Contact, key: String, unread: Bool)] = []
        var archivedRows: [(row: Contact, key: String)] = []
        var filedRows: [String: [(row: Contact, key: String, unread: Bool, fav: Bool)]] = [:]
        var unreadCount = 0
        for contact in list {
            let key = contact.nickname.lowercased()
            if archivedSet.contains(.peer(uin: contact.uin)) {
                // Render precedence, the one line every client repeats:
                // archive > user section > derived. The membership is KEPT in
                // the slot, so un-archiving puts the chat straight back.
                archivedRows.append((contact, key))
                continue
            }
            // Cross-island rows come from CrossIslandStore, not from here, and
            // that includes filing them: one source per row, or a filed peer
            // would draw twice.
            guard contact.host == nil else { continue }
            if let sid = filedIndex[Sections.peerKey(contact.uin)] {
                // A chat in a user section leaves EVERY derived section:
                // Favorites, Groups, Online, Offline. It renders once.
                filedRows[sid, default: []].append(
                    (contact, key, contact.unread > 0, starred.contains(.peer(uin: contact.uin)))
                )
                continue
            }
            if contact.status == .offline {
                let hasUnread = contact.unread > 0
                if hasUnread { unreadCount += 1 }
                offlineRows.append((contact, key, hasUnread))
            } else {
                onlineRows.append((contact, key))
            }
        }
        online = onlineRows.sorted { $0.key < $1.key }.map(\.row)
        offline = offlineRows.sorted {
            if $0.unread != $1.unread { return $0.unread }
            return $0.key < $1.key
        }.map(\.row)
        archivedContacts = archivedRows.sorted { $0.key < $1.key }.map(\.row)
        // Inside a user section: unread first, then favourite, then the sort
        // this client already uses everywhere else.
        filedContacts = filedRows.mapValues { rows in
            rows.sorted {
                if $0.unread != $1.unread { return $0.unread }
                if $0.fav != $1.fav { return $0.fav }
                return $0.key < $1.key
            }.map(\.row)
        }
        offlineUnreadContacts = unreadCount
        favoriteContacts = Self.favorites(in: list, starred: starred, filed: filedIndex)
    }

    private static func favorites(
        in list: [Contact],
        starred: Set<FavoritesStore.Entry>,
        filed: [String: String]
    ) -> [Contact] {
        let myUIN = AuthService.shared.ownUIN
        return sortedByNickname(
            list.filter {
                starred.contains(.peer(uin: $0.uin))
                    && !($0.uin == myUIN && Multihome.isOwnHost($0.host))
                    // Favouriting is not cleared when a chat is filed; it just
                    // has no section to render into, and it still floats the
                    // row to the top INSIDE the user section.
                    && filed[Sections.peerKey($0.uin, host: $0.host)] == nil
            }
        )
    }

    /// Name-sort with the key built once per element. Shared with the
    /// cross-island section, which sorts a list this model does not own.
    static func sortedByNickname(_ list: [Contact]) -> [Contact] {
        list.map { (row: $0, key: $0.nickname.lowercased()) }
            .sorted { $0.key < $1.key }
            .map(\.row)
    }

    /// The list mounting or being pulled has no intent of its own: a fetch
    /// already in the air (the boot's) is the answer it wants.
    func refresh() async {
        await service.refresh(joinInFlight: true)
        hasLoadedOnce = true
    }
    func remove(_ uin: Int) async { try? await service.remove(uin) }
    func toggleBlock(_ uin: Int) async { try? await service.toggleBlock(uin) }
}

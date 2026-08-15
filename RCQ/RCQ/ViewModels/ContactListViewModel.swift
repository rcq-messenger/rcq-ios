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

    init() {
        service.$contacts.receive(on: DispatchQueue.main).assign(to: &$contacts)
        service.$pendingRequests
            .receive(on: DispatchQueue.main)
            .map { $0.count }
            .assign(to: &$pendingCount)
    }

    /// Online section, filtered by archive state. Archived contacts
    /// drop out of the regular online/offline groups and live under a
    /// dedicated section at the bottom of the list. Cross-island contacts
    /// (`host != nil`) live in their own "Other islands" section — presence
    /// isn't tracked across islands, so online/offline would be a lie.
    var online: [Contact] {
        contacts
            .filter { $0.host == nil && $0.status != .offline && !ArchiveStore.shared.contains(peer: $0.uin) }
            .sorted { $0.nickname.lowercased() < $1.nickname.lowercased() }
    }

    var offline: [Contact] {
        contacts
            .filter { $0.host == nil && $0.status == .offline && !ArchiveStore.shared.contains(peer: $0.uin) }
            .sorted {
                if ($0.unread > 0) != ($1.unread > 0) { return $0.unread > 0 }
                return $0.nickname.lowercased() < $1.nickname.lowercased()
            }
    }

    var offlineUnreadContacts: Int {
        contacts.filter {
            $0.host == nil
                && $0.status == .offline
                && !ArchiveStore.shared.contains(peer: $0.uin)
                && $0.unread > 0
        }.count
    }

    var archivedContacts: [Contact] {
        contacts
            .filter { ArchiveStore.shared.contains(peer: $0.uin) }
            .sorted { $0.nickname.lowercased() < $1.nickname.lowercased() }
    }

    func refresh() async {
        await service.refresh()
        hasLoadedOnce = true
    }
    func remove(_ uin: Int) async { try? await service.remove(uin) }
    func toggleBlock(_ uin: Int) async { try? await service.toggleBlock(uin) }
}

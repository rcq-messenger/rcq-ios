import Combine
import Foundation

/// The cached sections tree.
///
/// Same shape as `ArchiveStore`: one `@Published` value the chat list observes,
/// one UserDefaults key behind it, and a `wipe()` for the burn hook. The tree
/// itself is the VAULT's, not this device's: `SectionsVault` folds the island's
/// copy into this cache and pushes local edits back out. The cache exists so a
/// cold start on a plane still draws the user's sections.
///
/// ⚠⚠ SCOPED BY ACCOUNT, unlike the favourites/archive keys next door. This
/// cache holds section names and the uin of every filed chat, so a flat key
/// would hand one account's list to the next one signed in on this device, and
/// would hand the REAL account's list to a decoy session. It is rebound
/// wherever `CrossIslandStore` is rebound: on an account switch, on entering a
/// duress session, and on leaving one.
///
/// The collapsed state of a section is deliberately NOT here: which sections
/// are folded up is a per-screen view preference, it stays device-local, and
/// the unlocked state of a PIN-gated section is not even that (view memory
/// only, see `ContactListView`).
@MainActor
final class SectionsStore: ObservableObject {
    static let shared = SectionsStore()

    /// The decoded tree, always readable: an empty tree when there is nothing
    /// cached, so every consumer can index into it without a nil dance.
    @Published private(set) var tree: SectionsTree = Sections.emptyTree()

    private static let treePrefix = "rcq.sections.v1."
    private static let pendingPrefix = "rcq.sections.pending.v1."

    private var treeKey: String
    private var pendingKey: String

    private init() {
        let id = AppGroup.readActiveAccountID()
        treeKey = Self.treePrefix + (id?.uuidString ?? "none")
        pendingKey = Self.pendingPrefix + (id?.uuidString ?? "none")
        load()
    }

    /// Re-point at the active account on launch, on every account switch, and
    /// on both directions of the duress swap.
    func bind(accountID: UUID?) {
        treeKey = Self.treePrefix + (accountID?.uuidString ?? "none")
        pendingKey = Self.pendingPrefix + (accountID?.uuidString ?? "none")
        load()
        SectionsVault.resetSyncState()
    }

    func save(_ next: SectionsTree) {
        tree = next
        UserDefaults.standard.set(Sections.encode(next), forKey: treeKey)
    }

    /// "This device has an edit the island has not confirmed." Persisted,
    /// because the case that matters most is the one that outlives the process:
    /// a section made on the underground, a write that failed, the app killed,
    /// and on the next cold start the island's VERSION has not moved either, so
    /// the reconnect sweep would skip the slot entirely. Set the moment the
    /// cache is edited, cleared only when a write comes back saying the
    /// island's copy includes ours.
    var pushPending: Bool {
        UserDefaults.standard.bool(forKey: pendingKey)
    }

    func markPending(_ on: Bool) {
        if on {
            UserDefaults.standard.set(true, forKey: pendingKey)
        } else {
            UserDefaults.standard.removeObject(forKey: pendingKey)
        }
    }

    /// Burn-account hook. The tree is a copy of the vault slot, so dropping it
    /// costs nothing but a re-read on a device that still has the account.
    func wipe() {
        tree = Sections.emptyTree()
        UserDefaults.standard.removeObject(forKey: treeKey)
        UserDefaults.standard.removeObject(forKey: pendingKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: treeKey),
              let decoded = Sections.decode(data) else {
            tree = Sections.emptyTree()
            return
        }
        tree = decoded
    }
}

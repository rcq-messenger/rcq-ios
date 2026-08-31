import Foundation

/// Federation Layer B (F2) — local store of cross-island contacts.
///
/// A peer on ANOTHER island is not a flagship user, so it can't live in the
/// server-side `/contacts` list. We keep cross-island contacts on-device, keyed
/// `uin@host`, as full `Contact`s (with `host` set + the keys from the peer's
/// island key card). `ContactService` merges these into its published list so
/// the normal chat-open + send flow works; `MessageService.sendEnvelope` routes
/// by `contact.host`. Mirrors web-chat's crossisland-store + Android's.
/// ObservableObject so the contact list's "Other islands" section renders
/// straight from this store: the merged ContactService list silently DROPS a
/// cross-island contact when a same-uin LOCAL contact exists (per-island uins
/// collide), which made an accepted cross-island peer invisible in the roster
/// (founder report). The section reads the snapshot; the merge stays for the
/// chat-open path.
final class CrossIslandStore: ObservableObject {
    static let shared = CrossIslandStore()

    /// Live copy of the stored contacts for SwiftUI (always `host != nil`).
    @Published private(set) var contactsSnapshot: [Contact] = []

    private static let appGroup = "group.app.rcq.shared"
    // Per-account: a cross-island contact added on one local account must NOT
    // bleed into another (founder report: `911@api` added on the is2 account
    // showed up on the 911 account, where it read as "I added myself"). The
    // old single global key `rcq.crossisland.contacts.v1` is left orphaned.
    private static let keyPrefix = "rcq.crossisland.contacts.v1."
    /// §5e stale guard: the `ts` of the last profile refresh we APPLIED, per
    /// `uin@host`. Kept beside the rows (same App Group container, same
    /// per-account slot) so it survives a relaunch — an offline-queue drain
    /// hands us envelopes in whatever order the mailbox held them.
    private static let profileTSPrefix = "rcq.crossisland.profilets.v1."

    private let defaults: UserDefaults
    private var accountKey: String
    private var profileTSKey: String
    private var cache: [String: Contact]   // keyed "uin@host"
    private var profileTS: [String: Int]

    private init() {
        defaults = UserDefaults(suiteName: Self.appGroup) ?? .standard
        // Non-isolated file read (same source MessageDB/KeychainStore resolve
        // the per-account slot from) so init stays off the main actor.
        let account = AppGroup.readActiveAccountID()
        accountKey = Self.keyFor(account)
        profileTSKey = Self.profileTSKeyFor(account)
        cache = Self.load(defaults, accountKey)
        profileTS = (defaults.dictionary(forKey: profileTSKey) as? [String: Int]) ?? [:]
        contactsSnapshot = Array(cache.values)
    }

    private static func keyFor(_ id: UUID?) -> String {
        keyPrefix + (id?.uuidString ?? "none")
    }

    private static func profileTSKeyFor(_ id: UUID?) -> String {
        profileTSPrefix + (id?.uuidString ?? "none")
    }

    private static func load(_ defaults: UserDefaults, _ key: String) -> [String: Contact] {
        guard let data = defaults.data(forKey: key),
              let map = try? JSONDecoder().decode([String: Contact].self, from: data) else { return [:] }
        return map
    }

    /// Re-point at the active account's cross-island contacts. Called on launch
    /// and on every account switch (AppState.rebootForActiveAccount), so the
    /// list is per-account and never bleeds across local accounts.
    func bind(accountID: UUID?) {
        accountKey = Self.keyFor(accountID)
        profileTSKey = Self.profileTSKeyFor(accountID)
        profileTS = (defaults.dictionary(forKey: profileTSKey) as? [String: Int]) ?? [:]
        cache = Self.load(defaults, accountKey)
        pruneOwnIsland()
        contactsSnapshot = Array(cache.values)
    }

    /// Forget every cross-island contact of the active account (burn only).
    ///
    /// A burn mints a fresh identity under the SAME account UUID, so the key
    /// these rows live under does not change and nothing else clears them:
    /// the burned identity's foreign contacts came back attached to the new
    /// one, which is the opposite of what "erase this account" promises. A
    /// switch must NOT call this, `bind` is that path: the rows belong to an
    /// account the user still has.
    func wipe() {
        defaults.removeObject(forKey: accountKey)
        defaults.removeObject(forKey: profileTSKey)
        cache = [:]
        profileTS = [:]
        contactsSnapshot = []
    }

    /// Drop entries filed under one of OUR OWN island's names.
    ///
    /// They should never have been written, but were: while the app was
    /// running over the Cloudflare front, `Multihome.ownHost()` returned the
    /// front instead of the island, so same-island peers read as foreign and
    /// accepting their "cross-island request" filed a duplicate here. The
    /// duplicate then rendered under "other islands" next to the real roster
    /// row. `isOwnHost` is fixed now, but the rows already on disk have to go,
    /// and the user cannot delete them (that section has no swipe action).
    private func pruneOwnIsland() {
        let stale = cache.filter { Multihome.isOwnHost($0.value.host) }
        guard !stale.isEmpty else { return }
        for key in stale.keys { cache.removeValue(forKey: key) }
        persist()
    }

    private func ciKey(_ uin: Int, _ host: String) -> String { "\(uin)@\(host.lowercased())" }

    func save(_ c: Contact) {
        // Never file a peer from our own island here — the roster owns those.
        guard let host = c.host, !Multihome.isOwnHost(host) else { return }
        cache[ciKey(c.uin, host)] = c
        persist()
        contactsSnapshot = Array(cache.values)
    }

    /// All stored cross-island contacts (each has `host` set).
    func all() -> [Contact] { Array(cache.values) }

    /// Map an incoming sealed message's senderUIN back to a cross-island contact.
    /// Per-island uins can collide in theory; returns the first match.
    func find(uin: Int) -> Contact? { cache.values.first { $0.uin == uin } }

    func remove(uin: Int, host: String) {
        let key = ciKey(uin, host)
        cache.removeValue(forKey: key)
        profileTS.removeValue(forKey: key)
        defaults.set(profileTS, forKey: profileTSKey)
        persist()
        contactsSnapshot = Array(cache.values)
    }

    /// §5e receive: refresh the DISPLAY fields of an EXISTING cross-island row.
    ///
    /// Deliberately narrow, and the narrowness is the point:
    ///  - a sender we do not already hold as an accepted cross-island contact
    ///    gets nothing — no row, no pending entry. It is cosmetic data from a
    ///    stranger, so it is dropped;
    ///  - the pinned `identityKey` / `signingKey` / `signalIdentityKey` are
    ///    never touched. They are the anti-impersonation anchor, and an inbound
    ///    envelope that could write them would BE the impersonation path. This
    ///    mutates a copy of the stored row, so they carry over untouched;
    ///  - an envelope older than the last one we applied for this peer is
    ///    ignored (queue drains replay out of order);
    ///  - the write goes to disk, not just to `contactsSnapshot`: the push path
    ///    reads the stored snapshot with no live session, so a memory-only
    ///    update would leave notifications showing the old name.
    ///
    /// A device-local alias still outranks whatever lands here — every display
    /// path resolves through `ContactAliasStore.displayName(for:fallback:)`, and
    /// this only ever writes the fallback.
    ///
    /// Returns the updated row when something actually changed, else nil.
    @discardableResult
    func applyProfile(
        uin: Int, host: String, ts: Int,
        nickname: String?, avatarMediaID: String?, avatarMediaKey: String?
    ) -> Contact? {
        let key = ciKey(uin, host)
        guard var row = cache[key] else { return nil }
        if let last = profileTS[key], ts < last { return nil }
        var changed = false
        // Bounded like web's 64: a peer must not be able to write an unbounded
        // string into our roster and onto our disk.
        if let raw = nickname?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let nick = String(raw.prefix(64))
            if nick != row.nickname {
                row.nickname = nick
                changed = true
            }
        }
        // ⚠ A SNAPSHOT, not a patch. The envelope always states the sender's
        // WHOLE current display state, so an absent picture means "I have none
        // now" and the one we hold goes. Web and Android read it the same way;
        // treating absence as "unchanged" here would mean a peer who removes
        // their picture keeps their old face on iOS forever while it vanishes
        // on the other two clients.
        //
        // Safe only because the SEND side never emits a spuriously-absent
        // picture: a sender that HAS a picture whose blob did not land on this
        // island skips the envelope entirely rather than sending the name alone
        // (CrossIslandSender.broadcastProfile / sendProfile). So absence on the
        // wire is a deliberate clear, not a transient media failure.
        //
        // Both halves or neither: the id is useless without its key, and
        // `GET /media/{id}` is unauthenticated so the key IS the access.
        //
        // The id is charset- and length-gated because it is interpolated
        // straight into `/media/{id}`: a peer-supplied `../…` must not steer
        // that fetch anywhere but at a blob. Same gate web and Android apply,
        // so the three clients accept exactly the same set of ids.
        var mid: String? = nil
        if let raw = avatarMediaID?.trimmingCharacters(in: .whitespacesAndNewlines),
           raw.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil {
            mid = raw
        }
        var mkey: String? = nil
        if let raw = avatarMediaKey?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty, raw.count <= 128 {
            mkey = raw
        }
        let nextID: String? = (mid != nil && mkey != nil) ? mid : nil
        let nextKey: String? = nextID == nil ? nil : mkey
        if nextID != row.avatarMediaID || nextKey != row.avatarMediaKey {
            row.avatarMediaID = nextID
            row.avatarMediaKey = nextKey
            changed = true
        }
        profileTS[key] = ts
        defaults.set(profileTS, forKey: profileTSKey)
        guard changed else { return nil }
        cache[key] = row
        persist()
        contactsSnapshot = Array(cache.values)
        return row
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(cache) {
            defaults.set(data, forKey: accountKey)
        }
    }
}

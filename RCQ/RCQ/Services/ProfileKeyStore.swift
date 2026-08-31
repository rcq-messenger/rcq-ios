import Foundation

/// The keys that open profile pictures: other people's, and my own.
///
/// The island used to hold these itself, in `users.avatar_media_key`, in the
/// same row as the uin and the nickname — so a seized island decrypted every
/// face it stored. Now the owner seals the key to their contacts and this is
/// where it lands. See docs/profile-key-design.md.
///
/// Modelled on `RoomKeyStore` deliberately, down to the decoy guard and the
/// main-actor isolation: a decoy session must never read or write the real
/// account's keys.
@MainActor
final class ProfileKeyStore {
    static let shared = ProfileKeyStore()

    private var peers: [Int: String] = [:]
    private var loadedFor: String?

    private func peersKey(_ account: String) -> String { "rcq.pkeys.v1.\(account)" }
    private func mineKey(_ account: String) -> String { "rcq.pkey.mine.v1.\(account)" }

    private var accountID: String? {
        guard !PanicPINService.shared.isDecoy else { return nil }
        return AccountManager.shared.activeAccountID?.uuidString
    }

    func hydrate() {
        guard let acct = accountID else { peers = [:]; loadedFor = nil; return }
        guard loadedFor != acct else { return }
        loadedFor = acct
        peers = [:]
        guard let raw = UserDefaults.standard.dictionary(forKey: peersKey(acct)) as? [String: String] else { return }
        for (uin, k) in raw {
            if let u = Int(uin) { peers[u] = k }
        }
    }

    /// The key that opens `uin`'s picture, or nil when we were never given it.
    ///
    /// ⚠ nil must render exactly like "this person has no picture". If the two
    /// look different, the tile becomes an oracle for "am I entitled to see
    /// this", which is the question the key is supposed to answer silently.
    func key(for uin: Int) -> String? {
        hydrate()
        return peers[uin]
    }

    @discardableResult
    func put(_ uin: Int, keyB64: String) -> Bool {
        hydrate()
        guard let acct = accountID, !keyB64.isEmpty, peers[uin] != keyB64 else { return false }
        peers[uin] = keyB64
        UserDefaults.standard.set(
            peers.reduce(into: [String: String]()) { $0["\($1.key)"] = $1.value },
            forKey: peersKey(acct)
        )
        return true
    }

    /// My own key: minted once and REUSED across picture changes. Changing the
    /// key would cost a fan-out every time and leave contacts on a blank tile
    /// until it landed.
    var mine: String? {
        guard let acct = accountID else { return nil }
        return UserDefaults.standard.string(forKey: mineKey(acct))
    }

    func setMine(_ keyB64: String) {
        guard let acct = accountID, !keyB64.isEmpty else { return }
        UserDefaults.standard.set(keyB64, forKey: mineKey(acct))
    }

    /// Forget everything for the active account (burn / account switch).
    func wipe() {
        guard let acct = accountID else { return }
        UserDefaults.standard.removeObject(forKey: peersKey(acct))
        UserDefaults.standard.removeObject(forKey: mineKey(acct))
        peers = [:]
        loadedFor = nil
    }
}

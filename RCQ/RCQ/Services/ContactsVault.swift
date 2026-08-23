import Foundation
import os.log

/// The contact list in the vault (stage 4 of the metadata plan, client half;
/// web `src/lib/contacts-vault.ts` and Android `data/ContactsVault.kt`, same
/// slot, same JSON).
///
/// Today's phase, "mirror": the island's `contacts` table is still what every
/// client (including the ones that have not updated) adds to and removes
/// from, so the server list is the truth and the vault holds a sealed copy of
/// it. Every successful `/contacts` fetch on an island that advertises `vault`
/// is folded into the account's `contacts` slot: entries the server has and
/// the slot does not are added, entries the server no longer has become
/// tombstones, and nothing is written when the slot already says the same.
///
/// Why bother before the table goes: the moment the island stops answering
/// `/contacts` (the read-only and drop steps of the plan), a reinstall or a
/// new device recovers its roster from this slot and from nowhere else, and a
/// client that shipped today already keeps the copy current.
///
/// ⚠ Server-wins is the rule of THIS phase only. A merge that let the slot
/// re-add what an old client removed on the island would resurrect deleted
/// contacts on every device; a merge that let the slot remove what the island
/// still has would drop contacts the other phone can see.
///
/// ⚠⚠ The #605 rule: never write the slot from local state alone. `mirror`
/// reads, folds, writes with the version it read, and goes around on a stale
/// answer. The island's nudge (`vault_changed`) has no replay, so a re-read
/// happens on every roster refresh anyway, which in this phase is enough.
enum ContactsVault {
    private static let log = OSLog(subsystem: "app.rcq.client", category: "ContactsVault")

    /// One edge. Field names are the wire's (one byte each, the slot is padded
    /// to 512-byte classes and a short key keeps more entries in a class):
    /// a = added ms, u = updated ms, b = 1 when blocked, n = last nickname
    /// seen, h = home island host for a cross-island peer.
    struct Entry: Codable, Equatable {
        var a: Int
        var u: Int
        var b: Int?
        var n: String?
        var h: String?
    }

    struct Blob: Codable, Equatable {
        var v: Int = 1
        var c: [String: Entry] = [:]
        var g: [String: Int] = [:]
    }

    enum Outcome { case written, unchanged, skipped, failed(String) }

    private static let tombstoneTTLMs = 90 * 24 * 3600 * 1000

    /// Set for the rest of the session when the island serves a version below
    /// the floor, or when another device retired this derivation
    /// (`vault_reset`). Keyed by account so switching accounts clears it.
    /// ⚠ A String, not an `Optional<UUID>`: an install with no active account
    /// id answers nil, and `nil == nil` would read as "stopped" straight away.
    private static var stoppedFor: String?

    private static func accountKey() -> String {
        AppGroup.readActiveAccountID()?.uuidString ?? "none"
    }

    /// Stop the slot for this session from outside: `/auth/reissue` on another
    /// device retired the derivation this install's slot name and seal key come
    /// from, so anything written from here would be sealed with a key the user
    /// has just declared dead, under a name nothing will ever read again.
    static func retire() {
        stoppedFor = accountKey()
        lastMirrored = nil
    }

    /// Account switch inside one process.
    static func resetSyncState() {
        stoppedFor = nil
        lastMirrored = nil
    }

    /// Re-read the slot because another device wrote it (`vault_changed`, or
    /// the reconnect sweep).
    ///
    /// The slot is still a MIRROR of the island's own list (stage 4, mirror
    /// phase), so re-reading it does not change what the app draws. What it
    /// does do is move the rollback floor up to what the other device just
    /// wrote, which is what keeps this install's next mirror write from opening
    /// with a 409, and drop the "already folded this list" fingerprint so the
    /// next `/contacts` refresh folds against the fresh copy instead of
    /// assuming its own is current.
    @MainActor
    static func refreshFromVault() async {
        guard !PanicPINService.shared.isDecoy else { return }
        guard AppState.shared.serverCapabilities.vault else { return }
        guard stoppedFor != accountKey() else { return }
        guard let ik = KeychainStore.data(KeychainStore.Keys.identityPriv) else { return }
        let slot = Vault.slotId(identityPriv: ik, name: Vault.contacts)
        guard let cur = try? await VaultClient.get(slot) else { return }
        if cur.version < VaultFloor.lastSeen(slot) {
            stoppedFor = accountKey()
            os_log("contacts slot is below the floor; the mirror is stopped for this session", log: log, type: .error)
            return
        }
        VaultFloor.remember(slot, cur.version)
        lastMirrored = nil
    }

    /// Fold the server's list into the slot. Never throws: the roster is on
    /// screen already and a vault that is down is not the user's problem at
    /// that moment. One at a time per process.
    private static var inFlight = false
    /// The edges last folded this process, as a fingerprint keyed by account,
    /// so a refresh that changed nothing costs no vault read.
    private static var lastMirrored: String?
    @MainActor
    static func mirror(_ list: [Contact]) async -> Outcome {
        guard AppState.shared.serverCapabilities.vault else { return .skipped }
        guard let ik = KeychainStore.data(KeychainStore.Keys.identityPriv) else { return .skipped }
        let onIsland = list.filter { $0.host == nil }
        let key = (AppGroup.readActiveAccountID()?.uuidString ?? "") + "|" + onIsland.map { "\($0.uin):\($0.blocked ? 1 : 0):\($0.nickname)" }.sorted().joined(separator: "\n")
        if key == lastMirrored { return .unchanged }
        if inFlight { return .skipped }
        inFlight = true
        defer { inFlight = false }
        guard stoppedFor != accountKey() else { return .skipped }
        let slot = Vault.slotId(identityPriv: ik, name: Vault.contacts)
        let now = Int(Date().timeIntervalSince1970 * 1000)
        var floor = VaultFloor.lastSeen(slot)
        do {
            for _ in 0..<5 {
                let cur = try await VaultClient.get(slot)
                if cur.version < floor {
                    // ⚠ The island served an older version than this install
                    // has seen. This used to clear the floor and rewrite the
                    // slot from the server list; it must not. The island cannot
                    // tell "restored from a backup" apart from "your derivation
                    // was retired by /auth/reissue", and rewriting there
                    // republishes the whole contact list under the retired slot
                    // name, sealed with the key the user has just declared
                    // compromised. Stop for the session and log it; a genuinely
                    // rolled-back island heals on its own, because another
                    // device's writes carry its version back over the floor.
                    stoppedFor = accountKey()
                    return .failed("rolled back: \(cur.version) < \(floor)")
                }
                var remote = Blob()
                if let b64 = cur.blob, let raw = Data(base64Encoded: b64) {
                    let plain = try Vault.open(identityPriv: ik, slot: slot, version: cur.version, blob: raw)
                    if let decoded = try? JSONDecoder().decode(Blob.self, from: plain), decoded.v == 1 {
                        remote = decoded
                    }
                }
                guard let next = fold(remote, onIsland, now: now) else {
                    VaultFloor.remember(slot, cur.version)
                    lastMirrored = key
                    return .unchanged
                }
                let sealed = try Vault.seal(identityPriv: ik, slot: slot, version: cur.version + 1, plaintext: try JSONEncoder().encode(next))
                let w = try await VaultClient.put(slot, blob: sealed.base64EncodedString(), basedOn: cur.version)
                if let v = w.version {
                    VaultFloor.remember(slot, v)
                    lastMirrored = key
                    return .written
                }
                // Stale: somebody else's write landed between our read and ours.
                floor = max(floor, w.current)
            }
            return .failed("conflict loop")
        } catch Vault.SealError.seal {
            // A blob this identity cannot open: another account's, a newer
            // format, or damage. Not ours to overwrite blindly in this phase.
            return .failed("bad seal")
        } catch {
            return .failed("\(error)")
        }
    }

    /// Pure: the slot after folding the server list in, or nil when nothing
    /// would change. Same rules as the web's foldServerList.
    static func fold(_ cur: Blob, _ list: [Contact], now: Int) -> Blob? {
        var c = cur.c
        var g = cur.g
        var changed = false
        var onServer = Set<String>()
        for ct in list {
            let k = String(ct.uin)
            onServer.insert(k)
            let prev = c[k]
            var entry = Entry(
                a: prev?.a ?? now,
                u: prev?.u ?? now,
                b: ct.blocked ? 1 : nil,
                n: ct.nickname.isEmpty ? nil : ct.nickname,
                h: (ct.host?.isEmpty ?? true) ? nil : ct.host
            )
            if prev == nil || !same(prev!, entry) {
                entry.u = now
                c[k] = entry
                changed = true
            }
            if g.removeValue(forKey: k) != nil { changed = true }
        }
        for k in Array(c.keys) where !onServer.contains(k) {
            c.removeValue(forKey: k)
            g[k] = now
            changed = true
        }
        for (k, t) in g where now - t > tombstoneTTLMs {
            g.removeValue(forKey: k)
            changed = true
        }
        return changed ? Blob(v: 1, c: c, g: g) : nil
    }

    private static func same(_ x: Entry, _ y: Entry) -> Bool {
        (x.b ?? 0) == (y.b ?? 0) && (x.n ?? "") == (y.n ?? "") && (x.h ?? "") == (y.h ?? "")
    }
}

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

    /// The highest version of the slot this install has seen, per account:
    /// the floor below which an island's answer is a rollback rather than data.
    private static var versionKey: String {
        guard let id = AppGroup.readActiveAccountID() else { return "rcq.vault.contacts.version" }
        return "rcq.vault.contacts.version.\(id.uuidString)"
    }
    private static var lastSeenVersion: Int {
        get { UserDefaults.standard.integer(forKey: versionKey) }
        set { UserDefaults.standard.set(newValue, forKey: versionKey) }
    }

    /// Fold the server's list into the slot. Never throws: the roster is on
    /// screen already and a vault that is down is not the user's problem at
    /// that moment. One at a time per process.
    private static var inFlight = false
    @MainActor
    static func mirror(_ list: [Contact]) async -> Outcome {
        guard AppState.shared.serverCapabilities.vault else { return .skipped }
        guard let ik = KeychainStore.data(KeychainStore.Keys.identityPriv) else { return .skipped }
        if inFlight { return .skipped }
        inFlight = true
        defer { inFlight = false }
        let slot = Vault.slotId(identityPriv: ik, name: Vault.contacts)
        let now = Int(Date().timeIntervalSince1970 * 1000)
        var floor = lastSeenVersion
        let onIsland = list.filter { $0.host == nil }
        do {
            for _ in 0..<5 {
                let cur = try await VaultAPI.get(slot)
                if cur.version < floor {
                    // The island served an older version than this install has
                    // seen. In the mirror phase the server list is the truth
                    // anyway; stop trusting the floor and rewrite from the list.
                    lastSeenVersion = 0
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
                    lastSeenVersion = cur.version
                    return .unchanged
                }
                let sealed = try Vault.seal(identityPriv: ik, slot: slot, version: cur.version + 1, plaintext: try JSONEncoder().encode(next))
                let w = try await VaultAPI.put(slot, blob: sealed.base64EncodedString(), basedOn: cur.version)
                if let v = w.version {
                    lastSeenVersion = v
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

/// The four vault calls (spec §4.9). 404 and 409 are answers the caller acts
/// on, not failures, so they come back as values with the version.
enum VaultAPI {
    struct SlotRead { let blob: String?; let version: Int }
    struct Write { let version: Int?; let current: Int }
    struct SlotRef: Decodable { let slot: String; let version: Int }

    private struct Detail: Decodable { let detail: Body?; struct Body: Decodable { let code: String?; let version: Int? } }
    private struct GetBody: Decodable { let blob: String; let version: Int }
    private struct VersionBody: Decodable { let version: Int }
    private struct ListBody: Decodable { let slots: [SlotRef] }
    private struct PutBody: Encodable { let blob: String; let version: Int }

    static func list() async throws -> [SlotRef] {
        let r: ListBody = try await APIClient.shared.request("GET", "/vault")
        return r.slots
    }

    static func get(_ slot: String) async throws -> SlotRead {
        do {
            let data = try await APIClient.shared.rawRequest("GET", "/vault/\(slot)")
            let b = try JSONDecoder().decode(GetBody.self, from: data)
            return SlotRead(blob: b.blob, version: b.version)
        } catch APIError.http(404, let body) {
            return SlotRead(blob: nil, version: detailVersion(body) ?? 0)
        }
    }

    /// `basedOn` is the version this write is based on (0 only for a slot
    /// that never existed).
    static func put(_ slot: String, blob: String, basedOn: Int) async throws -> Write {
        do {
            let data = try await APIClient.shared.rawRequest("PUT", "/vault/\(slot)", body: PutBody(blob: blob, version: basedOn))
            let v = try JSONDecoder().decode(VersionBody.self, from: data).version
            return Write(version: v, current: v)
        } catch APIError.http(409, let body) {
            return Write(version: nil, current: detailVersion(body) ?? 0)
        }
    }

    /// A delete names the version it is based on, like a write. True when it
    /// landed (or there was nothing to delete), false when stale.
    static func delete(_ slot: String, basedOn: Int) async throws -> Bool {
        do {
            _ = try await APIClient.shared.rawRequest("DELETE", "/vault/\(slot)", query: ["version": String(basedOn)])
            return true
        } catch APIError.http(409, _) {
            return false
        }
    }

    private static func detailVersion(_ body: String?) -> Int? {
        guard let body, let data = body.data(using: .utf8) else { return nil }
        return (try? JSONDecoder().decode(Detail.self, from: data))?.detail?.version
    }
}

import Foundation
import os.log

/// The vault's transport half: the four calls of spec §4.9, the rollback floor
/// they are read against, and the two paths that keep a slot fresh.
///
/// It lived inside `ContactsVault.swift` as `VaultAPI` while `contacts` was the
/// only slot. Sections are the second one (founder item 1 of 23.08,
/// `docs/sections-design-2026-08-23.md`), and two copies of a read-merge-write
/// transport diverge, so this is the one copy both slots use. Web
/// `src/lib/vault.ts` + `src/lib/vault-sync.ts`, Android `crypto/Vault.kt` +
/// `net/RcqSocket.kt`.
enum VaultClient {
    struct SlotRead { let blob: String?; let version: Int }
    struct Write { let version: Int?; let current: Int }
    struct SlotRef: Decodable { let slot: String; let version: Int }

    private struct Detail: Decodable { let detail: Body?; struct Body: Decodable { let code: String?; let version: Int? } }
    private struct GetBody: Decodable { let blob: String; let version: Int }
    private struct VersionBody: Decodable { let version: Int }
    private struct ListBody: Decodable { let slots: [SlotRef] }
    private struct PutBody: Encodable { let blob: String; let version: Int }

    /// Slot names and versions, no blobs. This is what the reconnect sweep asks
    /// for: one request says which slots moved while the socket was down.
    static func list() async throws -> [SlotRef] {
        let r: ListBody = try await APIClient.shared.request("GET", "/vault")
        return r.slots
    }

    /// 404 and 409 are answers the caller acts on, not failures, so they come
    /// back as values carrying the version.
    static func get(_ slot: String) async throws -> SlotRead {
        do {
            let data = try await APIClient.shared.rawRequest("GET", "/vault/\(slot)")
            let b = try JSONDecoder().decode(GetBody.self, from: data)
            return SlotRead(blob: b.blob, version: b.version)
        } catch APIError.http(404, let body) {
            return SlotRead(blob: nil, version: detailVersion(body) ?? 0)
        }
    }

    /// `basedOn` is the version this write is based on (0 only for a slot that
    /// never existed).
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

/// The highest version this install has seen for a slot: the floor below which
/// an island's answer is a rollback rather than data.
///
/// ⚠⚠ KEYED BY SLOT NAME, never by account. A slot name is
/// `HKDF(identity_priv, ...)`, so `POST /auth/reissue` does not move the
/// account's slots to a new version, it moves them to NEW NAMES, and the island
/// empties the vault in the same transaction. A floor filed under the account
/// alone then outlives the derivation it belonged to: the rotating device
/// republishes under the fresh names, the island answers them at version 1,
/// `1 < 12` reads as a rollback, and because the floor is persisted every later
/// session repeats it. The account's vault is then dead on that device for
/// good. Keyed by name, a new derivation starts at 0, which is what it is.
enum VaultFloor {
    private static let prefix = "rcq.vault.floor.v1."

    static func lastSeen(_ slot: String) -> Int {
        UserDefaults.standard.integer(forKey: prefix + slot)
    }

    static func remember(_ slot: String, _ version: Int) {
        guard version > 0 else { return }
        UserDefaults.standard.set(version, forKey: prefix + slot)
    }

    /// Forget the floor for a slot whose NAME is retired (`vault_reset`).
    /// Nothing else clears it: a floor that goes down on its own is a floor
    /// that lets an island serve an old blob back as if it were current.
    static func forget(_ slot: String) {
        UserDefaults.standard.removeObject(forKey: prefix + slot)
    }
}

/// Keeping the vault slots fresh: the island's nudge, and the sweep on
/// reconnect.
///
/// The island fans out `vault_changed {slot, version}` to every session of the
/// account whenever a slot moves (SPEC §4.9). Until 23.08 NO client listened
/// for it and none re-read a slot on reconnect, so a contact list sealed by the
/// desktop reached this phone on its next cold start and not before. Sections
/// make that visible immediately: a section made on the desktop has to appear
/// here, and the other way round.
///
/// Two paths, because one of them is not enough:
///
///   * the nudge, for the device that is connected right now. Cheap and
///     immediate.
///   * the sweep on every socket (re)connect, because the nudge is pub/sub with
///     NO REPLAY: a device whose socket was down when the other one wrote never
///     hears it, and a reconnect is exactly the moment that gap closes. One
///     `GET /vault` (slots and versions, no blobs) tells us what moved, and
///     only the slots that moved are actually fetched.
///
/// ⚠ Slot names are hashes. `slot` on the wire is 32 hex characters that mean
/// nothing without the account's identity key, so a frame is matched by
/// deriving both names locally rather than by comparing strings to "contacts".
@MainActor
enum VaultSync {
    private static let log = OSLog(subsystem: "app.rcq.client", category: "VaultSync")

    /// A socket that keeps dying redials on a curve that starts at one second,
    /// and each redial that succeeds would otherwise be a sweep. One every
    /// fifteen seconds is plenty for a change another device just made.
    private static let sweepFloor: TimeInterval = 15
    private static var lastSweep: Date = .distantPast

    /// Both slot names for the account this process is signed in as, or nil
    /// when there is no identity to derive them from (and in a decoy session,
    /// which has no island account and must touch no vault at all).
    private static func slots() -> (contacts: String, sections: String)? {
        guard !PanicPINService.shared.isDecoy else { return nil }
        guard let ik = KeychainStore.data(KeychainStore.Keys.identityPriv) else { return nil }
        return (
            Vault.slotId(identityPriv: ik, name: Vault.contacts),
            Vault.slotId(identityPriv: ik, name: Vault.sections)
        )
    }

    /// `vault_changed` from the socket. The writer hears its own nudge too and
    /// drops it by version: the floor is already at or above what the frame
    /// names.
    static func handleVaultChanged(slot: String, version: Int) async {
        guard let names = slots() else { return }
        if slot == names.sections {
            if version > 0 && version <= VaultFloor.lastSeen(slot) { return }
            _ = await SectionsVault.sync()
            return
        }
        if slot == names.contacts {
            if version > 0 && version <= VaultFloor.lastSeen(slot) { return }
            await ContactsVault.refreshFromVault()
        }
    }

    /// `vault_reset` from the socket: `POST /auth/reissue` on another device
    /// rotated the account's identity, and the island emptied the vault in the
    /// same transaction (SPEC §4.9, `backend/app/routers/auth.py`).
    ///
    /// ⚠ NOT a wipe, and not a republish either. The slot NAMES and the seal
    /// key are derived from `identity_priv`, and this device is holding the
    /// retired one: it cannot write anything the new derivation will ever read,
    /// and what it CAN still write is the whole contact list, sealed with the
    /// key the user has just declared compromised, under the old name. So both
    /// slots stop for this session and the local caches are left exactly as
    /// they are (until a device with the new identity publishes, the sections
    /// tree exists nowhere else).
    ///
    /// The stored floors go, because they belong to names that will never be
    /// read again and a stale floor is what locks a fresh derivation out of its
    /// own slot for good.
    static func handleVaultReset() {
        if let names = slots() {
            VaultFloor.forget(names.contacts)
            VaultFloor.forget(names.sections)
        }
        SectionsVault.retire()
        ContactsVault.retire()
        os_log("the account rotated its identity elsewhere; this derivation is retired", log: log, type: .info)
    }

    /// Boot and every reconnect. `force` skips the floor (the boot call).
    static func sweep(force: Bool = false) async {
        guard let names = slots() else { return }
        guard AppState.shared.serverCapabilities.vault else { return }
        let now = Date()
        if !force && now.timeIntervalSince(lastSweep) < sweepFloor { return }
        lastSweep = now
        let listed: [VaultClient.SlotRef]
        do {
            listed = try await VaultClient.list()
        } catch {
            // No vault on this island, or it is unreachable. Either way there
            // is nothing to compare against and nothing to do.
            return
        }
        var versions: [String: Int] = [:]
        for ref in listed { versions[ref.slot] = ref.version }
        // ⚠ The version is not the only reason to sync. A device that owes the
        // island a write (offline when the section was made, a 429 against the
        // 240-an-hour budget, a 5xx) has to be let in even though the island's
        // copy has not moved: `SectionsVault.sync` merges both ways and sends
        // what is outstanding. Without this the sweep looks at an unchanged
        // version, decides there is nothing to do, and the section stays on one
        // device forever.
        // ⚠ Three reasons to read, not one.
        //
        //  * the island's version moved: another device wrote;
        //  * this device owes the island a write (offline when the section was
        //    made, a 429 against the 240-an-hour budget, a 5xx). Without this
        //    the sweep looks at an unchanged version, decides there is nothing
        //    to do, and the section stays on one device forever;
        //  * this device has never read the slot at all. The floor sits at 0
        //    only on a fresh install or a fresh derivation, and that first read
        //    is what runs the Archive migration write (§3): the gate this
        //    client has always applied locally becomes an explicit `p:1` the
        //    other clients can see.
        if (versions[names.sections] ?? 0) > VaultFloor.lastSeen(names.sections)
            || VaultFloor.lastSeen(names.sections) == 0
            || SectionsStore.shared.pushPending {
            _ = await SectionsVault.sync()
        }
        if (versions[names.contacts] ?? 0) > VaultFloor.lastSeen(names.contacts) {
            await ContactsVault.refreshFromVault()
        }
    }
}

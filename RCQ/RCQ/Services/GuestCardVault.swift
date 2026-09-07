import Foundation
import os.log

/// The cards other people gave us, in the vault.
///
/// ⚠⚠ WITHOUT THIS THE WHOLE FEATURE HAS A TRAPDOOR, and the trapdoor is
/// silent. A guest card is the only way to reach somebody on a closed island,
/// the cards live in UserDefaults, and a closed island answers a caller with
/// no card by saying "no such number" — which is the refusal working exactly
/// as designed. So a person reinstalls, restores from their recovery phrase,
/// sees every contact intact, and simply cannot write to any of them, with
/// nothing on screen to explain it.
///
/// ⚠ ONLY THEIRS, never ours. A card we minted is a credential we HAND OUT: if
/// it is lost we mint another and share it again, and the island revokes the
/// old one from its own list. A card somebody gave US is irreplaceable without
/// asking them for it, which on a closed island is exactly the conversation we
/// cannot have.
///
/// Mirrors `web-chat/src/lib/guestcard-vault.ts` and Android's
/// `GuestCardVault`, including sorted keys so two devices that agree on the
/// cards agree on the bytes rather than rewriting the slot at each other.
@MainActor
enum GuestCardVault {
    private static let log = OSLog(subsystem: "app.rcq.client", category: "GuestCardVault")

    /// A card is ~43 characters and a handle is short, so this is far under the
    /// island's 256 KiB blob cap. The bound exists so a corrupted or hostile
    /// slot cannot make the client build an enormous map.
    private static let maxCards = 2000

    private static var rolledBack = false

    static func slotName(_ ik: Data) -> String { Vault.slotId(identityPriv: ik, name: Vault.guestcards) }

    static func retire() { rolledBack = true }

    /// Union, local first, sorted. Pure; the properties it has to keep are the
    /// same three the other two clients pin: never lose a card, let the device
    /// holding the newer one win, and produce stable bytes.
    ///
    /// ⚠ Removals are deliberately NOT synced. A card a stale device dropped
    /// must not vanish from a device still using it. The cost is a card kept
    /// slightly too long, which nobody can see; the alternative is a contact
    /// who goes quietly unreachable.
    static func merge(_ local: [String: String], _ remote: [String: String]) -> [String: String] {
        var out = remote
        for (k, v) in local { out[k] = v }
        guard out.count > maxCards else { return out }
        var trimmed: [String: String] = [:]
        for k in out.keys.sorted().prefix(maxCards) { trimmed[k] = out[k] }
        return trimmed
    }

    private static func encode(_ m: [String: String]) -> Data? {
        // Sorted keys, so two devices that agree on the cards agree on the
        // bytes and do not take turns rewriting the slot.
        try? JSONSerialization.data(
            withJSONObject: ["v": 1, "c": m] as [String: Any],
            options: [.sortedKeys],
        )
    }

    /// nil = a newer format this build must not overwrite.
    private static func decode(_ data: Data?) -> [String: String]? {
        guard let data else { return [:] }
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        if let v = o["v"] as? Int, v > 1 { return nil }
        guard let c = o["c"] as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in c {
            guard let s = v as? String, !s.isEmpty, s.count <= 128, out.count < maxCards else { continue }
            out[k] = s
        }
        return out
    }

    /// Boot, the nudge, and every reconnect. Never throws.
    ///
    /// ⚠ Only where cards mean anything. An open island never mints one, so
    /// there is nothing to carry and no reason to spend a request.
    @discardableResult
    static func sync() async -> Int {
        guard !rolledBack, !PanicPINService.shared.isDecoy else { return 0 }
        guard AppState.shared.serverCapabilities.vault,
              AppState.shared.serverCapabilities.closedIsland else { return 0 }
        guard let ik = KeychainStore.data(KeychainStore.Keys.identityPriv) else { return 0 }
        let slot = slotName(ik)
        do {
            let cur = try await VaultClient.get(slot)
            let floor = VaultFloor.lastSeen(slot)
            if cur.version < floor {
                rolledBack = true
                os_log("island served %d below the floor %d; sync stopped", log: log, type: .error, cur.version, floor)
                return 0
            }
            guard let remote = open(cur, slot: slot, ik: ik) else { return 0 }
            let merged = merge(GuestCardStore.shared.allTheirCards, remote)
            GuestCardStore.shared.replaceTheirCards(merged)
            VaultFloor.remember(slot, cur.version)
            // The same retry the other slots use: if folding our copy into the
            // island's changes the island's, the island is missing something of
            // ours — and a device that received a card five minutes ago is the
            // only thing in the world that has it.
            if merged != remote { await push(slot: slot, ik: ik) }
            return merged.count
        } catch {
            return 0
        }
    }

    private static func open(_ cur: VaultClient.SlotRead, slot: String, ik: Data) -> [String: String]? {
        guard let blob = cur.blob else { return [:] }
        guard let raw = Data(base64Encoded: blob),
              let plain = try? Vault.open(identityPriv: ik, slot: slot, version: cur.version, blob: raw)
        else { return nil }
        return decode(plain)
    }

    private static func push(slot: String, ik: Data) async {
        var floor = VaultFloor.lastSeen(slot)
        for _ in 0..<5 {
            do {
                let cur = try await VaultClient.get(slot)
                if cur.version < floor { rolledBack = true; return }
                guard let remote = open(cur, slot: slot, ik: ik) else { return }
                guard !PanicPINService.shared.isDecoy else { return }
                let next = merge(GuestCardStore.shared.allTheirCards, remote)
                if next == remote { return }
                guard let plain = encode(next),
                      let sealed = try? Vault.seal(identityPriv: ik, slot: slot, version: cur.version + 1, plaintext: plain)
                else { return }
                let w = try await VaultClient.put(slot, blob: sealed.base64EncodedString(), basedOn: cur.version)
                if let v = w.version {
                    VaultFloor.remember(slot, v)
                    GuestCardStore.shared.replaceTheirCards(next)
                    return
                }
                floor = max(floor, w.current)
            } catch {
                return
            }
        }
    }
}

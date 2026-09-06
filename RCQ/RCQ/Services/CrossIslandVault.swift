import Foundation
import os.log

/// Cross-island contacts in the vault. The iOS half of web-chat's
/// `src/lib/crossisland-vault.ts` and Android's `data/CrossIslandVault.kt`;
/// same slot, same merge, same bytes.
///
/// `CrossIslandStore` is the ONLY record that a peer on another island exists:
/// there is no server-side row for them, because /contacts holds users of this
/// island and a peer on another one is not. That store is UserDefaults in the
/// App Group. So reinstall, or simply pick up the second device, and every
/// cross-island contact was gone along with the peer's pinned keys, with no
/// way back but asking them for their number again. Same-island contacts have
/// survived that since stage 4.
///
/// Deliberately NOT what `ContactsVault` does. That slot mirrors a list the
/// island can always be asked for again, so its merge is server-wins. This one
/// is the only copy in existence, so the merge is a two-way union and a failed
/// write is retried by the next read.
///
/// ⚠⚠ The pinned keys are the point, and the one thing a merge must not get
/// wrong. `identityKey` / `signingKey` / `signalIdentityKey` come from the
/// peer's island key card at the moment they were added, and everything ever
/// verified about that peer is checked against them. So the merge is
/// TRUST-ON-FIRST-USE across devices: when both sides hold the same handle the
/// keys come from the row with the EARLIER addedAt, never the newer one. A
/// second device cannot re-pin a peer to a different key card by adding them
/// again, which is exactly what an island handing out a swapped card needs it
/// to do. Display fields go the other way: newest profileTs wins.
///
/// ⚠⚠ The wire shape is a CONTRACT between three clients with three
/// serialisers. Required fields always, optionals only when they hold a value,
/// `profileTs` always a number, keys sorted, the envelope `{"v","c","g"}` in
/// that order. Anything else and this client and the web read each other's
/// writes as a disagreement, rewrite, and burn the account's 240-puts-an-hour
/// budget rewriting the same contacts at each other forever.
enum CrossIslandVault {
    private static let log = OSLog(subsystem: "app.rcq.client", category: "CrossIslandVault")

    typealias State = (rows: [String: [String: Any]], graves: [String: Double])

    private static let tombstoneTTL: Double = 90 * 24 * 3600 * 1000

    /// The island's cap is 256 KiB decoded and a write over it is a permanent
    /// 413: a sync that never works again and says nothing. A row is ~250
    /// bytes. Whoever gets here keeps every row on the device and loses the
    /// backup, which is the mild half of the failure.
    private static let maxRows = 600

    private static var rolledBack = false
    private static var pushing = false
    private static var pushAgain = false

    static func slotName(_ ik: Data) -> String { Vault.slotId(identityPriv: ik, name: Vault.crossisland) }

    static func retire() { rolledBack = true }

    // MARK: - the merge, pure and shared with the other two clients

    private static func str(_ r: [String: Any], _ k: String) -> String? {
        guard let v = r[k] as? String, !v.isEmpty else { return nil }
        return v
    }

    private static func num(_ r: [String: Any], _ k: String) -> Double {
        if let d = r[k] as? Double { return d }
        if let i = r[k] as? Int { return Double(i) }
        if let n = r[k] as? NSNumber { return n.doubleValue }
        return 0
    }

    private static func valid(_ r: [String: Any]?) -> Bool {
        guard let r else { return false }
        return r["uin"] != nil && str(r, "host") != nil && str(r, "identityKey") != nil && str(r, "signingKey") != nil
    }

    private static func ciKey(_ r: [String: Any]) -> String {
        "\(Int(num(r, "uin")))@\((str(r, "host") ?? "").lowercased())"
    }

    /// `profileTs` is epoch SECONDS on the wire; `addedAt` is ms.
    private static func updatedAt(_ r: [String: Any]) -> Double {
        max(num(r, "addedAt"), num(r, "profileTs") * 1000)
    }

    /// Keys from the earlier row, display from the newer one.
    private static func combine(_ a: [String: Any], _ b: [String: Any]) -> [String: Any] {
        let base = num(a, "addedAt") <= num(b, "addedAt") ? a : b
        let fresh = updatedAt(a) >= updatedAt(b) ? a : b
        var o: [String: Any] = [
            "uin": Int(num(base, "uin")),
            "host": str(base, "host") ?? "",
            "nickname": str(fresh, "nickname") ?? str(base, "nickname") ?? "",
            "identityKey": str(base, "identityKey") ?? "",
            "signingKey": str(base, "signingKey") ?? "",
            "addedAt": num(base, "addedAt"),
            "profileTs": max(num(a, "profileTs"), num(b, "profileTs")),
        ]
        if let s = str(base, "signalIdentityKey") { o["signalIdentityKey"] = s }
        if let g = str(fresh, "gender") ?? str(base, "gender") { o["gender"] = g }
        if let sm = str(fresh, "statusMessage") ?? str(base, "statusMessage") { o["statusMessage"] = sm }
        if let id = str(fresh, "avatarMediaId"), let k = str(fresh, "avatarMediaKey") {
            o["avatarMediaId"] = id
            o["avatarMediaKey"] = k
        }
        return o
    }

    /// Every row leaving the merge goes through here, including the ones only
    /// one device has. ⚠ Not only the combined ones: the avatar id and its key
    /// are a pair, and a row written before that rule can carry half of one.
    /// Half a pair names a blob nobody can open, so the picture stays broken.
    private static func canonRow(_ r: [String: Any]) -> [String: Any] {
        var o: [String: Any] = [
            "uin": Int(num(r, "uin")),
            "host": str(r, "host") ?? "",
            "nickname": str(r, "nickname") ?? "",
            "identityKey": str(r, "identityKey") ?? "",
            "signingKey": str(r, "signingKey") ?? "",
            "addedAt": num(r, "addedAt"),
            "profileTs": num(r, "profileTs"),
        ]
        if let s = str(r, "signalIdentityKey") { o["signalIdentityKey"] = s }
        if let g = str(r, "gender") { o["gender"] = g }
        if let sm = str(r, "statusMessage") { o["statusMessage"] = sm }
        if let id = str(r, "avatarMediaId"), let k = str(r, "avatarMediaKey") {
            o["avatarMediaId"] = id
            o["avatarMediaKey"] = k
        }
        return o
    }

    /// A tombstone kills a row only while it is NEWER than that row was added:
    /// remove a peer on the phone, add them again on the desktop, and the fresh
    /// row wins, or re-adding somebody you once removed would be impossible
    /// from a second device.
    static func merge(_ local: State, _ remote: State, now: Double) -> State {
        var graves: [String: Double] = [:]
        for k in Set(local.graves.keys).union(remote.graves.keys) {
            let t = max(local.graves[k] ?? 0, remote.graves[k] ?? 0)
            if t > 0 && now - t < tombstoneTTL { graves[k] = t }
        }
        var rows: [String: [String: Any]] = [:]
        for k in Set(local.rows.keys).union(remote.rows.keys) {
            let a = local.rows[k]
            let b = remote.rows[k]
            let picked: [String: Any]?
            if valid(a), valid(b) { picked = combine(a!, b!) } else if valid(a) { picked = a } else if valid(b) { picked = b } else { picked = nil }
            guard let row = picked else { continue }
            let buried = graves[k] ?? 0
            if buried > num(row, "addedAt") { continue }
            if buried > 0 { graves.removeValue(forKey: k) }
            rows[ciKey(row)] = canonRow(row)
        }
        return (rows, graves)
    }

    // MARK: - the wire form

    /// Hand-assembled rather than one JSONSerialization call, because the
    /// envelope's own keys are `v`, `c`, `g` in THAT order (what the web and
    /// Android write) while `.sortedKeys` would put them in alphabetical
    /// order. The rows inside do use `.sortedKeys`, which is exactly what the
    /// other two clients produce for them.
    static func encode(_ s: State) -> Data? {
        var parts: [String] = []
        for k in s.rows.keys.sorted() {
            guard let row = s.rows[k],
                  let data = try? JSONSerialization.data(withJSONObject: normalizeNumbers(row), options: [.sortedKeys, .withoutEscapingSlashes]),
                  let text = String(data: data, encoding: .utf8),
                  let key = jsonString(k)
            else { return nil }
            parts.append("\(key):\(text)")
        }
        var graveParts: [String] = []
        for k in s.graves.keys.sorted() {
            guard let key = jsonString(k) else { return nil }
            graveParts.append("\(key):\(intString(s.graves[k] ?? 0))")
        }
        let json = "{\"v\":1,\"c\":{\(parts.joined(separator: ","))},\"g\":{\(graveParts.joined(separator: ","))}}"
        return json.data(using: .utf8)
    }

    /// ⚠ `addedAt` and `profileTs` are whole numbers on the wire. Held as
    /// Double here (UserDefaults has no Int64 for a ms timestamp), and
    /// JSONSerialization would write `1756913600000.0` for one, which every
    /// other client reads as a different value from its own `1756913600000`
    /// and rewrites.
    private static func normalizeNumbers(_ r: [String: Any]) -> [String: Any] {
        var o = r
        for k in ["addedAt", "profileTs", "uin"] where o[k] != nil {
            o[k] = NSNumber(value: Int64(num(r, k)))
        }
        return o
    }

    private static func intString(_ d: Double) -> String { String(Int64(d)) }

    private static func jsonString(_ s: String) -> String? {
        guard let d = try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes]),
              var t = String(data: d, encoding: .utf8) else { return nil }
        t.removeFirst(); t.removeLast()
        return t
    }

    static func decode(_ data: Data) -> State? {
        guard let any = try? JSONSerialization.jsonObject(with: data),
              let o = any as? [String: Any] else { return nil }
        // A newer format: leave it alone rather than overwrite what wrote it.
        if let v = o["v"] as? Int, v > 1 { return nil }
        let c = (o["c"] as? [String: Any]) ?? [:]
        var rows: [String: [String: Any]] = [:]
        for (k, v) in c { if let r = v as? [String: Any] { rows[k] = r } }
        var graves: [String: Double] = [:]
        for (k, v) in (o["g"] as? [String: Any]) ?? [:] {
            if let n = v as? NSNumber { graves[k] = n.doubleValue }
        }
        return (rows, graves)
    }

    static func sameContent(_ a: State, _ b: State) -> Bool { encode(a) == encode(b) }

    // MARK: - this device's side

    @MainActor
    private static func localState() -> State {
        var rows: [String: [String: Any]] = [:]
        let store = CrossIslandStore.shared
        for c in store.all() {
            guard let host = c.host else { continue }
            var o: [String: Any] = [
                "uin": c.uin,
                "host": host,
                "nickname": c.nickname,
                "identityKey": c.identityKey,
                "signingKey": c.signingKey,
                "addedAt": store.addedAtFor(c.uin, host),
                "profileTs": Double(store.profileTSFor(c.uin, host)),
            ]
            if let s = c.signalIdentityKey, !s.isEmpty { o["signalIdentityKey"] = s }
            if let g = c.gender, !g.isEmpty { o["gender"] = g }
            if let sm = c.statusMessage, !sm.isEmpty { o["statusMessage"] = sm }
            if let id = c.avatarMediaID, let k = c.avatarMediaKey, !id.isEmpty, !k.isEmpty {
                o["avatarMediaId"] = id
                o["avatarMediaKey"] = k
            }
            rows["\(c.uin)@\(host.lowercased())"] = o
        }
        return (rows, store.tombstones())
    }

    @MainActor
    private static func applyLocally(_ s: State) {
        var out: [(contact: Contact, addedAt: Double, profileTS: Int)] = []
        for (_, r) in s.rows {
            guard let host = str(r, "host"),
                  let ik = str(r, "identityKey"),
                  let sk = str(r, "signingKey") else { continue }
            var c = Contact(
                uin: Int(num(r, "uin")),
                nickname: str(r, "nickname") ?? "",
                status: .offline,
                statusMessage: str(r, "statusMessage"),
                blocked: false,
                identityKey: ik,
                signingKey: sk,
                signalIdentityKey: str(r, "signalIdentityKey"),
                gender: str(r, "gender")
            )
            c.host = host
            c.avatarMediaID = str(r, "avatarMediaId")
            c.avatarMediaKey = str(r, "avatarMediaKey")
            out.append((c, num(r, "addedAt"), Int(num(r, "profileTs"))))
        }
        CrossIslandStore.shared.replaceAll(out, graves: s.graves)
    }

    // MARK: - read path: boot, the nudge, every reconnect

    /// Never throws. Returns the number of cross-island contacts now held.
    @discardableResult
    @MainActor
    static func sync() async -> Int {
        guard !rolledBack, !PanicPINService.shared.isDecoy else { return 0 }
        guard AppState.shared.serverCapabilities.vault else { return 0 }
        guard let ik = KeychainStore.data(KeychainStore.Keys.identityPriv) else { return 0 }
        let slot = slotName(ik)
        let now = Date().timeIntervalSince1970 * 1000
        do {
            let cur = try await VaultClient.get(slot)
            let floor = VaultFloor.lastSeen(slot)
            if cur.version < floor {
                rolledBack = true
                os_log("island served %d below the floor %d; sync stopped for this session", log: log, type: .error, cur.version, floor)
                return 0
            }
            guard let remote = open(cur, slot: slot, ik: ik) else { return 0 }
            let next = merge(localState(), remote, now: now)
            applyLocally(next)
            VaultFloor.remember(slot, cur.version)
            // ⚠ AND THIS IS THE RETRY. A write that failed (offline, a 429, a
            // 5xx) leaves rows nothing else in the world holds, and the read
            // path is the one thing that runs on boot, on the nudge and on
            // every reconnect.
            if !sameContent(next, remote) { Task { await push() } }
            return next.rows.count
        } catch {
            return 0
        }
    }

    private static func open(_ cur: VaultClient.SlotRead, slot: String, ik: Data) -> State? {
        guard let blob = cur.blob else { return ([:], [:]) }
        guard let raw = Data(base64Encoded: blob),
              let plain = try? Vault.open(identityPriv: ik, slot: slot, version: cur.version, blob: raw)
        else {
            os_log("slot unreadable; leaving it alone", log: log, type: .info)
            return nil
        }
        return decode(plain)
    }

    // MARK: - write path

    @MainActor
    static func push() async {
        guard !rolledBack, !PanicPINService.shared.isDecoy else { return }
        // One write in flight at a time. Two overlapping read-merge-write loops
        // on one slot are legal (the island's 409 sorts them out) but they burn
        // the hourly budget for nothing.
        if pushing { pushAgain = true; return }
        pushing = true
        defer {
            pushing = false
            if pushAgain { pushAgain = false; Task { await push() } }
        }
        guard AppState.shared.serverCapabilities.vault else { return }
        guard let ik = KeychainStore.data(KeychainStore.Keys.identityPriv) else { return }
        let slot = slotName(ik)
        let now = Date().timeIntervalSince1970 * 1000
        var floor = VaultFloor.lastSeen(slot)
        for _ in 0..<5 {
            do {
                let cur = try await VaultClient.get(slot)
                if cur.version < floor {
                    rolledBack = true
                    return
                }
                guard let remote = open(cur, slot: slot, ik: ik) else { return }
                // ⚠⚠ What is about to be SEALED into this account's slot comes
                // from THIS account's store or from nowhere. The duress PIN can
                // rebind the store while the GET is in the air, and publishing
                // the decoy's contacts into the real account's slot would
                // syndicate them to every device.
                guard !PanicPINService.shared.isDecoy else { return }
                let next = merge(localState(), remote, now: now)
                if sameContent(next, remote) { return }
                if next.rows.count > maxRows {
                    os_log("%d rows is over the slot budget; not backing up", log: log, type: .error, next.rows.count)
                    return
                }
                guard let plain = encode(next),
                      let sealed = try? Vault.seal(identityPriv: ik, slot: slot, version: cur.version + 1, plaintext: plain)
                else { return }
                let w = try await VaultClient.put(slot, blob: sealed.base64EncodedString(), basedOn: cur.version)
                if let v = w.version {
                    VaultFloor.remember(slot, v)
                    applyLocally(next)
                    return
                }
                // Stale: somebody else's write landed between our read and ours.
                floor = max(floor, w.current)
            } catch {
                return
            }
        }
    }

    /// A local add or remove just happened. Debounced, because accepting a
    /// cross-island request writes the row and then the profile that came with
    /// it.
    @MainActor private static var pushTask: Task<Void, Never>?

    @MainActor
    static func schedulePush() {
        pushTask?.cancel()
        pushTask = Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            await push()
        }
    }

    /// Point the store's change hook at the slot. Called from the vault sweep,
    /// which is the one thing that runs at launch and on every reconnect.
    @MainActor
    static func arm() {
        guard CrossIslandStore.shared.onChange == nil else { return }
        CrossIslandStore.shared.onChange = { Task { @MainActor in schedulePush() } }
    }
}

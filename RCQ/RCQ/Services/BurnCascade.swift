import Foundation
import CryptoKit
import UIKit

/// What an erase AFTER the wipe needs, copied out BEFORE the wipe.
///
/// ⚠⚠ Memory only. Never encoded, never written to the Keychain, defaults or
/// a file: the wipe PIN promises that nothing of the account survives on the
/// device, and a snapshot on disk would be exactly such a thing. The key bytes
/// are zeroed when the erase ends, and again on deinit for any path that drops
/// the snapshot without running it.
///
/// Zeroing is best effort. `Data` is copy-on-write, so a copy handed to
/// CryptoKit lives in CryptoKit's own buffer (which it clears on release); the
/// point is that no long-lived reference keeps the bytes readable.
///
/// Holds the home island and, since C1 (spec F2), the copies on the islands
/// this device visited and the backup homes: hosts and their stored tokens.
/// ⏭ A pending rotation (F3, release C2) adds its second key here.
final class BurnSnapshot: @unchecked Sendable {
    /// The route the app was using to reach the home island at the moment of
    /// the wipe, kept as it was: the fresh boot may repoint `APIClient`.
    let homeBase: URL
    let uin: Int
    /// `X-RCQ-Auth` of a private island; nil for public ones.
    let serverToken: String?

    private let lock = NSLock()
    private var token: String?
    private var signingPriv: Data?
    private var copies: [BurnCascade.CopyHost]

    private init(
        homeBase: URL, uin: Int, serverToken: String?, token: String?, signingPriv: Data?,
        copies: [BurnCascade.CopyHost]
    ) {
        self.homeBase = homeBase
        self.uin = uin
        self.serverToken = serverToken
        self.token = token
        self.signingPriv = signingPriv
        self.copies = copies
    }

    /// Read the active account's credentials. No network: every read here is
    /// the Keychain, the App Group stores or an in-process value. Nil when
    /// there is nothing that could authenticate an erase.
    ///
    /// Same slot rule as `AuthService.deleteServerAccount`: this runs from the
    /// lock screen of a COLD START too, before boot ever handed `APIClient` a
    /// token, and only the legacy/first account may read the unprefixed slot.
    @MainActor
    static func capture() async -> BurnSnapshot? {
        // The decoy never reaches the real account's islands. The wipe PIN is
        // typed on the lock screen, not inside a decoy session, so this is the
        // backstop and not the path.
        if PanicPINService.shared.isDecoy { return nil }
        guard let uin = AuthService.shared.ownUIN else { return nil }
        var token = await APIClient.shared.currentToken()
        if token == nil {
            let am = AccountManager.shared
            let legacyOwner = am.accounts.count <= 1 || am.activeAccountID == am.accounts.first?.id
            token = legacyOwner
                ? KeychainStore.string(KeychainStore.Keys.token)
                : am.activeAccountID.flatMap { KeychainStore.string(KeychainStore.Keys.token, forAccount: $0) }
        }
        let signing = KeychainStore.data(KeychainStore.Keys.signingPriv)
        guard token != nil || signing != nil else { return nil }
        var serverToken = await APIClient.shared.currentServerToken()
        if serverToken == nil { serverToken = AccountManager.shared.active?.serverToken }
        return BurnSnapshot(
            homeBase: APIClient.shared.baseURL,
            uin: uin,
            serverToken: serverToken,
            token: token,
            signingPriv: signing,
            copies: BurnCascade.remoteCopies(ownUin: uin)
        )
    }

    fileprivate func credentials() -> (token: String?, signingPriv: Data?, copies: [BurnCascade.CopyHost]) {
        lock.lock(); defer { lock.unlock() }
        return (token, signingPriv, copies)
    }

    func zero() {
        lock.lock(); defer { lock.unlock() }
        if var bytes = signingPriv {
            signingPriv = nil
            bytes.resetBytes(in: 0..<bytes.count)
        }
        token = nil
        copies = []
    }

    deinit { zero() }
}

enum BurnCascade {

    /// One island this account has a copy on, as this device's stores name
    /// it, with every token they hold for it. No key: the key is read when
    /// the burn runs, not carried around with the list the screen shows.
    struct CopyHost: Sendable, Equatable {
        let host: String
        var tokens: [String]
    }

    // MARK: the burning gate

    private static let gateLock = NSLock()
    private static var burning = false

    /// True from the moment a burn from Settings starts deleting copies until
    /// it has wiped the device or given up.
    ///
    /// ⚠ While it is up, nothing may write fresh credentials for this account
    /// or open a new copy: the backup and visited drains, the pending-request
    /// poll, the guest refresh, a group join and the nickname push all stand
    /// down. A drain that recovers a copy between its delete and the local
    /// wipe would otherwise leave a token for an account the island just
    /// erased, and a join would register a brand-new copy nobody deletes
    /// (spec F2, Phase 0). A lock rather than the main actor because the
    /// guest refresh is read off it.
    static var isBurning: Bool {
        gateLock.lock(); defer { gateLock.unlock() }
        return burning
    }

    static func setBurning(_ on: Bool) {
        gateLock.lock(); burning = on; gateLock.unlock()
    }

    // MARK: plan

    /// The islands this account holds a copy on according to this device's
    /// own stores: the visited islands and the backup homes, merged by host,
    /// never the home island. Only islands in our own stores, never one a peer
    /// named: nothing another island says can make this device delete anything
    /// elsewhere (spec F2 security).
    ///
    /// ⚠ The backup tokens are left out when another account on this device
    /// holds the same number (two islands numbering independently): the store
    /// files them by number alone, and a DELETE with a token that belongs to
    /// the other account would erase that account. The key still proves which
    /// copies are ours, so those islands are still burned, just without the
    /// shortcut.
    @MainActor
    static func remoteCopies(ownUin: Int) -> [CopyHost] {
        let am = AccountManager.shared
        let numberShared = am.accounts.contains { other in
            other.id != am.activeAccountID
                && KeychainStore.string(KeychainStore.Keys.uin, forAccount: other.id) == String(ownUin)
        }
        var out = CopyList()
        for v in VisitedIslandsStore.shared.list() { out.add(v.host, token: v.jwt) }
        for h in MultihomeStore.shared.list(ownUin: ownUin) { out.add(h.host, token: numberShared ? nil : h.jwt) }
        return out.hosts
    }

    /// Hosts merged case-insensitively, own island left out, first-seen order.
    struct CopyList {
        private(set) var hosts: [CopyHost] = []

        init(_ hosts: [CopyHost] = []) {
            self.hosts = hosts
        }

        mutating func add(_ rawHost: String, token: String?) {
            guard let host = Multihome.normalizeHost(rawHost)?.lowercased(), !Multihome.isOwnHost(host) else { return }
            if let i = hosts.firstIndex(where: { $0.host == host }) {
                if let token, !token.isEmpty, !hosts[i].tokens.contains(token) { hosts[i].tokens.append(token) }
            } else {
                hosts.append(CopyHost(host: host, tokens: (token?.isEmpty == false) ? [token!] : []))
            }
        }
    }

    // MARK: run

    /// Phase R of a burn from Settings: every copy in parallel, one retry per
    /// request, back by `deadline` whatever the islands do.
    static func run(_ targets: [BurnTarget], deadline: TimeInterval = 15) async -> [String: IslandBurnResult] {
        await BurnCascadeMachine.run(
            targets, deadline: deadline, retry: true, transport: IslandBurnTransport(timeout: 8)
        )
    }

    /// The wipe PIN's server erase, started only AFTER the local wipe: a single
    /// attempt under one deadline, detached from the UI and from the fresh
    /// boot, inside a background-task grant so locking the phone right after
    /// the wipe does not suspend it mid-request.
    ///
    /// The home island and every copy on other islands at once. Home: the
    /// captured token first; on 401 or 404 the recover handshake with the
    /// captured key, and a DELETE with that token only when recover names the
    /// SAME number (a shared key resolves to the oldest account carrying it,
    /// which may be somebody else's). Other islands: the burn machine with
    /// retries off. No logs: a log line naming the number or an island is the
    /// kind of remnant the wipe exists to remove.
    @MainActor
    static func runDetached(_ snapshot: BurnSnapshot, deadline: TimeInterval = 8) {
        let grant = BackgroundGrant()
        grant.begin()
        let work = Task.detached(priority: .userInitiated) {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await withTaskGroup(of: Void.self) { both in
                        both.addTask { await eraseHome(snapshot, deadline: deadline) }
                        both.addTask { await eraseCopies(snapshot, deadline: deadline) }
                    }
                }
                group.addTask { try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000)) }
                // Whichever ends first ends both: the erase finished, or the
                // deadline passed and the requests are cancelled where they stand.
                _ = await group.next()
                group.cancelAll()
            }
            snapshot.zero()
            await grant.end()
        }
        grant.attach(work)
    }

    private static func eraseHome(_ s: BurnSnapshot, deadline: TimeInterval) async {
        let creds = s.credentials()
        if let token = creds.token {
            let status = await APIClient.shared.deleteAccountStatus(
                base: s.homeBase, bearer: token, serverToken: s.serverToken, timeout: deadline
            )
            switch status {
            case .some(200..<300):
                return
            case .some(401), .some(404):
                break   // stale token: prove the key below
            default:
                return  // suspended, server error, or nothing answered: one attempt only
            }
        }
        guard !Task.isCancelled,
              let raw = creds.signingPriv,
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw),
              let host = s.homeBase.host else { return }
        let authority = s.homeBase.port.map { "\(host):\($0)" } ?? host
        // nil (identity_not_found) means the account is already gone; a
        // rotated or ambiguous answer throws, and neither is ours to delete.
        guard let fresh = try? await Multihome.recoverOn(host: authority, signingPriv: key),
              fresh.uin == s.uin, !Task.isCancelled else { return }
        _ = await APIClient.shared.deleteAccountStatus(
            base: s.homeBase, bearer: fresh.token, serverToken: s.serverToken, timeout: deadline
        )
    }

    private static func eraseCopies(_ s: BurnSnapshot, deadline: TimeInterval) async {
        let creds = s.credentials()
        guard !creds.copies.isEmpty else { return }
        let keys = creds.signingPriv.map { [$0] } ?? []
        let targets = creds.copies.map { BurnTarget(host: $0.host, tokens: $0.tokens, keys: keys) }
        _ = await BurnCascadeMachine.run(
            targets, deadline: deadline, retry: false, transport: IslandBurnTransport(timeout: deadline)
        )
    }
}

/// The burn's requests to an island other than home, over `IslandHTTP` (the
/// same censorship-resistant route every cross-island call takes).
///
/// The recover handshake is spelled out here instead of going through
/// `Multihome.recoverOn`: the burn needs "the challenge endpoint is missing"
/// (an island too old to prove anything on) kept apart from the recover's own
/// `identity_not_found` (proven absent). See `BurnRecover`.
struct IslandBurnTransport: BurnTransport {
    let timeout: TimeInterval

    func deleteAccount(host: String, bearer: String) async -> BurnHTTP {
        if DuressGate.isActive { return .unreachable }
        guard let url = URL(string: "https://\(host)/auth/account") else { return .unreachable }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.timeoutInterval = timeout
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        AccessTokenStore.stamp(&req)   // closed-island gate (foreign host)
        guard let (_, resp) = try? await IslandHTTP.data(for: req),
              let http = resp as? HTTPURLResponse else { return .unreachable }
        return .status(http.statusCode)
    }

    func recover(host: String, signingKey: Data) async -> BurnRecover {
        if DuressGate.isActive { return .unreachable }
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: signingKey) else {
            return .status(0)
        }
        let sk = key.publicKey.rawRepresentation.base64EncodedString()
        struct ChallengeOut: Decodable { let challenge: String }

        let (cCode, cBody) = await post("https://\(host)/auth/recover/challenge", ["signing_key": sk])
        guard let cCode else { return .unreachable }
        if cCode == 404 { return .challengeMissing }
        guard (200..<300).contains(cCode),
              let challenge = try? JSONDecoder().decode(ChallengeOut.self, from: cBody).challenge,
              let signature = try? RecoveryPhrase.signChallenge(signingPrivate: key, challenge: challenge)
        else { return .status(cCode) }

        let (rCode, rBody) = await post(
            "https://\(host)/auth/recover",
            ["signing_key": sk, "challenge": challenge, "signature": signature]
        )
        guard let rCode else { return .unreachable }
        switch rCode {
        case 200..<300:
            guard let creds = try? JSONDecoder().decode(Multihome.Credentials.self, from: rBody) else {
                return .status(rCode)
            }
            return .account(token: creds.token)
        case 404:
            // Exact codes only, never a substring: "gone" is the one answer
            // that ends the island, and a proxy page merely containing the
            // word must not produce it.
            switch Multihome.authErrorDetail(String(data: rBody, encoding: .utf8) ?? "").code {
            case "identity_not_found": return .notFound
            case "identity_rotated": return .rotated
            case "identity_ambiguous": return .ambiguous
            default: return .status(404)
            }
        default:
            return .status(rCode)
        }
    }

    private func post(_ urlString: String, _ json: [String: String]) async -> (Int?, Data) {
        guard let url = URL(string: urlString),
              let body = try? JSONSerialization.data(withJSONObject: json) else { return (nil, Data()) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        AccessTokenStore.stamp(&req)   // closed-island gate (foreign host)
        guard let (data, resp) = try? await IslandHTTP.data(for: req),
              let http = resp as? HTTPURLResponse else { return (nil, Data()) }
        return (http.statusCode, data)
    }
}

/// One `beginBackgroundTask` grant, ended exactly once: by the work when it
/// finishes, or by iOS's expiration handler, which also cancels the work.
@MainActor
private final class BackgroundGrant {
    private var id: UIBackgroundTaskIdentifier = .invalid
    private var work: Task<Void, Never>?

    func begin() {
        // A name without the number or the island in it.
        id = UIApplication.shared.beginBackgroundTask(withName: "rcq.wipe.erase") { [weak self] in
            MainActor.assumeIsolated {
                self?.work?.cancel()
                self?.end()
            }
        }
    }

    func attach(_ task: Task<Void, Never>) {
        work = task
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
        work = nil
    }
}

/// The burn's requests to OUR home island for the same-key accounts that live
/// there (spec F2, Phase H), over the route the app itself uses for home:
/// `APIClient`'s session with the island's masquerade token, and the recover
/// handshake the wipe PIN's home erase already uses.
///
/// Used only after our own home row is gone, so every row the key still
/// recovers on the home island is one of those accounts.
struct HomeBurnTransport: BurnTransport {
    let base: URL
    let serverToken: String?
    let timeout: TimeInterval

    func deleteAccount(host: String, bearer: String) async -> BurnHTTP {
        guard let code = await APIClient.shared.deleteAccountStatus(
            base: base, bearer: bearer, serverToken: serverToken, timeout: timeout
        ) else { return .unreachable }
        return .status(code)
    }

    func recover(host: String, signingKey: Data) async -> BurnRecover {
        if DuressGate.isActive { return .unreachable }
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: signingKey) else {
            return .status(0)
        }
        do {
            // nil is `identity_not_found` and nothing else (see `recoverOn`).
            guard let fresh = try await Multihome.recoverOn(host: host, signingPriv: key) else { return .notFound }
            return .account(token: fresh.token)
        } catch {
            // Rotated, ambiguous, refused or unreachable: none of them proves
            // the rows gone, so the island does not count as settled.
            return .status(502)
        }
    }
}

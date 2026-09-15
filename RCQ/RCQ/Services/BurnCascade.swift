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
/// ⏭ C0 holds the HOME island only. Burn across islands (spec F2, release C1)
/// adds the visited and backup targets and both keys of a pending rotation.
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

    private init(homeBase: URL, uin: Int, serverToken: String?, token: String?, signingPriv: Data?) {
        self.homeBase = homeBase
        self.uin = uin
        self.serverToken = serverToken
        self.token = token
        self.signingPriv = signingPriv
    }

    /// Read the active account's credentials. No network: every read here is
    /// the Keychain or an in-process value. Nil when there is nothing that
    /// could authenticate an erase.
    ///
    /// Same slot rule as `AuthService.deleteServerAccount`: this runs from the
    /// lock screen of a COLD START too, before boot ever handed `APIClient` a
    /// token, and only the legacy/first account may read the unprefixed slot.
    @MainActor
    static func capture() async -> BurnSnapshot? {
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
            signingPriv: signing
        )
    }

    fileprivate func credentials() -> (token: String?, signingPriv: Data?) {
        lock.lock(); defer { lock.unlock() }
        return (token, signingPriv)
    }

    func zero() {
        lock.lock(); defer { lock.unlock() }
        if var bytes = signingPriv {
            signingPriv = nil
            bytes.resetBytes(in: 0..<bytes.count)
        }
        token = nil
    }

    deinit { zero() }
}

enum BurnCascade {

    /// The wipe PIN's server erase, started only AFTER the local wipe: a single
    /// attempt under one deadline, detached from the UI and from the fresh
    /// boot, inside a background-task grant so locking the phone right after
    /// the wipe does not suspend it mid-request.
    ///
    /// Per island (home only in C0): the captured token first; on 401 or 404
    /// the recover handshake with the captured key, and a DELETE with that
    /// token only when recover names the SAME number (a shared key resolves to
    /// the oldest account carrying it, which may be somebody else's). No
    /// retries, no logs: a log line naming the number or the island is the
    /// kind of remnant the wipe exists to remove.
    @MainActor
    static func runDetached(_ snapshot: BurnSnapshot, deadline: TimeInterval = 8) {
        let grant = BackgroundGrant()
        grant.begin()
        let work = Task.detached(priority: .userInitiated) {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await eraseHome(snapshot, deadline: deadline) }
                group.addTask { try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000)) }
                // Whichever ends first ends both: the erase finished, or the
                // deadline passed and the request is cancelled where it stands.
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

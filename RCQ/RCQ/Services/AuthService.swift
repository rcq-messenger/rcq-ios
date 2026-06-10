import Foundation
import CryptoKit

@MainActor
final class AuthService: ObservableObject {
    static let shared = AuthService()

    @Published private(set) var ownUIN: Int?
    @Published private(set) var nickname: String = ""
    @Published private(set) var isReady: Bool = false

    private init() {
        if let uinStr = KeychainStore.string(KeychainStore.Keys.uin), let uin = Int(uinStr) {
            self.ownUIN = uin
            self.nickname = KeychainStore.string(KeychainStore.Keys.nickname) ?? ""
        }
    }

    /// First launch: mint identity, register, persist to Keychain. On subsequent
    /// launches validates the cached identity against the server and self-heals
    /// if our UIN no longer exists (burn from another device, dev DB wipe).
    func bootstrapIfNeeded(suggestedNickname: String? = nil) async throws {
        let probeToken = KeychainStore.string(KeychainStore.Keys.token)
        let probeUIN = KeychainStore.string(KeychainStore.Keys.uin)
        if let token = probeToken,
           let uinStr = probeUIN,
           let uin = Int(uinStr) {
            await APIClient.shared.setToken(token)
            do {
                let _: UserProfile = try await APIClient.shared.request("GET", "/users/\(uin)/info")
                self.ownUIN = uin
                self.nickname = KeychainStore.string(KeychainStore.Keys.nickname) ?? ""
                // Fire-and-forget Stage 3 top-up. Failure is non-fatal —
                // encrypt path falls back to v=1 per peer.
                try? await SignalIdentityBootstrap.ensureBootstrapped(ownUIN: uin)
                await publishHomeIslandRecord(ownUIN: uin)
                UserDefaults.standard.removeObject(forKey: AppState.pendingInviterKey)
                isReady = true
                return
            } catch APIError.http(404, _), APIError.http(401, _) {
                // 404 → server forgot us. 401 → JWT signed with a different
                // server's secret. Wipe and re-register.
                await wipeLocalIdentity()
            } catch {
                // Transient — keep cached identity for now.
                self.ownUIN = uin
                self.nickname = KeychainStore.string(KeychainStore.Keys.nickname) ?? ""
                isReady = true
                return
            }
        }

        let nick = suggestedNickname ?? "user-\(Int.random(in: 1000...9999))"

        // Generate long-term X25519 + Ed25519 keypairs. `bootstrap()`
        // writes the private halves to the Keychain.
        let (bundle, _) = try SignalCryptoService.bootstrap()

        struct Body: Encodable {
            let nickname: String
            let identity_key: String
            let signing_key: String
            let inviter_uin: Int?
            let invite: String?
        }
        struct Out: Decodable { let uin: Int; let token: String }

        let inviterUIN = UserDefaults.standard.object(forKey: AppState.pendingInviterKey) as? Int
        // Consume-once: read + clear the server-join invite up front so a failed
        // register (e.g. bad invite → 403) can't leave it to leak into the next.
        let serverInvite = UserDefaults.standard.string(forKey: AppState.pendingServerInviteKey)
        UserDefaults.standard.removeObject(forKey: AppState.pendingServerInviteKey)

        let out: Out = try await APIClient.shared.request(
            "POST",
            "/auth/register",
            body: Body(
                nickname: nick,
                identity_key: bundle.identityKey,
                signing_key: bundle.signingKey,
                inviter_uin: inviterUIN,
                invite: serverInvite
            )
        )
        UserDefaults.standard.removeObject(forKey: AppState.pendingInviterKey)

        KeychainStore.setString(KeychainStore.Keys.uin, String(out.uin))
        KeychainStore.setString(KeychainStore.Keys.token, out.token)
        KeychainStore.setString(KeychainStore.Keys.nickname, nick)

        await APIClient.shared.setToken(out.token)
        ownUIN = out.uin
        nickname = nick

        // Stage 3 bootstrap. Failure here doesn't block registration —
        // peers fall back to v=1 until next successful boot.
        try? await SignalIdentityBootstrap.ensureBootstrapped(ownUIN: out.uin)
        await publishHomeIslandRecord(ownUIN: out.uin)

        isReady = true
    }

    /// Federation Layer B (F1): build + publish this account's signed home-island
    /// record after the libsignal identity exists. Single-homed on this session's
    /// island for now (multi-homing = F2). Fully best-effort — any failure (an
    /// island without the F1 endpoint, a missing key, a network hiccup) is
    /// swallowed so it can never disrupt login. Mirrors the web + Android wiring.
    private func publishHomeIslandRecord(ownUIN: Int) async {
        guard let sigBytes = KeychainStore.data(KeychainStore.Keys.signingPriv),
              let signingPriv = try? Curve25519.Signing.PrivateKey(rawRepresentation: sigBytes),
              let local = try? SignalProtocolStores.shared.loadLocalIdentity() else { return }
        let sk = signingPriv.publicKey.rawRepresentation.base64EncodedString()
        let ik = local.identityKeyPair.publicKey.serialize().base64EncodedString()
        let host = APIClient.shared.baseURL.host ?? RcqFederation.flagshipHost
        let homes = [RcqFederation.Home(host: host, uin: ownUIN)]
        let ts = Int(Date().timeIntervalSince1970)
        guard let doc = try? RcqFederation.buildRecord(ik: ik, sk: sk, signingPriv: signingPriv, homes: homes, ts: ts),
              let body = try? JSONSerialization.data(withJSONObject: doc) else { return }
        _ = await APIClient.shared.publishIslandRecord(body)
    }

    /// The active account's 24-word recovery phrase, or nil for a legacy
    /// account whose keys predate seed-derivation (nothing to back up). The
    /// caller gates the Settings UI on nil to show a "not available" notice.
    func recoveryPhrase() -> [String]? {
        guard let seed = KeychainStore.data(KeychainStore.Keys.recoverySeed) else { return nil }
        return RecoveryPhrase.encode(seed)
    }

    /// A LEGACY account (no seed) backup: its raw identity keys exported as a
    /// 48-word phrase (idPriv||signPriv = 64 bytes). nil for a seed-derived
    /// account (use recoveryPhrase()) or if keys are missing/malformed.
    func legacyExportPhrase() -> [String]? {
        guard KeychainStore.data(KeychainStore.Keys.recoverySeed) == nil else { return nil }
        guard let id = KeychainStore.data(KeychainStore.Keys.identityPriv),
              let sign = KeychainStore.data(KeychainStore.Keys.signingPriv),
              id.count == 32, sign.count == 32 else { return nil }
        return RecoveryPhrase.encode(id + sign)
    }

    /// Rotate the active account's long-term identity to a fresh seed/keypair
    /// while KEEPING the same UIN. Derives new X25519 + Ed25519 keys from a new
    /// recovery seed, pushes the new public keys to /auth/reissue, persists them
    /// (server-FIRST, so a failed call never strands us on keys the server
    /// doesn't have), and rebuilds the libsignal bundle so the safety number
    /// changes and contacts get a "security code changed" warning on their next
    /// key sync. Returns the NEW 24-word phrase, or nil on failure. For users
    /// who fear key compromise or just want a fresh phrase.
    func reissueKeys() async -> [String]? {
        guard ownUIN != nil else { return nil }
        do {
            let newSeed = RecoveryPhrase.newSeed()
            let keys = try RecoveryPhrase.deriveKeys(seed: newSeed)
            struct Body: Encodable { let identity_key: String; let signing_key: String }
            struct Out: Decodable { let uin: Int; let token: String }
            let out: Out = try await APIClient.shared.request(
                "POST", "/auth/reissue",
                body: Body(identity_key: keys.identityPubB64, signing_key: keys.signingPubB64)
            )
            // Server accepted the new keys — now commit them locally.
            KeychainStore.set(KeychainStore.Keys.identityPriv, keys.identityPriv.rawRepresentation)
            KeychainStore.set(KeychainStore.Keys.signingPriv,  keys.signingPriv.rawRepresentation)
            KeychainStore.set(KeychainStore.Keys.recoverySeed, newSeed)
            KeychainStore.setString(KeychainStore.Keys.token, out.token)
            await APIClient.shared.setToken(out.token)
            // Rotate the libsignal identity too → new safety number (upload-first).
            try await SignalIdentityBootstrap.rebootstrap(ownUIN: out.uin)
            return RecoveryPhrase.encode(newSeed)
        } catch {
            return nil
        }
    }

    func updateNicknameLocal(_ nick: String) {
        nickname = nick
        KeychainStore.setString(KeychainStore.Keys.nickname, nick)
    }

    func applyDecoyIdentity(uin: Int, nickname: String) {
        self.ownUIN = uin
        self.nickname = nickname
    }

    func restoreRealIdentity() {
        if let s = KeychainStore.string(KeychainStore.Keys.uin), let u = Int(s) {
            ownUIN = u
        }
        nickname = KeychainStore.string(KeychainStore.Keys.nickname) ?? ""
    }

    /// Hard reset — wipes Keychain, in-memory state, and API token.
    /// Used by the "Burn account" flow.
    /// In-memory reset for the soft account-switch path. Doesn't
    /// touch Keychain or the libsignal store — those are per-account
    /// already and stay on disk for the next switch-back. Just nulls
    /// out the @Published properties so any view still holding a
    /// reference to AuthService.shared during the rebootForActiveAccount
    /// window doesn't render the OLD account's UIN / nickname over
    /// the new account's empty state. Bootstrap repopulates these
    /// from the new account's Keychain prefix.
    func resetForAccountSwitch() {
        ownUIN = nil
        nickname = ""
        isReady = false
    }

    func wipeLocalIdentity() async {
        for key in [
            KeychainStore.Keys.uin,
            KeychainStore.Keys.token,
            KeychainStore.Keys.nickname,
            KeychainStore.Keys.identityPriv,
            KeychainStore.Keys.signingPriv,
            KeychainStore.Keys.recoverySeed,
        ] {
            KeychainStore.delete(key)
        }
        // Stage 3 stores live in App Group SQLite, not Keychain. Burn
        // them too — re-registered identity must not inherit stale
        // sessions/ratchet state.
        SignalProtocolDB.shared.wipe()
        await APIClient.shared.setToken(nil)
        ownUIN = nil
        nickname = ""
        isReady = false
    }

    /// Best-effort — local burn proceeds even if this fails.
    func deleteServerAccount() async {
        let _: EmptyResponse? = try? await APIClient.shared.request(
            "DELETE", "/auth/account"
        )
    }
}

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
        // Decide register-vs-validate from the ACTIVE account's OWN credentials.
        // KeychainStore.string() falls back to the legacy UNPREFIXED slot when the
        // per-account slot is empty — a safety net meant only for the legacy first
        // account before migration. A FRESH account added on a custom server has an
        // empty own-slot, so that fallback handed it the flagship's creds (911) and
        // boot validated the flagship instead of registering on the new island
        // (founder: is2 worked because it has its own creds; a brand-new custom
        // server did not). Only the legacy/first account may use the unprefixed
        // fallback; every other account reads strictly its own slot → so a fresh
        // custom-server account registers instead of inheriting the flagship.
        let am = AccountManager.shared
        let legacyOwner = am.accounts.count <= 1 || am.activeAccountID == am.accounts.first?.id
        let probeToken: String? = legacyOwner
            ? KeychainStore.string(KeychainStore.Keys.token)
            : am.activeAccountID.flatMap { KeychainStore.string(KeychainStore.Keys.token, forAccount: $0) }
        let probeUIN: String? = legacyOwner
            ? KeychainStore.string(KeychainStore.Keys.uin)
            : am.activeAccountID.flatMap { KeychainStore.string(KeychainStore.Keys.uin, forAccount: $0) }
        print("[boot] bootstrap: active=\(am.activeAccountID?.uuidString.prefix(8).description ?? "nil") base=\(APIClient.shared.baseURL.absoluteString) legacyOwner=\(legacyOwner) probeUIN=\(probeUIN ?? "nil")")
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
                // 404 → the island answers "no such uin". 401 → the token no
                // longer authenticates (rotated server secret; servers before
                // 2026-07 also 401'd tokens idle past their 30-day exp).
                // NEITHER proves the account is gone, and the old response
                // here — wipe + silent fresh-register — destroyed real
                // identities (July reports: long-idle users opened the app to
                // a fresh 9-digit UIN). We hold the Ed25519 signing key, so
                // ask the island to re-mint a token for the SAME identity
                // first; only when a real island completes the recover
                // handshake and itself answers "identity unknown" (true burn
                // / server DB wipe) fall through to the historical
                // wipe + fresh-register self-heal — after stashing the keys.
                print("[boot] cached uin=\(uin) rejected by \(APIClient.shared.baseURL.absoluteString) — attempting key recover")
                switch await recoverOwnSession(expectedUIN: uin) {
                case .recovered(let creds):
                    print("[boot] recovered uin=\(creds.uin) with a fresh token")
                    KeychainStore.setString(KeychainStore.Keys.uin, String(creds.uin))
                    KeychainStore.setString(KeychainStore.Keys.token, creds.token)
                    await APIClient.shared.setToken(creds.token)
                    self.ownUIN = creds.uin
                    self.nickname = KeychainStore.string(KeychainStore.Keys.nickname) ?? ""
                    try? await SignalIdentityBootstrap.ensureBootstrapped(ownUIN: creds.uin)
                    await publishHomeIslandRecord(ownUIN: creds.uin)
                    UserDefaults.standard.removeObject(forKey: AppState.pendingInviterKey)
                    isReady = true
                    return
                case .identityUnknown:
                    print("[boot] island confirmed identity unknown — wiping + re-registering")
                    stashWipedIdentityBackup(uin: uin)
                    await wipeLocalIdentity()
                case .transient:
                    // Can't prove the account is gone (no signing key, the
                    // recover endpoint unreachable / unsupported, or the key
                    // resolved to a DIFFERENT uin). Keep the cached identity
                    // — never destroy what we cannot re-mint.
                    print("[boot] rejection unconfirmed — keeping cached identity")
                    self.ownUIN = uin
                    self.nickname = KeychainStore.string(KeychainStore.Keys.nickname) ?? ""
                    isReady = true
                    return
                }
            } catch {
                // Transient — keep cached identity for now.
                print("[boot] cached uin=\(uin) kept (transient: \(error.localizedDescription))")
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
            // Which INSTALL this session belongs to. Without it the server
            // keys us as "primary" like every other install of the account:
            // their websockets supersede each other in a loop, and they share
            // one offline-queue cursor so the first to drain leaves the rest
            // with nothing to read.
            let device_id: String
            // Proof that we hold the private half of `signing_key`. A public
            // signing key is public, so without this anyone could register an
            // account carrying somebody else's and capture where their recovery
            // lands. Optional on the wire: an island that predates the
            // challenge endpoint 404s and registration works as before.
            let challenge: String?
            let signature: String?
        }
        struct ChalBody: Encodable { let signing_key: String }
        struct ChalOut: Decodable { let challenge: String }
        struct Out: Decodable { let uin: Int; let token: String }

        let inviterUIN = UserDefaults.standard.object(forKey: AppState.pendingInviterKey) as? Int
        // Consume-once: read + clear the server-join invite up front so a failed
        // register (e.g. bad invite → 403) can't leave it to leak into the next.
        let serverInvite = UserDefaults.standard.string(forKey: AppState.pendingServerInviteKey)
        UserDefaults.standard.removeObject(forKey: AppState.pendingServerInviteKey)

        // Best-effort key proof, before the register call below.
        var regChallenge: String? = nil
        var regSignature: String? = nil
        if let chal: ChalOut = try? await APIClient.shared.request(
            "POST", "/auth/register/challenge",
            body: ChalBody(signing_key: bundle.signingKey),
            authenticated: false
        ), let signingPriv = KeychainStore.data(KeychainStore.Keys.signingPriv),
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: signingPriv),
           let sig = try? RecoveryPhrase.signChallenge(signingPrivate: key, challenge: chal.challenge) {
            regChallenge = chal.challenge
            regSignature = sig
        }

        print("[boot] registering fresh @ \(APIClient.shared.baseURL.absoluteString)")
        let out: Out
        do {
            out = try await APIClient.shared.request(
                "POST",
                "/auth/register",
                body: Body(
                    nickname: nick,
                    identity_key: bundle.identityKey,
                    signing_key: bundle.signingKey,
                    inviter_uin: inviterUIN,
                    invite: serverInvite,
                    device_id: KeychainStore.deviceID(),
                    challenge: regChallenge,
                    signature: regSignature
                )
            )
        } catch {
            print("[boot] register FAILED @ \(APIClient.shared.baseURL.absoluteString): \(error)")
            throw error
        }
        print("[boot] register ok uin=\(out.uin) @ \(APIClient.shared.baseURL.absoluteString)")
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

    /// Outcome of asking the active island to re-mint a session token for the
    /// locally-held identity keys.
    private enum RecoverOutcome {
        case recovered(Multihome.Credentials)
        case identityUnknown
        case transient
    }

    /// Challenge-response `/auth/recover` against the ACTIVE base using the
    /// account's own Ed25519 key. `identityUnknown` only when a real RCQ
    /// island completed the challenge handshake and then 404'd the recover —
    /// a decoy site, an old island without the endpoint, or any network error
    /// is `transient` (never grounds for wiping). A recover that lands on a
    /// DIFFERENT uin (the legacy-slot fallback handing us another account's
    /// key) is also `transient`: proving THAT key exists says nothing about
    /// THIS account.
    private func recoverOwnSession(expectedUIN: Int) async -> RecoverOutcome {
        guard let host = APIClient.shared.baseURL.host,
              let sigBytes = KeychainStore.data(KeychainStore.Keys.signingPriv),
              let signingPriv = try? Curve25519.Signing.PrivateKey(rawRepresentation: sigBytes) else {
            return .transient
        }
        do {
            guard let creds = try await Multihome.recoverOn(host: host, signingPriv: signingPriv) else {
                return .identityUnknown
            }
            return creds.uin == expectedUIN ? .recovered(creds) : .transient
        } catch {
            return .transient
        }
    }

    /// Last-resort escape hatch: before the wipe + fresh-register self-heal
    /// destroys an identity, keep its key material under a single global
    /// Keychain slot (latest wipe only) so support can still rescue a user
    /// whose account turns out not to have been gone after all.
    private func stashWipedIdentityBackup(uin: Int) {
        var dict: [String: String] = [
            "uin": String(uin),
            "ts": String(Int(Date().timeIntervalSince1970)),
        ]
        dict["nickname"] = KeychainStore.string(KeychainStore.Keys.nickname)
        dict["seed"] = KeychainStore.data(KeychainStore.Keys.recoverySeed)?.base64EncodedString()
        dict["identityPriv"] = KeychainStore.data(KeychainStore.Keys.identityPriv)?.base64EncodedString()
        dict["signingPriv"] = KeychainStore.data(KeychainStore.Keys.signingPriv)?.base64EncodedString()
        if let data = try? JSONSerialization.data(withJSONObject: dict) {
            KeychainStore.set("rcq.wiped.identity.backup", data)
        }
    }

    /// Federation Layer B (F1): build + publish this account's signed home-island
    /// record after the libsignal identity exists — the primary island plus any
    /// backup homes (multihoming v1). The same signed record is PUT to every
    /// home so senders can resolve it from whichever island survives. Fully
    /// best-effort — any failure (an island without the F1 endpoint, a missing
    /// key, a network hiccup) is swallowed so it can never disrupt login.
    /// Mirrors the web + Android wiring. Internal so the Settings backup-island
    /// surface can republish after an add/remove.
    func publishHomeIslandRecord(ownUIN: Int) async {
        guard let doc = buildOwnRecordDoc(ownUIN: ownUIN),
              let body = try? JSONSerialization.data(withJSONObject: doc) else { return }
        _ = await APIClient.shared.publishIslandRecord(body)
        let homeCount = (doc["homes"] as? [[String: Any]])?.count ?? 1
        if homeCount > 1 { await Multihome.publishToBackups(ownUin: ownUIN, recordBody: body) }
    }

    /// Build + sign this account's current home-island record (primary + backup
    /// homes). Shared by the F1 publish above and the gossip B1 self-push so
    /// both sign the exact same bytes. Returns nil before the libsignal device
    /// or signing key exists.
    func buildOwnRecordDoc(ownUIN: Int) -> [String: Any]? {
        guard let sigBytes = KeychainStore.data(KeychainStore.Keys.signingPriv),
              let signingPriv = try? Curve25519.Signing.PrivateKey(rawRepresentation: sigBytes),
              let local = try? SignalProtocolStores.shared.loadLocalIdentity() else { return nil }
        let sk = signingPriv.publicKey.rawRepresentation.base64EncodedString()
        let ik = local.identityKeyPair.publicKey.serialize().base64EncodedString()
        let host = APIClient.shared.baseURL.host ?? RcqFederation.flagshipHost
        let homes = [RcqFederation.Home(host: host, uin: ownUIN)] +
            MultihomeStore.shared.list(ownUin: ownUIN).map { RcqFederation.Home(host: $0.host, uin: $0.uin) }
        let ts = Int(Date().timeIntervalSince1970)
        return try? RcqFederation.buildRecord(ik: ik, sk: sk, signingPriv: signingPriv, homes: homes, ts: ts)
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

import Foundation

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
        }
        struct Out: Decodable { let uin: Int; let token: String }

        let inviterUIN = UserDefaults.standard.object(forKey: AppState.pendingInviterKey) as? Int

        let out: Out = try await APIClient.shared.request(
            "POST",
            "/auth/register",
            body: Body(
                nickname: nick,
                identity_key: bundle.identityKey,
                signing_key: bundle.signingKey,
                inviter_uin: inviterUIN
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

        isReady = true
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

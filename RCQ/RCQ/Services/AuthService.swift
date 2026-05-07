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

    /// First launch: pick a default nickname, mint a Signal identity, register with the
    /// backend, persist UIN+token+nickname to Keychain.
    ///
    /// On subsequent launches we still validate the cached identity against the
    /// server — if our UIN no longer exists (account burned from another device,
    /// dev wiped the DB, etc.) we self-heal by wiping Keychain and re-registering.
    /// Without this guard the app sits with stale credentials forever.
    func bootstrapIfNeeded(suggestedNickname: String? = nil) async throws {
        if let token = KeychainStore.string(KeychainStore.Keys.token),
           let uinStr = KeychainStore.string(KeychainStore.Keys.uin),
           let uin = Int(uinStr) {
            await APIClient.shared.setToken(token)
            do {
                let _: UserProfile = try await APIClient.shared.request("GET", "/users/\(uin)/info")
                self.ownUIN = uin
                self.nickname = KeychainStore.string(KeychainStore.Keys.nickname) ?? ""
                // Fire-and-forget Stage 3 top-up. Existing accounts
                // upgrading to Stage 3 land here and bootstrap once;
                // every subsequent launch just verifies the OPK pool
                // and refills if low. Failure is non-fatal — the
                // encrypt path falls back to v=1 per peer.
                try? await SignalIdentityBootstrap.ensureBootstrapped(ownUIN: uin)
                isReady = true
                return
            } catch APIError.http(404, _), APIError.http(401, _) {
                // 404 → server forgot us (dev DB wipe, account burn from
                // another device). 401 → JWT signed with a different
                // server's secret (e.g. token cached from local dev,
                // simulator now points at prod). Either way, wipe local
                // identity and fall through to a fresh registration.
                await wipeLocalIdentity()
            } catch {
                // Network or other transient — keep cached identity for now.
                self.ownUIN = uin
                self.nickname = KeychainStore.string(KeychainStore.Keys.nickname) ?? ""
                isReady = true
                return
            }
        }

        let nick = suggestedNickname ?? "user-\(Int.random(in: 1000...9999))"

        // Generate the long-term X25519 (ECDH) and Ed25519 (signing) keypairs.
        // `bootstrap()` writes the private halves to the Keychain itself so
        // we don't have to remember them here.
        let (bundle, _) = try SignalCryptoService.bootstrap()

        struct Body: Encodable {
            let nickname: String
            let identity_key: String
            let signing_key: String
        }
        struct Out: Decodable { let uin: Int; let token: String }

        let out: Out = try await APIClient.shared.request(
            "POST",
            "/auth/register",
            body: Body(
                nickname: nick,
                identity_key: bundle.identityKey,
                signing_key: bundle.signingKey
            )
        )

        KeychainStore.setString(KeychainStore.Keys.uin, String(out.uin))
        KeychainStore.setString(KeychainStore.Keys.token, out.token)
        KeychainStore.setString(KeychainStore.Keys.nickname, nick)

        await APIClient.shared.setToken(out.token)
        ownUIN = out.uin
        nickname = nick

        // Stage 3: generate libsignal identity + prekeys + Kyber and
        // upload the bundle so other Stage 3 senders can ride v=2 with
        // us right away. A failure here doesn't block registration —
        // peers just fall back to v=1 until our next successful boot.
        try? await SignalIdentityBootstrap.ensureBootstrapped(ownUIN: out.uin)

        isReady = true
    }

    func updateNicknameLocal(_ nick: String) {
        nickname = nick
        KeychainStore.setString(KeychainStore.Keys.nickname, nick)
    }

    /// Hard reset of the local identity. Wipes every Keychain entry tied to the
    /// current account, clears the in-memory snapshot, and forgets the API
    /// token. Used by the "Burn account" flow — after this call the app behaves
    /// as if it had been freshly installed.
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
        // Stage 3 protocol stores live in the shared App Group SQLite,
        // not the Keychain. Burn them too — otherwise a re-registered
        // identity inherits stale sessions and ratchet state and the
        // first message after re-register fails to decrypt on the
        // peer.
        SignalProtocolDB.shared.wipe()
        await APIClient.shared.setToken(nil)
        ownUIN = nil
        nickname = ""
        isReady = false
    }

    /// Ask the server to delete our account. Best-effort — local burn proceeds
    /// even if this fails (e.g. offline), so the user can always escape.
    func deleteServerAccount() async {
        let _: EmptyResponse? = try? await APIClient.shared.request(
            "DELETE", "/auth/account"
        )
    }
}

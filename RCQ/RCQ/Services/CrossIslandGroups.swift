import Foundation
import CryptoKit

/// Cross-island GROUPS (room-host, federation §5c).
///
/// A group lives entirely on ONE island; a member from another island becomes
/// a first-class citizen of the group's island via a GUEST registration —
/// recover-first with the SAME keypair (the multihome mechanic), giving a
/// per-island (uin, jwt). All group machinery then runs unchanged on the host
/// island; the guest client deposits sends there and polls its guest mailbox.
/// No island ever talks to another island.
///
/// Unlike multihome backup homes, visited islands are PRIVATE: never published
/// in the signed home-island record (group membership is not an addressing
/// fact). Per-account, mirroring CrossIslandRequestsStore.
///
/// Foreign group ids: per-island ints collide across islands, and every store
/// (threads/unread/routes) keys groups by an Int. Foreign groups therefore get
/// a stable NEGATIVE local alias id; the API boundary translates
/// alias ↔ (host, remoteId). Mirrors web visited-islands.ts / Android
/// VisitedIslandsStore.
final class VisitedIslandsStore {
    static let shared = VisitedIslandsStore()

    struct Visited: Codable {
        let host: String
        let uin: Int     // per-island uin of this identity (same keys as primary)
        let jwt: String
        let addedAt: Date
        /// The island called this copy a guest copy (spec 2026-09-15, 2.3):
        /// it takes part in rooms there and nothing else. Nil on entries saved
        /// before the field and on islands that never send it, which is a
        /// native account.
        var guest: Bool? = nil
    }

    struct AliasRef: Codable {
        let host: String
        let remoteId: Int
        let aliasId: Int // negative, stable per account
    }

    private static let appGroup = "group.app.rcq.shared"
    private static let visitedPrefix = "rcq.visited.v1."
    private static let aliasPrefix = "rcq.fgroup-alias.v1."

    private let defaults: UserDefaults
    private var visitedKey: String
    private var aliasKey: String

    private init() {
        defaults = UserDefaults(suiteName: Self.appGroup) ?? .standard
        let id = AppGroup.readActiveAccountID()
        visitedKey = Self.visitedPrefix + (id?.uuidString ?? "none")
        aliasKey = Self.aliasPrefix + (id?.uuidString ?? "none")
    }

    /// Re-point at the active account on launch + every account switch.
    func bind(accountID: UUID?) {
        visitedKey = Self.visitedPrefix + (accountID?.uuidString ?? "none")
        aliasKey = Self.aliasPrefix + (accountID?.uuidString ?? "none")
    }

    // MARK: visited islands

    func list() -> [Visited] {
        guard let data = defaults.data(forKey: visitedKey),
              let v = try? JSONDecoder().decode([Visited].self, from: data) else { return [] }
        return v
    }

    func get(host: String) -> Visited? { list().first { $0.host == host.lowercased() } }

    func save(_ v: Visited) {
        let next = list().filter { $0.host != v.host.lowercased() } +
            [Visited(host: v.host.lowercased(), uin: v.uin, jwt: v.jwt, addedAt: v.addedAt, guest: v.guest)]
        if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: visitedKey) }
    }

    /// `guest` nil keeps what is on file: an island older than the flag says
    /// nothing, and that is not news that the copy stopped being a guest.
    func updateCreds(host: String, uin: Int, jwt: String, guest: Bool? = nil) {
        guard let cur = get(host: host) else { return }
        save(Visited(host: cur.host, uin: uin, jwt: jwt, addedAt: cur.addedAt, guest: guest ?? cur.guest))
    }

    /// Spec 9.1: this copy settled and lives on that island now. The row keeps
    /// its number and its token, because a conversion changes neither; the one
    /// thing it stops being is a guest.
    func markSettled(host: String) {
        guard let cur = get(host: host) else { return }
        save(Visited(host: cur.host, uin: cur.uin, jwt: cur.jwt, addedAt: cur.addedAt, guest: false))
    }

    /// Forget one island's login: a burn deleted our copy there and then
    /// stopped short of the wipe (spec F2). The alias map stays, so the local
    /// ids of that island's rooms keep meaning the same rooms.
    func remove(host: String) {
        let h = host.lowercased()
        let next = list().filter { $0.host != h }
        if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: visitedKey) }
    }

    /// Another account's visited islands, read without binding to it: the
    /// burn of a same-key account (spec F2) deletes its copies too.
    static func list(accountID: UUID) -> [Visited] {
        let d = UserDefaults(suiteName: appGroup) ?? .standard
        guard let data = d.data(forKey: visitedPrefix + accountID.uuidString),
              let v = try? JSONDecoder().decode([Visited].self, from: data) else { return [] }
        return v
    }

    /// `wipe()` for an account that is not the bound one.
    static func wipeStored(accountID: UUID) {
        let d = UserDefaults(suiteName: appGroup) ?? .standard
        d.removeObject(forKey: visitedPrefix + accountID.uuidString)
        d.removeObject(forKey: aliasPrefix + accountID.uuidString)
    }

    // MARK: foreign-group alias ids

    private func aliases() -> [AliasRef] {
        guard let data = defaults.data(forKey: aliasKey),
              let a = try? JSONDecoder().decode([AliasRef].self, from: data) else { return [] }
        return a
    }

    func isForeignGroupId(_ id: Int) -> Bool { id < 0 }

    /// Stable local alias for (host, remoteId); allocated on first sight.
    func aliasFor(host: String, remoteId: Int) -> Int {
        let h = host.lowercased()
        let all = aliases()
        if let hit = all.first(where: { $0.host == h && $0.remoteId == remoteId }) { return hit.aliasId }
        let aliasId = -(1000 + all.count) // negative: server ids are positive
        let next = all + [AliasRef(host: h, remoteId: remoteId, aliasId: aliasId)]
        if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: aliasKey) }
        return aliasId
    }

    func refByAlias(_ aliasId: Int) -> AliasRef? { aliases().first { $0.aliasId == aliasId } }

    func wipe() {
        defaults.removeObject(forKey: visitedKey)
        defaults.removeObject(forKey: aliasKey)
    }
}

/// Raw-host group operations for §5c. APIClient is pinned to the primary
/// island, so every cross-island call goes through URLSession directly here
/// (groups list/preview/join with the guest jwt; group-sealed deposit is the
/// open unauthenticated path; queue drain with the guest jwt). The returned
/// RCQGroups are stamped with the local alias id + host so the rest of the app
/// keeps working on plain Ints.
enum CrossIslandGroups {
    enum CIGError: Error {
        case noKeys
        /// The island answered and said no: its HTTP status and `detail.code`
        /// (spec 2026-09-15, 12.4). Status 0 is a request that could not even
        /// be built. Callers read the code, never the body text.
        case refused(status: Int, code: String?)
        case burning
        /// A decoy or duress view is up, the app is locked, or the account
        /// switched while the request was in the air: nothing reaches a copy,
        /// and the person sees what they would see offline.
        case offline
        /// `identity_rotated`: this key was retired by a signed key change on
        /// another device. The rotated-elsewhere sentence, and NEVER a wipe.
        case rotated
        /// Nothing answered.
        case unreachable
    }

    /// The decoy identity must never reach this account's copies: their
    /// tokens are the real account's.
    @MainActor
    static func decoyOrLocked() -> Bool {
        PanicPINService.shared.isDecoy || PanicPINService.shared.isLocked
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let date = iso.date(from: s) ?? isoPlain.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "bad date \(s)"))
        }
        return d
    }()

    /// Guest credentials for `host`, made on first use (federation §5c). The
    /// copy is PRIVATE: never published in the home-island record. Throws on
    /// failure.
    ///
    /// Two roads (spec 2026-09-15, 12.1), chosen from the island's own
    /// `/server/info`, asked only now, on the explicit Join tap, and only when
    /// no copy is on file:
    ///
    /// * `guest_accounts_v1` advertised and a room to join: `/auth/guest` with
    ///   an `rcq-guest-v1` proof over that island, that room, both our keys and
    ///   a fresh challenge. The island hands back the row this key already has
    ///   there, or a new guest copy together with its first membership.
    /// * anywhere else: recover-first, then `/auth/register`, now with the
    ///   register challenge and its signature and still never `desired_uin`.
    ///
    /// Nothing about the home island goes out on either road: not its host,
    /// not our number there, not a record. `groupId` is the room id ON `host`.
    static func ensureGuest(host: String, nickname: String, groupId: Int? = nil) async throws -> VisitedIslandsStore.Visited {
        guard let h = Multihome.normalizeHost(host) else { throw Multihome.AddError.invalidHost }
        // A copy registered while a burn deletes the others is a copy nobody
        // deletes (spec F2, Phase 0).
        if BurnCascade.isBurning { throw CIGError.burning }
        // Before the store is even read: a copy on file is the real account's
        // token, and the decoy identity never holds one.
        if await decoyOrLocked() { throw CIGError.offline }
        if let existing = VisitedIslandsStore.shared.get(host: h) { return existing }
        guard let sigBytes = KeychainStore.data(KeychainStore.Keys.signingPriv),
              let signingPriv = try? Curve25519.Signing.PrivateKey(rawRepresentation: sigBytes),
              let idBytes = KeychainStore.data(KeychainStore.Keys.identityPriv),
              let identityPriv = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: idBytes) else {
            throw CIGError.noKeys
        }
        let accountID = await MainActor.run { AccountManager.shared.activeAccountID }
        // ⚠⚠ D1: never our home number, on either road. An empty name, or one
        // that carries the number (`user-<uin>`, the fallback a recovery with
        // no profile writes), goes out as a neutral word instead.
        let homeUins = await MainActor.run { [AuthService.shared.ownUIN].compactMap { $0 } }
        let wireNickname = GuestNickname.wire(nickname, homeUins: homeUins)

        let outcome: (creds: Multihome.Credentials, carriedNickname: Bool)
        switch (await guestPath(host: h), groupId) {
        case (.guest, let gid?):
            outcome = try await joinAsGuest(
                host: h, groupId: gid, nickname: wireNickname,
                signingPriv: signingPriv, identityPriv: identityPriv
            )
        case (.guest, nil):
            // No room, no mint (spec 12.2): a caller without a room only takes
            // back a copy that already exists.
            guard let recovered = try await recoverCopy(host: h, signingPriv: signingPriv) else {
                throw CIGError.refused(status: 404, code: "identity_not_found")
            }
            outcome = (recovered, false)
        case (.legacy, _):
            outcome = try await joinLegacy(
                host: h, nickname: wireNickname, signingPriv: signingPriv, identityPriv: identityPriv
            )
        }
        let creds = outcome.creds

        // Every request above was a suspension point. A switch, a decoy or a
        // burn that landed in between owns the store now: the copy stays on
        // the island (the next tap takes it back by recover), but its token is
        // not written into somebody else's list.
        let currentAccount = await MainActor.run { AccountManager.shared.activeAccountID }
        let decoyNow = await decoyOrLocked()
        if currentAccount != accountID || decoyNow || BurnCascade.isBurning { throw CIGError.offline }

        let v = VisitedIslandsStore.Visited(
            host: h, uin: creds.uin, jwt: creds.token, addedAt: Date(), guest: creds.guest
        )
        VisitedIslandsStore.shared.save(v)
        // A row that already existed carries whatever name it was registered or
        // owner-added under, possibly long ago, and nothing on that island
        // ever refreshes it. Send the current one once, now, so a stale name
        // corrects itself on joining. A fresh row already carried it.
        // Detached and best-effort: the join must not wait on a cosmetic write.
        if !outcome.carriedNickname {
            // Only a real name: `Guest` must not overwrite the one the row has.
            if let nick = GuestNickname.usable(nickname, homeUins: homeUins) {
                Task { _ = await putNickname(host: h, jwt: creds.token, nickname: nick) }
            } else {
                // Nothing of ours to send, so that row is still called whatever
                // it was made with, and before D1 that was our home number
                // (E6).
                Task { await repairLegacyNickname(host: h, uin: creds.uin, jwt: creds.token) }
            }
        }
        return v
    }

    /// Spec 12.1 `decideGuestPath`, asked fresh from `host`'s own
    /// `/server/info`. Only ever called from an explicit tap (the §5c privacy
    /// rule: seeing a link never touches an island). Unreachable, not 2xx, or
    /// a body that does not say exactly `true` are all legacy.
    static func guestPath(host: String) async -> GuestPath {
        guard let url = URL(string: "https://\(host)/server/info") else { return .legacy }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        AccessTokenStore.stamp(&req)   // closed-island gate (foreign host)
        guard let (data, resp) = try? await IslandHTTP.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return .legacy }
        return GuestPath.decide(serverInfo: data)
    }

    /// `Multihome.recoverOn` with its rotated refusal folded into ours. Nil
    /// only for `identity_not_found`.
    private static func recoverCopy(
        host: String,
        signingPriv: Curve25519.Signing.PrivateKey
    ) async throws -> Multihome.Credentials? {
        do {
            return try await Multihome.recoverOn(host: host, signingPriv: signingPriv)
        } catch Multihome.IdentityRefusal.rotated(_) {
            throw CIGError.rotated
        }
    }

    /// The guest road: `/auth/guest/challenge`, then `/auth/guest` with the
    /// `rcq-guest-v1` proof (spec 4). What happens after a refusal is
    /// `GuestJoinStep`, driven case by case by `Tools/GuestProofCheck`.
    /// `carriedNickname` is false when the key landed on a row that existed.
    private static func joinAsGuest(
        host h: String,
        groupId: Int,
        nickname: String,
        signingPriv: Curve25519.Signing.PrivateKey,
        identityPriv: Curve25519.KeyAgreement.PrivateKey
    ) async throws -> (creds: Multihome.Credentials, carriedNickname: Bool) {
        struct ChallengeOut: Decodable { let challenge: String }
        struct GuestOut: Decodable { let uin: Int; let token: String; let guest: Bool; let created: Bool }
        let sk = signingPriv.publicKey.rawRepresentation
        let ik = identityPriv.publicKey.rawRepresentation
        var retried = false
        while true {
            let refusal: IslandRefusal?
            do {
                let chal: ChallengeOut = try await postJSON(
                    "https://\(h)/auth/guest/challenge",
                    json: ["signing_key": GuestProof.canonicalKey(sk)], jwt: nil
                )
                // Signed over the SAME host string the body carries, which the
                // island canonicalises the same way before it verifies.
                guard let bytes = GuestProof.proofBytes(
                    host: h, groupId: groupId, identityKey: ik, signingKey: sk, challenge: chal.challenge
                ) else { throw CIGError.refused(status: 0, code: nil) }
                let signature = try signingPriv.signature(for: bytes)
                let body = GuestProof.requestBody(
                    host: h, groupId: groupId, nickname: nickname,
                    identityKey: ik, signingKey: sk, challenge: chal.challenge, signature: signature
                )
                let out: GuestOut = try await postJSON(
                    "https://\(h)/auth/guest", data: try JSONSerialization.data(withJSONObject: body), jwt: nil
                )
                return (Multihome.Credentials(uin: out.uin, token: out.token, guest: out.guest), out.created)
            } catch CIGError.refused(let status, let code) {
                refusal = IslandRefusal(status: status, code: code)
            } catch {
                // No answer, or a 2xx that did not decode: neither says no.
                refusal = nil
            }
            switch GuestJoinStep.after(refusal, retried: retried) {
            case .retryWithFreshChallenge:
                retried = true
            case .rotated:
                throw CIGError.rotated
            case .legacy:
                return try await joinLegacy(
                    host: h, nickname: nickname, signingPriv: signingPriv, identityPriv: identityPriv
                )
            case .recoverFallback:
                // One recover-first attempt: a copy that exists still gets its
                // token while guest admission is having a bad moment. Its own
                // failures say less than the answer that brought us here,
                // except a retired key, which is the rotated flow (D2).
                do {
                    if let recovered = try await recoverCopy(host: h, signingPriv: signingPriv) {
                        return (recovered, false)
                    }
                } catch CIGError.rotated {
                    throw CIGError.rotated
                } catch {}
                if let refusal { throw CIGError.refused(status: refusal.status, code: refusal.code) }
                throw CIGError.unreachable
            case .refused(let r):
                throw CIGError.refused(status: r.status, code: r.code)
            }
        }
    }

    /// The legacy road, for every island that does not advertise
    /// `guest_accounts_v1`: recover-first, then `/auth/register`.
    ///
    /// ⚠ The register challenge and its signature go along now (spec 12.1).
    /// Without them the island treats the registration as unproven, and a
    /// later residency on that island could not convert this row in place. An
    /// island too old for the challenge endpoint gets the plain body, as
    /// before. There is never a `desired_uin` here: a copy is not our number.
    private static func joinLegacy(
        host h: String,
        nickname: String,
        signingPriv: Curve25519.Signing.PrivateKey,
        identityPriv: Curve25519.KeyAgreement.PrivateKey
    ) async throws -> (creds: Multihome.Credentials, carriedNickname: Bool) {
        if let recovered = try await recoverCopy(host: h, signingPriv: signingPriv) {
            return (recovered, false)
        }
        struct ChallengeOut: Decodable { let challenge: String }
        let sk = signingPriv.publicKey.rawRepresentation.base64EncodedString()
        var challenge: String?
        var signature: String?
        if let chal: ChallengeOut = try? await postJSON(
            "https://\(h)/auth/register/challenge", json: ["signing_key": sk], jwt: nil
        ) {
            challenge = chal.challenge
            signature = try? RecoveryPhrase.signChallenge(signingPrivate: signingPriv, challenge: chal.challenge)
        }
        let creds: Multihome.Credentials = try await postJSON(
            "https://\(h)/auth/register",
            json: LegacyGuestRegister.body(
                nickname: nickname,
                identityKey: identityPriv.publicKey.rawRepresentation.base64EncodedString(),
                signingKey: sk,
                challenge: challenge,
                signature: signature
            ),
            jwt: nil
        )
        return (creds, true)
    }

    // MARK: nickname on this account's copies (#985(2))

    /// Push the nickname to every island in this account's OWN visited and
    /// backup stores, with that island's own token.
    ///
    /// ⚠ Nothing else ever reaches them. `PUT /users/me` on the home island
    /// updates only the home row, and its `contact_renamed` goes only to
    /// contacts on that island; §5e reaches accepted cross-island contacts
    /// only. So a room on another island kept showing the name our copy there
    /// was registered with, for good. Islands talk to no island by design,
    /// which leaves the client that holds a token for each copy as the only
    /// party able to repeat the rename.
    ///
    /// Only the nickname: that island already shows it to the room, so
    /// nothing new is disclosed. Only islands this account's own stores hold,
    /// never one learned from a peer. Best-effort per island: a 401 re-mints
    /// the token through the recover handshake once, anything else waits for
    /// the next rename.
    @MainActor
    static func pushNicknameToCopies(_ nickname: String) async {
        // The decoy identity must never speak for the real one.
        if PanicPINService.shared.isDecoy || PanicPINService.shared.isLocked { return }
        if BurnCascade.isBurning { return }
        // D1: a name that carries our home number never reaches a copy.
        guard let nick = GuestNickname.usable(
            nickname, homeUins: [AuthService.shared.ownUIN].compactMap { $0 }
        ) else { return }
        // Every island below is a round trip, and a switch can land between
        // them; the refreshes write into whichever account's store is bound.
        let accountID = AccountManager.shared.activeAccountID
        func stillSameAccount() -> Bool { AccountManager.shared.activeAccountID == accountID }

        for v in VisitedIslandsStore.shared.list() where !Multihome.isOwnHost(v.host) {
            let code = await putNickname(host: v.host, jwt: v.jwt, nickname: nick)
            guard stillSameAccount() else { return }
            if code == 401, let fresh = await refreshGuest(host: v.host) {
                guard stillSameAccount() else { return }
                _ = await putNickname(host: v.host, jwt: fresh.jwt, nickname: nick)
            }
        }

        guard let me = AuthService.shared.ownUIN else { return }
        let signingPriv = KeychainStore.data(KeychainStore.Keys.signingPriv)
            .flatMap { try? Curve25519.Signing.PrivateKey(rawRepresentation: $0) }
        for home in MultihomeStore.shared.list(ownUin: me) where !Multihome.isOwnHost(home.host) {
            let code = await putNickname(host: home.host, jwt: home.jwt, nickname: nick)
            guard stillSameAccount() else { return }
            guard code == 401, let signingPriv,
                  let fresh = try? await Multihome.recoverOn(host: home.host, signingPriv: signingPriv)
            else { continue }
            guard stillSameAccount() else { return }
            MultihomeStore.shared.updateCreds(ownUin: me, host: home.host, uin: fresh.uin, jwt: fresh.token)
            _ = await putNickname(host: home.host, jwt: fresh.token, nickname: nick)
        }
    }

    /// `PUT /users/me` with the nickname alone on `host`. Returns the HTTP
    /// status, 0 when the island could not be reached.
    private static func putNickname(host: String, jwt: String, nickname: String) async -> Int {
        guard let url = URL(string: "https://\(host)/users/me"),
              let body = try? JSONSerialization.data(withJSONObject: ["nickname": nickname])
        else { return 0 }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        req.httpBody = body
        AccessTokenStore.stamp(&req)   // closed-island gate (foreign host)
        guard let (_, resp) = try? await IslandHTTP.data(for: req) else { return 0 }
        return (resp as? HTTPURLResponse)?.statusCode ?? 0
    }

    /// Per island, per account: this copy's legacy name has been looked at.
    private static let nicknameRepairKey = "rcq.guest.nickrepair.v1"

    /// Repair a copy still named `user-<our home number>` (decision E6, 16.09).
    ///
    /// Before D1 existed, a copy on another island was registered under
    /// `user-<uin>` whenever this device had no profile name to send, and
    /// nothing on that island ever rewrites a name. So the one thing a guest
    /// copy exists NOT to tell an island is sitting in its roster, in front of
    /// every member of every room the copy is in. On the first sign-in after
    /// this build, the name that island holds for our row is read once and, if
    /// it spells our number, replaced with the neutral word.
    ///
    /// ⚠⚠ Never on a BACKUP HOME. There the number is published on purpose:
    /// the signed home record names that island and our uin on it, and senders
    /// deposit to that number. Renaming it hides nothing and only makes the
    /// mailbox harder for its owner to recognise.
    ///
    /// Once per island per account whatever the answer, so somebody who named
    /// their copy something with digits in it is not corrected twice. A PUT
    /// that failed is left for the next sign-in.
    static func repairLegacyNickname(host: String, uin: Int, jwt: String) async {
        struct SelfCard: Decodable { let nickname: String? }
        guard !BurnCascade.isBurning, !(await decoyOrLocked()) else { return }
        guard let h = Multihome.normalizeHost(host), !Multihome.isOwnHost(h) else { return }
        let ownUin = await MainActor.run { AuthService.shared.ownUIN }
        guard let me = ownUin, me > 0 else { return }
        if MultihomeStore.shared.list(ownUin: me).contains(where: { $0.host.lowercased() == h }) { return }
        let key = "\(nicknameRepairKey).\(me).\(h)"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        // The island serves the self view to a guest session (spec 6.2); every
        // other row on it is none of our business and is not asked for.
        guard let card: SelfCard = try? await getJSON("https://\(h)/users/\(uin)/info", jwt: jwt) else { return }
        let remote = (card.nickname ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // `usable` is nil exactly when the name carries one of our home numbers
        // as a digit run of its own, which is what `user-<uin>` is.
        if !remote.isEmpty, GuestNickname.usable(remote, homeUins: [me]) == nil {
            let code = await putNickname(host: h, jwt: jwt, nickname: GuestNickname.neutral)
            guard (200..<300).contains(code) else { return }
        }
        UserDefaults.standard.set(true, forKey: key)
    }

    /// Refresh an expired guest jwt via the recover handshake. Returns the
    /// updated entry or nil.
    static func refreshGuest(host: String) async -> VisitedIslandsStore.Visited? {
        if case .minted(let entry) = await refreshGuestOutcome(host: host) { return entry }
        return nil
    }

    /// How a re-mint ended, for a caller that has to tell a RETIRED KEY from
    /// every other failure (F2, 16.09).
    ///
    /// `refreshGuest` collapses the two into nil, which is all a caller that
    /// simply gives up needs. A caller that PRINTS something needs more: a
    /// retired key has already opened the account's rotated-elsewhere notice by
    /// the time it is asked, and a sentence beside that notice tells one
    /// refusal twice.
    enum GuestRefresh {
        case minted(VisitedIslandsStore.Visited)
        /// D2: the copy's island retired this key, and the notice is up.
        case rotated
        /// Mid-burn, under the decoy, no keys on file, or the island said no.
        case failed
    }

    static func refreshGuestOutcome(host: String) async -> GuestRefresh {
        // Mid-burn a recover could hand back a token for a copy the burn is
        // deleting, and the write below would keep it on disk.
        guard !BurnCascade.isBurning else { return .failed }
        // The decoy never proves the real key to a copy's island.
        guard !(await decoyOrLocked()) else { return .failed }
        guard let sigBytes = KeychainStore.data(KeychainStore.Keys.signingPriv),
              let signingPriv = try? Curve25519.Signing.PrivateKey(rawRepresentation: sigBytes)
        else { return .failed }
        let recovered: Multihome.Credentials?
        do {
            recovered = try await Multihome.recoverOn(host: host, signingPriv: signingPriv)
        } catch Multihome.IdentityRefusal.rotated(_) {
            // D2: the copy's island retired this key. The account's
            // rotated-elsewhere notice, never a wipe of anything.
            await announceRotatedElsewhere()
            return .rotated
        } catch {
            return .failed
        }
        guard let c = recovered else { return .failed }
        VisitedIslandsStore.shared.updateCreds(host: host, uin: c.uin, jwt: c.token, guest: c.guest)
        // A proven sign-in to that island, which is the other moment the legacy
        // name gets repaired if it is still ours to repair (E6).
        Task { await repairLegacyNickname(host: host, uin: c.uin, jwt: c.token) }
        guard let entry = VisitedIslandsStore.shared.get(host: host) else { return .failed }
        return .minted(entry)
    }

    /// `POST /auth/guest/settle` on a VISITED island (spec 9.1, decision D7):
    /// the copy we hold there becomes a resident of it, keeping its number, its
    /// rooms and its token, because guestness was never in the token.
    ///
    /// `code` is an entry voucher or an invite; an island whose door is open
    /// settles with none. A stale token is re-minted once, as every other call
    /// on a copy does. Throws `CIGError.refused` with the island's own code,
    /// which the sheet turns into a sentence (`GuestSentence.settle`).
    static func settleGuest(host: String, code: String?) async throws {
        struct Out: Decodable { let uin: Int }
        if BurnCascade.isBurning { throw CIGError.burning }
        if await decoyOrLocked() { throw CIGError.offline }
        guard let h = Multihome.normalizeHost(host),
              let visited = VisitedIslandsStore.shared.get(host: h) else { throw CIGError.unreachable }
        var body: [String: Any] = [:]
        let trimmed = (code ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { body["code"] = trimmed }
        let payload = try JSONSerialization.data(withJSONObject: body)
        var jwt = visited.jwt
        var reminted = false
        while true {
            do {
                let _: Out = try await postJSON("https://\(h)/auth/guest/settle", data: payload, jwt: jwt)
                VisitedIslandsStore.shared.markSettled(host: h)
                return
            } catch CIGError.refused(401, let code401) {
                guard !reminted else { throw CIGError.refused(status: 401, code: code401) }
                switch await refreshGuestOutcome(host: h) {
                case .minted(let fresh):
                    reminted = true
                    jwt = fresh.jwt
                case .rotated:
                    // ⚠ NOT the plain 401 (F2, 16.09). The re-mint just opened
                    // the account's rotated-elsewhere notice, and the sheet has
                    // to say NOTHING beside it. Rethrowing the 401 read as an
                    // ordinary failure, whose code this table does not know, so
                    // the sheet painted the generic "residency.error" under the
                    // notice: one refusal told twice.
                    throw CIGError.rotated
                case .failed:
                    throw CIGError.refused(status: 401, code: code401)
                }
            }
        }
    }

    /// Creds for a foreign host: a visited/guest island OR one of our BACKUP
    /// islands (multihome). A cross-island group can be hosted on EITHER — both
    /// stores hold this identity's (uin, jwt) for that host. Without the backup
    /// fallback, a group on your backup island has no roster/name and its sends
    /// misroute to your own island (the "Группа / 0 участников / не дошло" bug).
    static func foreignCreds(host: String, ownUIN: Int?) -> (uin: Int, jwt: String)? {
        if let v = VisitedIslandsStore.shared.get(host: host) { return (v.uin, v.jwt) }
        guard let me = ownUIN else { return nil }
        if let h = MultihomeStore.shared.list(ownUin: me).first(where: { $0.host.lowercased() == host.lowercased() }) {
            return (h.uin, h.jwt)
        }
        return nil
    }

    /// Groups we joined on `host`, ids rewritten to the local alias + host
    /// stamped. A 401 refreshes the guest jwt once (visited islands only; a
    /// backup island's token is long-lived + refreshed by the backup drain).
    /// [] on any failure.
    static func guestGroups(host: String, ownUIN: Int?) async -> [RCQGroup] {
        guard !(await decoyOrLocked()) else { return [] }
        guard let creds = foreignCreds(host: host, ownUIN: ownUIN) else { return [] }
        func fetch(_ jwt: String) async throws -> [RCQGroup] {
            try await getJSON("https://\(host)/groups", jwt: jwt)
        }
        do {
            var groups: [RCQGroup]
            do {
                groups = try await fetch(creds.jwt)
            } catch CIGError.refused(401, _) {
                guard let fresh = await refreshGuest(host: host) else { return [] }
                groups = try await fetch(fresh.jwt)
            }
            return groups.map { g in
                var g = g
                g.id = VisitedIslandsStore.shared.aliasFor(host: host, remoteId: g.id)
                g.host = host
                return g
            }
        } catch {
            return []
        }
    }

    /// One room on `host` with its roster, for the one decision that must not
    /// be made on a roster nobody fetched: the last-resident warning before a
    /// leave (spec 8.1, decision E4). The room keeps its local alias id here;
    /// the request uses its id THERE.
    ///
    /// One request with the copy's own token, one 401 re-mint. Nil on anything
    /// else, and the caller reads nil as "could not tell", never as "nobody".
    static func foreignRoster(host: String, aliasID: Int) async -> RCQGroup? {
        guard !(await decoyOrLocked()) else { return nil }
        guard let ref = VisitedIslandsStore.shared.refByAlias(aliasID) else { return nil }
        let me = await MainActor.run { AuthService.shared.ownUIN }
        guard let creds = foreignCreds(host: host, ownUIN: me) else { return nil }
        func fetch(_ jwt: String) async throws -> RCQGroup {
            try await getJSON("https://\(host)/groups/\(ref.remoteId)", jwt: jwt)
        }
        do {
            var g: RCQGroup
            do {
                g = try await fetch(creds.jwt)
            } catch CIGError.refused(401, _) {
                guard let fresh = await refreshGuest(host: host) else { return nil }
                g = try await fetch(fresh.jwt)
            }
            g.id = aliasID
            g.host = host
            return g
        } catch {
            return nil
        }
    }

    /// Preview a foreign group. The invite LINK is the capability, so we read the
    /// PUBLIC card (name/avatar/member count) even on an island we haven't visited
    /// — the server's /groups/{id}/preview is optional-auth. Sends the guest token
    /// when we have one (visited), otherwise unauthenticated. So a received
    /// cross-island invite shows the real group, not a blank card.
    static func previewForeign(host: String, remoteId: Int) async -> GroupService.GroupPreview? {
        // Under the decoy the sheet draws the minimal island card instead:
        // no copy's token is sent, and the island is not asked at all.
        guard !(await decoyOrLocked()) else { return nil }
        let jwt = VisitedIslandsStore.shared.get(host: host)?.jwt
        return try? await getJSON("https://\(host)/groups/\(remoteId)/preview", jwt: jwt)
    }

    /// §5c join: a copy on the group's island (explicit user action, seeing a
    /// link never touches the island), the join there, and the group stamped
    /// with the local alias + host. A failure carries the island's code, so
    /// the join sheet can say why (`joinSentence`) instead of "couldn't load".
    ///
    /// On the guest road the island already put the copy in the room; the
    /// join then short-circuits on "already a member" and returns the room.
    static func joinForeign(host: String, remoteId: Int, nickname: String) async -> Result<RCQGroup, CIGError> {
        do {
            let v = try await ensureGuest(host: host, nickname: nickname, groupId: remoteId)
            var g: RCQGroup
            do {
                g = try await postJSON("https://\(host)/groups/\(remoteId)/join", json: [:], jwt: v.jwt)
            } catch CIGError.refused(401, _) {
                // A copy on file whose token went stale: re-mint it once.
                //
                // ⚠ The re-mint's OUTCOME, not just the token it hands back
                // (F2, 16.09). `refreshGuest` folds a RETIRED KEY and an
                // ordinary failure into the same nil, so a rotation arrived
                // here as a plain 401: the sheet painted a line no retry could
                // ever fix, and the rotated-elsewhere flow never started for
                // the one join that had actually hit it. A re-mint IS a recover
                // (`Multihome.recoverOn`), and the other clients never let a
                // recover inside the join flow answer "no copy here" for a
                // retired key either: Android's `recoverForGuest` passes
                // `rotatedIsError = true`, the web's `recoverGuestCopy` passes
                // `rotatedThrows: true`, and both rethrow it.
                switch await refreshGuestOutcome(host: host) {
                case .minted(let fresh):
                    g = try await postJSON("https://\(host)/groups/\(remoteId)/join", json: [:], jwt: fresh.jwt)
                case .rotated:
                    throw CIGError.rotated
                case .failed:
                    throw CIGError.refused(status: 401, code: nil)
                }
            }
            g.id = VisitedIslandsStore.shared.aliasFor(host: host, remoteId: remoteId)
            g.host = host
            return .success(g)
        } catch let e as CIGError {
            // D2: `identity_rotated` from `/auth/guest` or from a recover in
            // this flow starts the account's rotated-elsewhere notice. Nothing
            // is wiped, and the sheet says NOTHING beside the notice (F2).
            if isRotated(e) { await announceRotatedElsewhere() }
            return .failure(e)
        } catch {
            return .failure(.unreachable)
        }
    }

    /// The existing rotated-elsewhere flow for the ACTIVE account (the one
    /// boot and the socket's 4401 probe start): an alert, once per session,
    /// and nothing deleted. The decoy guard lives in `presentRotatedElsewhere`.
    @MainActor
    static func announceRotatedElsewhere() {
        guard let uin = AuthService.shared.ownUIN else { return }
        AppState.shared.presentRotatedElsewhere(uin: uin)
    }

    /// A retired key, in either spelling it can arrive in: the typed case the
    /// guest and recover paths throw, and a raw `404 identity_rotated` from any
    /// other call on that island. Both mean the rotated-elsewhere notice and
    /// nothing else on screen (F2, 16.09).
    static func isRotated(_ error: CIGError) -> Bool {
        if case .rotated = error { return true }
        if case .refused(_, let code) = error, code == "identity_rotated" { return true }
        return false
    }

    /// The sentence a failed join puts on the sheet, or nil for NOTHING AT ALL.
    /// Never the island's own text.
    ///
    /// ⚠ Nil does not mean "use the generic line" any more (F2, 16.09): the
    /// generic line is folded in here, so the one answer that comes back nil is
    /// the one that must stay silent. A retired key has already opened the
    /// account's rotated-elsewhere notice by the time this is asked
    /// (`joinForeign`), and a sentence in the sheet beside that notice tells
    /// one refusal twice. Android returns null at the same point and the web
    /// returns before it sets an error.
    @MainActor
    static func joinSentence(_ error: CIGError, host: String) -> String? {
        switch error {
        case .rotated:
            return nil
        case .refused(let status, let code):
            let refusal = IslandRefusal(status: status, code: code)
            if GuestSentence.noticeOnly(refusal) { return nil }
            let key = GuestSentence.join(refusal) ?? GuestSentence.joinGeneric
            return String(format: key.localized, host)
        case .noKeys, .burning, .offline, .unreachable:
            // Nothing was refused: offline, mid-burn, or under the decoy. The
            // sheet's own line, which is what it printed for these before.
            return String(format: GuestSentence.joinGeneric.localized, host)
        }
    }

    /// An owner-add the island refused, with the `scope` that
    /// `guest_add_limit` carries.
    struct GuestAddRefused: Error {
        let refusal: IslandRefusal
    }

    /// Spec 2026-09-15, section 5, for a room on ANOTHER island: `POST
    /// /groups/{remoteId}/guests` there with our own token for that island and
    /// the contact's PUBLIC card. The island resolves the key to the row it
    /// already has or mints an unclaimed seat with its membership. No token for
    /// the contact's copy exists anywhere, and none reaches this device.
    /// Returns the uin the key landed on there.
    static func addGuestMember(
        host: String,
        remoteId: Int,
        jwt: String,
        identityKey: String,
        signingKey: String,
        nickname: String
    ) async throws -> Int {
        struct Out: Decodable { let added_uin: Int }
        guard let url = URL(string: "https://\(host)/groups/\(remoteId)/guests") else {
            throw GuestAddRefused(refusal: IslandRefusal(status: 0, code: nil))
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "identity_key": identityKey,
            "signing_key": signingKey,
            "nickname": nickname,
        ])
        AccessTokenStore.stamp(&req)   // closed-island gate (foreign host)
        let (data, resp) = try await IslandHTTP.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw GuestAddRefused(refusal: IslandRefusal.parse(status: status, body: data))
        }
        return try decoder.decode(Out.self, from: data).added_uin
    }

    /// §5c owner-initiated group add: the local uin bound to a signing key on
    /// `host`, or nil when no account there has it yet. Open inverse key card.
    static func resolveUinForKey(host: String, signingKeyB64: String) async -> Int? {
        guard let enc = signingKeyB64.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://\(host)/federation/uin-for-key?signing_key=\(enc)") else { return nil }
        var ukReq = URLRequest(url: url)
        AccessTokenStore.stamp(&ukReq)   // closed-island gate (foreign host)
        guard let (data, resp) = try? await IslandHTTP.data(for: ukReq),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        struct Out: Decodable { let uin: Int }
        return (try? decoder.decode(Out.self, from: data))?.uin
    }

    /// §5c LEGACY owner-add, on an island without `guest_accounts_v1`: register
    /// a contact's PUBLIC keys on `host` so the add has a local uin for the
    /// roster. The contact later recovers the SAME uin (recover-first is keyed
    /// by the signing key). Throws `CIGError.refused` with the island's code (a
    /// shut door answers `entry_required` / `invite_required`), or
    /// `.unreachable`.
    ///
    /// ⚠ `nickname` must already be `GuestNickname.wire`: never `user-<uin>`
    /// with the contact's home number in it (D1).
    static func registerForeignKeys(host: String, identityKey: String, signingKey: String, nickname: String) async throws -> Int {
        struct Out: Decodable { let uin: Int }
        do {
            let out: Out = try await postJSON(
                "https://\(host)/auth/register",
                json: ["nickname": nickname, "identity_key": identityKey, "signing_key": signingKey],
                jwt: nil
            )
            return out.uin
        } catch let e as CIGError {
            throw e
        } catch {
            throw CIGError.unreachable
        }
    }

    /// Deposit a group fan-out into the group's island. The deposit endpoint is
    /// the open unauthenticated path (same as 1:1), so no jwt needed.
    struct GroupEntry: Encodable { let to_uin: Int; let payload: String }
    static func groupSealedDeposit(host: String, remoteId: Int, envelopeType: String, payloads: [GroupEntry]) async throws {
        // Stage 2: `cls` mirrors the island's `_cls_for`; additive, and an older
        // host island simply ignores the field it does not know.
        struct Body: Encodable { let group_id: Int; let envelope_type: String; let cls: Int; let payloads: [GroupEntry] }
        let body = try JSONEncoder().encode(Body(group_id: remoteId, envelope_type: envelopeType, cls: rcqMessageClass(envelopeType), payloads: payloads))
        guard let url = URL(string: "https://\(host)/messages/group-sealed") else { throw CIGError.refused(status: 0, code: nil) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        AccessTokenStore.stamp(&req)   // closed-island gate (foreign host)
        let (_, resp) = try await IslandHTTP.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw CIGError.refused(status: code, code: nil) }
    }

    /// Drain the guest mailbox on every visited island (the receive path — the
    /// host island spools group fan-out there). Group rows file under the local
    /// alias; a stray 1:1 row routes through the normal ingest, whose
    /// cross-island consent gate quarantines unknown senders. Mirrors the
    /// multihome backup drain.
    @MainActor
    static func drainVisitedQueues() async {
        // Stage 2: `cls`/`seq` served alongside the legacy fields; optional so an
        // older host island still decodes, and read only for future ordering. The
        // guest mailbox is drained on the server's own fetch cursor, not on `seq`.
        struct Row: Decodable { let envelope_type: String; let payload: String; let group_id: Int?; let cls: Int?; let seq: Int? }
        // Whose guest mailboxes these are. One pass here can span several
        // islands and as many round trips, so it outlives an account switch
        // easily, and `ingest` writes into whatever per-account store `bind`
        // last installed rather than asking whose row it is holding. Without
        // this, a §5f `contactreq` read from the outgoing account's guest
        // mailbox files as a pending request under the incoming account
        // (founder, 30.08). Same shape as the main drain in `MessageService`.
        let accountID = AccountManager.shared.activeAccountID
        if BurnCascade.isBurning { return }
        for v in VisitedIslandsStore.shared.list() {
            var jwt = v.jwt
            var rows: [Row]? = try? await getJSON("https://\(v.host)/messages/queue", jwt: jwt)
            if rows == nil, let fresh = await refreshGuest(host: v.host) {
                jwt = fresh.jwt
                rows = try? await getJSON("https://\(v.host)/messages/queue", jwt: jwt)
            }
            guard let rows else { continue }
            // Every fetch above is a suspension point. Checked here rather
            // than at the top of the loop only: the switch is far likelier to
            // land inside the network call than between two of them.
            guard AccountManager.shared.activeAccountID == accountID,
                  !PanicPINService.shared.isLocked,
                  !PanicPINService.shared.isDecoy,
                  !BurnCascade.isBurning
            else { return }
            for r in rows {
                let gid = r.group_id.map { VisitedIslandsStore.shared.aliasFor(host: v.host, remoteId: $0) }
                let packet = WebSocketService.EnvelopePacket(
                    type: r.envelope_type, payload: r.payload, serverTime: Date(),
                    offline: true, groupID: gid
                )
                _ = MessageService.shared.ingest(envelope: packet)
            }
            // Stage 5: a room lives on its island, so whether it is drained
            // from a log is that island's call, not ours. Only a host that
            // advertises `group_log` gets the fetch; the queue above stays
            // the whole receive path for every other one.
            if await hostKeepsGroupLog(v.host) {
                guard AccountManager.shared.activeAccountID == accountID else { return }
                await drainGroupLog(host: v.host, jwt: jwt)
            }
            // F1: contact requests addressed to our copy on this island. Its
            // own schedule decides (every 5 min or slower), so most passes of
            // this 30 s loop end here without a request. It re-checks the
            // account, the decoy, the lock and the burn after every await.
            guard AccountManager.shared.activeAccountID == accountID else { return }
            await CrossIslandPendingPoll.pollIfDue(host: v.host, jwt: jwt)
        }
    }

    // MARK: Stage 5: the room log on a visited island

    /// Per-host answer to "does this island keep a log per room", read off
    /// its /server/info. A yes is kept for the life of the process; a no is
    /// asked again after an hour, so an island that upgrades while we run
    /// is picked up without a relaunch. Unreachable counts as no: the queue
    /// drain above already failed for it in that case, and the next pass
    /// asks again. Shared with the backup-home drain in `Multihome`: a room
    /// can live on a backup home as well as on a visited island.
    private static var groupLogByHost: [String: (value: Bool, at: Date)] = [:]

    static func hostKeepsGroupLog(_ host: String) async -> Bool {
        let key = host.lowercased()
        if let known = groupLogByHost[key], known.value || Date().timeIntervalSince(known.at) < 3600 {
            return known.value
        }
        let info: ServerInfoResponse? = try? await getJSON("https://\(host)/server/info", jwt: nil)
        let value = info?.capabilities.groupLog ?? false
        groupLogByHost[key] = (value, Date())
        return value
    }

    /// Drain our room logs on `host` (a visited island, or a backup home
    /// that hosts a room we are in) and ack what landed, the same loop as
    /// `MessageService.drainOwnGroupLogIfAdvertised` on our own island: rows
    /// go through the one ingest path filed under the local alias, the ack
    /// is keyed by the island's own room id, and the loop only continues
    /// while an ack moved a cursor and landed (the fetch reads from the
    /// island's cursor, so a pass that acked nothing, or whose ack failed,
    /// would read the same rows again). Called right after the host's
    /// legacy queue was read, never beside it.
    @MainActor
    static func drainGroupLog(host: String, jwt: String) async {
        struct FetchIn: Encodable { let limit: Int }
        struct FetchOut: Decodable {
            let rows: [MessageService.GroupLogRow]
            // Keyed by the room id as a string; see the own-island drain.
            let cursors: [String: Int]
            let more: Bool
        }
        struct AckRoom: Encodable { let gid: Int; let upto: Int }
        struct AckIn: Encodable { let rooms: [AckRoom] }
        struct AckOut: Decodable { let deleted: Int }
        let drain = MessageService.shared.beginGroupLogDrain()
        var passes = 0
        repeat {
            passes += 1
            guard let out: FetchOut = try? await postJSON(
                "https://\(host)/messages/group-log/fetch", body: FetchIn(limit: 500), jwt: jwt
            ) else { return }
            // On the one drain chain, not beside it. This walk runs off
            // `Multihome`'s 30 s poll, so it lands in the middle of the queue
            // drain as often as not, and both walks share the one page-batch
            // slot in MessageService: the second to arrive silently piles its
            // unread counts, badge bumps and delivered receipts into the
            // first's batch, then acks its rows to the island anyway. The
            // island deletes them; the bookkeeping goes wherever the other
            // walk's batch went. Only the ingest is chained — the fetch and
            // the ack above stay off it, so a slow island cannot hold the
            // queue drain up.
            let got = await MessageService.shared.serialisedDrain {
                await MessageService.shared.ingestGroupLogRows(out.rows, drain: drain) {
                    VisitedIslandsStore.shared.aliasFor(host: host, remoteId: $0)
                }
            }
            let acks = got.upto.filter { $0.value > (out.cursors[String($0.key)] ?? 0) }
            guard !acks.isEmpty else { return }
            let acked: AckOut? = try? await postJSON(
                "https://\(host)/messages/group-log/ack",
                body: AckIn(rooms: acks.map { AckRoom(gid: $0.key, upto: $0.value) }), jwt: jwt
            )
            guard acked != nil, out.more, passes < 20 else { return }
        } while true
    }

    // MARK: raw HTTP

    private static func getJSON<T: Decodable>(_ urlString: String, jwt: String?) async throws -> T {
        guard let url = URL(string: urlString) else { throw CIGError.refused(status: 0, code: nil) }
        var req = URLRequest(url: url)
        if let jwt { req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization") }
        AccessTokenStore.stamp(&req)   // closed-island gate (foreign host)
        let (data, resp) = try await IslandHTTP.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw CIGError.refused(status: code, code: IslandRefusal.parse(status: code, body: data).code)
        }
        return try decoder.decode(T.self, from: data)
    }

    private static func postJSON<T: Decodable>(_ urlString: String, json: [String: String], jwt: String?) async throws -> T {
        try await postJSON(urlString, data: try JSONSerialization.data(withJSONObject: json), jwt: jwt)
    }

    /// Same call with a typed body, for the shapes a flat string map cannot
    /// carry (the room-log fetch and ack nest lists and ints).
    private static func postJSON<T: Decodable>(_ urlString: String, body: Encodable, jwt: String?) async throws -> T {
        try await postJSON(urlString, data: try JSONEncoder().encode(body), jwt: jwt)
    }

    private static func postJSON<T: Decodable>(_ urlString: String, data: Data, jwt: String?) async throws -> T {
        guard let url = URL(string: urlString) else { throw CIGError.refused(status: 0, code: nil) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let jwt { req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization") }
        req.httpBody = data
        AccessTokenStore.stamp(&req)   // closed-island gate (foreign host)
        let (data, resp) = try await IslandHTTP.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw CIGError.refused(status: code, code: IslandRefusal.parse(status: code, body: data).code)
        }
        return try decoder.decode(T.self, from: data)
    }
}

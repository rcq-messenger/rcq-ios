import Foundation

/// Taking the key to your own face off the island, for pictures set before that
/// was possible (docs/profile-key-design.md, migration phase 3).
///
/// ⚠⚠ WHY. The profile-key model only ever applied to pictures set AFTER it
/// shipped. Everything older kept the old shape: a per-upload key sitting in
/// `users.avatar_media_key`, in the same row as the number and the nickname,
/// with the ciphertext behind an unauthenticated GET on the same disk. Counted
/// on 21.09 across both production islands: of 80 pictures, 63 were still
/// openable by the island. Nothing was going to fix those on its own, because
/// the shape only changes when somebody happens to set a NEW picture, and most
/// people set one once.
///
/// So: fetch my own blob, open it with the key the island still holds, re-seal
/// it under my profile key, upload it as a new id and hand the island the id
/// ALONE — which is what makes the island drop the key column.
///
/// ⚠ Safe to interrupt. Nothing changes until the PUT lands; the old id and the
/// old blob keep working until then, so a failure anywhere leaves the picture
/// exactly as it was.
///
/// ⚠ Safe to race with another device: both seal under the SAME profile key
/// (both read it from the vault), so whichever id lands last is a blob every
/// contact can open with the key they already hold.
@MainActor
enum AvatarMigration {

    private static let triedKey = "rcq.avatarMigration.lastTry"
    private static let retry: TimeInterval = 24 * 60 * 60
    private static var triedThisSession = false

    /// Move my picture to the profile-key shape if it is still in the old one.
    static func runIfNeeded() async {
        guard !triedThisSession else { return }
        triedThisSession = true
        // ⚠ Never under duress: this reads and republishes the REAL account's
        // picture, and the decoy session must not touch it.
        guard !PanicPINService.shared.isDecoy else { return }
        let last = UserDefaults.standard.double(forKey: triedKey)
        if last > 0, Date().timeIntervalSince1970 - last < retry { return }

        guard let uin = AuthService.shared.ownUIN,
              let me: UserProfile = try? await APIClient.shared.request("GET", "/users/\(uin)/info"),
              let oldID = me.avatarMediaID, !oldID.isEmpty,
              // No key means it is already sealed under the profile key:
              // nothing to do, and nothing to remember either.
              let oldKey = me.avatarMediaKey, !oldKey.isEmpty
        else { return }

        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: triedKey)

        guard let plain = await MediaService.shared.fetchDecrypted(mediaID: oldID, keyBase64: oldKey) else { return }
        // ⚠ This MINTS when the account has no profile key yet, and that is
        // correct here and nowhere else: we are about to publish under it and
        // hand it to every contact in the same breath. It reads the vault
        // first, so a key a sibling install already published is adopted.
        guard let pk = await ProfileKeyService.shared.ensureMine() else { return }

        // ⚠ The raw-bytes path on purpose. Re-encoding would change the
        // picture; a migration must move the same bytes under a new key.
        guard let res = try? await MediaService.shared.uploadGIF(data: plain, under: pk) else { return }

        struct Body: Encodable { let avatar_media_id: String }
        // The id ALONE: that is what makes the island drop the key it holds.
        guard let back: UserProfile = try? await APIClient.shared.request(
            "PUT", "/users/me", body: Body(avatar_media_id: res.mediaID)
        ) else { return }
        // ⚠⚠ An island older than the profile-key feature parses the request
        // with Pydantic's default extra='ignore': it drops the field, commits
        // nothing and answers 200. On such an island this must be a no-op, not
        // a picture pointing at a blob nobody was told about.
        guard back.avatarMediaID == res.mediaID else { return }

        PresenceService.shared.setOwnAvatar(id: res.mediaID, key: res.keyBase64)
        await ProfileKeyService.shared.fanOut(keyB64: res.keyBase64)
        // §5e: a cross-island contact reads the picture from THEIR island, so
        // the new blob goes there and the key rides the sealed snapshot.
        Task { await CrossIslandSender.broadcastProfile() }
    }
}

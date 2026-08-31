import Foundation

/// Minting, mirroring and handing out MY profile key — the key my avatar blob
/// is sealed under (docs/profile-key-design.md).
///
/// The island no longer receives it. Until this it sat in
/// `users.avatar_media_key`, in the same row as the uin and the nickname, with
/// the ciphertext on the same disk behind an unauthenticated GET, so a seized
/// island decrypted every face it stored.
@MainActor
final class ProfileKeyService {
    static let shared = ProfileKeyService()

    /// The key to use for my picture: the local copy, else what the vault
    /// already holds, else a fresh one published to the vault.
    ///
    /// ⚠ Vault FIRST, mint second, and never overwrite a slot that already
    /// holds a key. If a phone minted its own while the browser had published
    /// one, the two installs would hand out different keys and half of one
    /// person's contacts would hold a key that opens nothing. Whoever
    /// published first wins.
    func ensureMine() async -> String? {
        if let have = ProfileKeyStore.shared.mine, !have.isEmpty { return have }
        guard !PanicPINService.shared.isDecoy,
              let ik = KeychainStore.data(KeychainStore.Keys.identityPriv) else { return nil }
        let slot = Vault.slotId(identityPriv: ik, name: Vault.profileKey)

        // 1. Adopt what a sibling install already published.
        if let read = try? await VaultClient.get(slot),
           let blob = read.blob,
           let raw = Data(base64Encoded: blob),
           let plain = try? Vault.open(identityPriv: ik, slot: slot, version: read.version, blob: raw),
           let existing = String(data: plain, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty {
            ProfileKeyStore.shared.setMine(existing)
            return existing
        }

        // 2. Nothing there: mint and publish. A 409 means somebody got in
        //    first, so re-read and adopt theirs rather than overwrite.
        var raw = Data(count: 32)
        _ = raw.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        let minted = raw.base64EncodedString()
        let base = (try? await VaultClient.get(slot))?.version ?? 0
        guard let sealed = try? Vault.seal(
            identityPriv: ik, slot: slot, version: base + 1,
            plaintext: Data(minted.utf8)
        ) else { return nil }
        let w = try? await VaultClient.put(slot, blob: sealed.base64EncodedString(), basedOn: base)
        if w?.version != nil {
            ProfileKeyStore.shared.setMine(minted)
            return minted
        }
        if let again = try? await VaultClient.get(slot),
           let blob = again.blob,
           let rawBlob = Data(base64Encoded: blob),
           let plain = try? Vault.open(identityPriv: ik, slot: slot, version: again.version, blob: rawBlob),
           let theirs = String(data: plain, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !theirs.isEmpty {
            ProfileKeyStore.shared.setMine(theirs)
            return theirs
        }
        // No vault on this island: keep the minted key locally. A picture only
        // my own devices can open is still better than refusing to set one.
        ProfileKeyStore.shared.setMine(minted)
        return minted
    }

    /// Seal the key to every contact. Best effort per peer: one unreachable
    /// contact must not cost the rest their copy — they ask with `pkeyask`.
    func fanOut(keyB64: String) async {
        let roster = ContactService.shared.contacts
        for c in roster where !c.identityKey.isEmpty {
            let bundle = PeerBundle(uin: c.uin, identityKey: c.identityKey, signingKey: c.signingKey)
            let env: Envelope = .pkey(key: keyB64)
            guard let crypto = MessageService.shared.crypto,
                  let blob = try? crypto.encrypt(envelope: env, for: bundle) else { continue }
            struct Body: Encodable { let to_uin: Int; let envelope_type: String; let cls: Int; let payload: String }
            struct Out: Decodable { let delivered: Bool; let queued: Bool }
            _ = try? await APIClient.shared.request(
                "POST", "/messages/sealed",
                body: Body(to_uin: c.uin, envelope_type: "skdm", cls: rcqMessageClass("skdm"), payload: blob),
                authenticated: false,
                retries: 1
            ) as Out
        }
    }
}

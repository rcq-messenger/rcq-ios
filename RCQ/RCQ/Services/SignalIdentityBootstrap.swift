import Foundation
import LibSignalClient
import UIKit

/// Idempotent Stage 3 bootstrap — ensures local libsignal identity,
/// signed pre-key, Kyber pre-key, and OPK pool exist and the matching
/// public material is uploaded.
///
/// ## Which slot we publish into
///
/// A libsignal session belongs to ONE PAIR of devices. The account has a
/// single PRIMARY slot (`POST /keys/bundle`, libsignal device 1) and any
/// number of secondaries (`POST /keys/devices`, ids assigned by the
/// server). Every install has to land in a slot of its own: two installs
/// sharing one slot means whichever established last owns the peer's
/// session and the other's messages arrive undecryptable.
enum SignalIdentityBootstrap {
    /// Server-side pool target. Top-up below ~25.
    static let targetOPKCount = 100
    static let topUpThreshold = 25

    /// Consecutive device lists that came back without this install's id
    /// before we believe them. See the secondary branch of `topUpIfNeeded`.
    /// The count itself lives in the store, not here: a process-lifetime
    /// counter is reset by every launch, and a bootstrap that runs once per
    /// launch would then never reach the second strike.
    private static let missingDeviceStrikesToAct = 2

    /// Throws if generation or upload fails so the caller can surface
    /// "Stage 3 not ready" — encrypt path falls back to v=1 per peer.
    static func ensureBootstrapped(ownUIN: Int) async throws {
        let stores = SignalProtocolStores.shared
        let ctx = RCQStoreContext.shared

        if let existing = try stores.loadLocalIdentity() {
            // UIN drift (local DB survived server-side wipe + re-register):
            // throw out stale libsignal state and rebootstrap.
            if existing.uin != ownUIN {
                print("[SignalBootstrap] uin drift \(existing.uin)→\(ownUIN), rebootstrapping")
                SignalProtocolDB.shared.wipe()
            } else {
                await topUpIfNeeded(ownUIN: ownUIN)
                return
            }
        }

        try await freshBootstrap(ownUIN: ownUIN, ctx: ctx)
    }

    // MARK: - upload shapes

    private struct SignedPreKeyOut: Encodable {
        let id: UInt32; let publicKey: String; let signature: String
        enum CodingKeys: String, CodingKey { case id; case publicKey = "public"; case signature }
    }
    private struct KyberPreKeyOut: Encodable {
        let id: UInt32; let publicKey: String; let signature: String
        enum CodingKeys: String, CodingKey { case id; case publicKey = "public"; case signature }
    }
    private struct OPKOut: Encodable {
        let id: UInt32; let publicKey: String
        enum CodingKeys: String, CodingKey { case id; case publicKey = "public" }
    }
    private struct BundleBody: Encodable {
        let signal_identity_key: String
        let registration_id: UInt32
        let signed_prekey: SignedPreKeyOut
        let kyber_prekey: KyberPreKeyOut
        let one_time_prekeys: [OPKOut]
    }
    /// `POST /keys/devices` — the bundle shape plus the two fields only a
    /// secondary carries.
    private struct DeviceBody: Encodable {
        let signal_identity_key: String
        let registration_id: UInt32
        let signed_prekey: SignedPreKeyOut
        let kyber_prekey: KyberPreKeyOut
        let one_time_prekeys: [OPKOut]
        let label: String
        let sealed_sender_pub: String

        init(bundle: BundleBody, label: String, sealedSenderPub: String) {
            self.signal_identity_key = bundle.signal_identity_key
            self.registration_id = bundle.registration_id
            self.signed_prekey = bundle.signed_prekey
            self.kyber_prekey = bundle.kyber_prekey
            self.one_time_prekeys = bundle.one_time_prekeys
            self.label = label
            self.sealed_sender_pub = sealedSenderPub
        }
    }
    private struct KeyStatus: Decodable {
        let has_bundle: Bool
        let one_time_prekey_count: Int
        let target_count: Int
        let signed_prekey_age_seconds: Int?
        /// Identity key currently published as PRIMARY; nil when the
        /// account has no bundle yet.
        let signal_identity_key: String?
    }

    /// Generic model name only ("iPhone", "iPad") — the user-set device
    /// name is a real name often enough that it has no business on a
    /// server that is otherwise told nothing about who we are.
    @MainActor
    private static func deviceLabel() -> String {
        return UIDevice.current.model
    }

    /// Publish [body] into whichever slot this install owns, and return the
    /// libsignal device id it now holds. Persisting that id is the caller's
    /// job — `rebootstrap` wipes the store after this returns.
    ///
    /// [currentIdentityB64] is the identity this install ALREADY HAS, which is
    /// what says whether the primary slot is ours — not [body], which on a
    /// re-key is a key nobody has seen yet. `nil` for an install with no
    /// libsignal identity behind it (first run, reinstall, restore onto a new
    /// phone), and that install CLAIMS the primary slot, occupied or not.
    ///
    /// ⚠ For an install that DOES hold an identity the status read is not
    /// advisory. `/keys/bundle` is the account's ONE primary slot, and writing
    /// to it while another install owns it replaces that install on every peer
    /// it talks to. A status call we cannot complete therefore publishes
    /// nothing and throws; the next launch retries.
    private static func publishBundle(
        _ body: BundleBody, ownUIN: Int, currentIdentityB64: String?
    ) async throws -> Int {
        // No local libsignal identity: take the primary slot without asking.
        //
        // Such an install cannot tell a live sibling apart from its own
        // previous install, whose private keys went with the app data a
        // reinstall or a new phone discarded — the local store was the only
        // place that memory lived. The two mistakes are not symmetric.
        // Standing aside leaves a DEAD identity in the slot that every sender
        // too old to fan out keeps addressing forever, with no endpoint to
        // retire it, and the only install on the phone hears none of them.
        // Taking it costs a live sibling one step: its next status check finds
        // a published key that is not its own and it re-registers itself as a
        // secondary. And we give up nothing doing it — an install with no
        // identity has no sessions to preserve.
        if currentIdentityB64 == nil {
            let _: EmptyResponse = try await APIClient.shared.request("POST", "/keys/bundle", body: body)
            return 1
        }
        let status: KeyStatus = try await APIClient.shared.request("GET", "/keys/me/status")
        // The primary slot, when the account has none yet, when it holds the
        // key this install is publishing FROM (a re-key keeps the slot: the
        // published key changes on purpose, the install holding it does not),
        // when it already holds the key we are publishing, or when the island
        // predates per-device keys (no `signal_identity_key` in the status) and
        // has nowhere else to put us — there the single slot is the only
        // behaviour there has ever been, and refusing to publish would leave us
        // unreachable over v=2.
        let slotIsOurs = status.signal_identity_key == currentIdentityB64
            || status.signal_identity_key == body.signal_identity_key
        if !status.has_bundle || status.signal_identity_key == nil || slotIsOurs {
            let _: EmptyResponse = try await APIClient.shared.request("POST", "/keys/bundle", body: body)
            return 1
        }
        guard let sealedSenderPub = try? SignalCryptoService.loadFromKeychain(ownUIN: ownUIN)?
            .bootstrapIdentity().identityKey
        else { throw SignalProtocolStoreError.noLocalIdentity }

        // Adoption is for republishing the SAME identity only. When [body]
        // carries a new one (a re-key), a row published under the old identity
        // is not what we are trying to put on the server, and returning it
        // would leave the new material unpublished while local state swaps to
        // it — every peer then talking to an identity we no longer hold.
        if let mine = currentIdentityB64, mine == body.signal_identity_key,
           let adopted = await adoptOwnDevice(
               ownUIN: ownUIN, identityB64: mine, registrationId: body.registration_id
           ) {
            print("[SignalBootstrap] adopted already-registered device \(adopted)")
            return adopted
        }

        struct DeviceOut: Decodable { let device_id: Int }
        let label = await deviceLabel()
        let out: DeviceOut = try await APIClient.shared.request(
            "POST", "/keys/devices",
            body: DeviceBody(bundle: body, label: label, sealedSenderPub: sealedSenderPub)
        )
        print("[SignalBootstrap] another install owns the primary slot, registered as device \(out.device_id)")
        // The list we hold of our own devices predates this row.
        await SignalCryptoService.invalidateOwnDevices()
        return out.device_id
    }

    /// The device row THIS install already registered, if it ever got one.
    ///
    /// `POST /keys/devices` is not idempotent — it always mints the next free
    /// id — so a response lost on the way back leaves a row behind that this
    /// install does not know it owns. Registering again would strand it:
    /// senders fan out over the device list and would keep sealing a copy for
    /// a device nobody drains. The published identity + registration id are
    /// the only things that distinguish our row from a sibling's, so match on
    /// both before minting another one.
    private static func adoptOwnDevice(
        ownUIN: Int, identityB64: String, registrationId: UInt32
    ) async -> Int? {
        // Our own account: a five-minute-old list can be missing the row we
        // are looking for, which is the whole question here.
        await SignalCryptoService.invalidatePeerDevices(forPeerUIN: ownUIN)
        guard let devices = await SignalCryptoService.peerDeviceIDs(forPeerUIN: ownUIN) else { return nil }
        for d in devices where d != 1 && (1...127).contains(d) {
            guard let published = await SignalCryptoService.deviceIdentity(uin: ownUIN, deviceId: UInt32(d))
            else { continue }
            if published.identityKey == identityB64 && published.registrationId == registrationId {
                return d
            }
        }
        return nil
    }

    /// Fresh signed pre-key + Kyber pre-key + OPK pool under [identity],
    /// stored locally and returned in upload shape.
    private static func mintKeyMaterial(
        identity: IdentityKeyPair, ctx: StoreContext
    ) throws -> (signed: SignedPreKeyOut, kyber: KyberPreKeyOut, opks: [OPKOut]) {
        let stores = SignalProtocolStores.shared
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)

        // Signed pre-key. TODO: rotate every ~7 days from a launch hook.
        let signedId = UInt32.random(in: 1...0x7FFFFFFF)
        let signedPriv = PrivateKey.generate()
        let signedPubBytes = signedPriv.publicKey.serialize()
        let signedSig = identity.privateKey.generateSignature(message: signedPubBytes)
        let signedRecord = try SignedPreKeyRecord(
            id: signedId,
            timestamp: nowMs,
            privateKey: signedPriv,
            signature: signedSig
        )
        try stores.storeSignedPreKey(signedRecord, id: signedId, context: ctx)

        // Kyber pre-key. Reuse is OK per PQXDH (FS comes from EC ephemeral).
        let kyberId = UInt32.random(in: 1...0x7FFFFFFF)
        let kyberKp = KEMKeyPair.generate()
        let kyberPubBytes = kyberKp.publicKey.serialize()
        let kyberSig = identity.privateKey.generateSignature(message: kyberPubBytes)
        let kyberRecord = try KyberPreKeyRecord(
            id: kyberId,
            timestamp: nowMs,
            keyPair: kyberKp,
            signature: kyberSig
        )
        try stores.storeKyberPreKey(kyberRecord, id: kyberId, context: ctx)

        // OPK pool — one-time pre-keys consumed at X3DH initiation.
        var opks: [OPKOut] = []
        for _ in 0..<targetOPKCount {
            let id = UInt32.random(in: 1...0x7FFFFFFF)
            let priv = PrivateKey.generate()
            let record = try PreKeyRecord(id: id, privateKey: priv)
            try stores.storePreKey(record, id: id, context: ctx)
            opks.append(OPKOut(id: id, publicKey: priv.publicKey.serialize().base64EncodedString()))
        }

        return (
            SignedPreKeyOut(
                id: signedId,
                publicKey: signedPubBytes.base64EncodedString(),
                signature: signedSig.base64EncodedString()
            ),
            KyberPreKeyOut(
                id: kyberId,
                publicKey: kyberPubBytes.base64EncodedString(),
                signature: kyberSig.base64EncodedString()
            ),
            opks
        )
    }

    private static func freshBootstrap(ownUIN: Int, ctx: StoreContext) async throws {
        let stores = SignalProtocolStores.shared

        // Whatever this install held before this run, read BEFORE the new
        // identity overwrites it — that is what decides the slot. Normally
        // nothing: a fresh bootstrap follows an empty (or wiped) store.
        let previousIdentityB64 = (try? stores.loadLocalIdentity())?
            .identityKeyPair.publicKey.serialize().base64EncodedString()

        // Identity + registrationId (14-bit, libsignal device disambiguator).
        let identity = IdentityKeyPair.generate()
        let registrationId = UInt32.random(in: 1...16380)
        stores.storeLocalIdentity(uin: ownUIN, identityKeyPair: identity, registrationId: registrationId)

        let material = try mintKeyMaterial(identity: identity, ctx: ctx)
        let body = BundleBody(
            signal_identity_key: identity.publicKey.serialize().base64EncodedString(),
            registration_id: registrationId,
            signed_prekey: material.signed,
            kyber_prekey: material.kyber,
            one_time_prekeys: material.opks
        )
        let deviceId = try await publishBundle(
            body, ownUIN: ownUIN, currentIdentityB64: previousIdentityB64
        )
        stores.storeLocalDeviceId(deviceId)
        print("[SignalBootstrap] uploaded fresh bundle for UIN=\(ownUIN), device=\(deviceId), OPKs=\(material.opks.count)")
    }

    /// This install has a working libsignal identity but ANOTHER install
    /// holds the primary slot. Keep the identity (the safety number stays
    /// put), mint fresh pre-key material for it, and claim a device id.
    ///
    /// Sessions go with the move: a peer keys their half by the device id we
    /// declare, so everything established while we were device 1 is at an
    /// address that is no longer ours. Retiring the SENDING half of ours makes
    /// the next message to each peer a PreKeySignalMessage, which is what seeds
    /// a session under the new address on their side — without this the ratchet
    /// would keep emitting whisper messages nobody has a session for. The
    /// receiving half stays: messages already on their way to our old address
    /// are still ours to open, and they open with nothing else.
    private static func registerSecondary(
        ownUIN: Int,
        identity: IdentityKeyPair,
        registrationId: UInt32,
        ctx: StoreContext
    ) async throws {
        let stores = SignalProtocolStores.shared
        let identityB64 = identity.publicKey.serialize().base64EncodedString()
        let material = try mintKeyMaterial(identity: identity, ctx: ctx)
        let body = BundleBody(
            signal_identity_key: identityB64,
            registration_id: registrationId,
            signed_prekey: material.signed,
            kyber_prekey: material.kyber,
            one_time_prekeys: material.opks
        )
        let deviceId = try await publishBundle(body, ownUIN: ownUIN, currentIdentityB64: identityB64)
        guard deviceId != stores.localDeviceId else { return }
        stores.archiveAllSessions()
        stores.storeLocalDeviceId(deviceId)
    }

    /// Rotate the libsignal identity in place: mint a brand-new identity + prekey
    /// bundle, upload it (REPLACING the old one), then swap local state to match.
    /// Upload-FIRST so a failed network call leaves the existing (working)
    /// identity untouched instead of desyncing local vs server. Used by account
    /// key re-issue — a new libsignal identity changes our safety number so
    /// contacts get a "safety number changed" warning on their next session.
    static func rebootstrap(ownUIN: Int) async throws {
        let stores = SignalProtocolStores.shared
        let ctx = RCQStoreContext.shared

        // The key we are replacing. A re-issue is a deliberate change of
        // identity by the install that owns the slot, so this — never the new
        // key below — is what says the slot is ours to write.
        let previousIdentityB64 = (try? stores.loadLocalIdentity())?
            .identityKeyPair.publicKey.serialize().base64EncodedString()

        let identity = IdentityKeyPair.generate()
        let registrationId = UInt32.random(in: 1...16380)
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)

        let signedId = UInt32.random(in: 1...0x7FFFFFFF)
        let signedPriv = PrivateKey.generate()
        let signedPubBytes = signedPriv.publicKey.serialize()
        let signedSig = identity.privateKey.generateSignature(message: signedPubBytes)

        let kyberId = UInt32.random(in: 1...0x7FFFFFFF)
        let kyberKp = KEMKeyPair.generate()
        let kyberPubBytes = kyberKp.publicKey.serialize()
        let kyberSig = identity.privateKey.generateSignature(message: kyberPubBytes)

        struct GenOPK { let id: UInt32; let priv: PrivateKey }
        var gen: [GenOPK] = []
        for _ in 0..<targetOPKCount {
            gen.append(GenOPK(id: UInt32.random(in: 1...0x7FFFFFFF), priv: PrivateKey.generate()))
        }

        let body = BundleBody(
            signal_identity_key: identity.publicKey.serialize().base64EncodedString(),
            registration_id: registrationId,
            signed_prekey: SignedPreKeyOut(
                id: signedId,
                publicKey: signedPubBytes.base64EncodedString(),
                signature: signedSig.base64EncodedString()
            ),
            kyber_prekey: KyberPreKeyOut(
                id: kyberId,
                publicKey: kyberPubBytes.base64EncodedString(),
                signature: kyberSig.base64EncodedString()
            ),
            one_time_prekeys: gen.map {
                OPKOut(id: $0.id, publicKey: $0.priv.publicKey.serialize().base64EncodedString())
            }
        )
        // Upload BEFORE touching local state. The slot this install already
        // holds it keeps — a re-key is not a second install. A re-issue from a
        // secondary claims a NEW device id rather than seizing the primary
        // slot from whoever holds it.
        let deviceId = try await publishBundle(
            body, ownUIN: ownUIN, currentIdentityB64: previousIdentityB64
        )

        // Server accepted the new bundle — swap local libsignal state to match.
        SignalProtocolDB.shared.wipe()
        stores.storeLocalIdentity(uin: ownUIN, identityKeyPair: identity, registrationId: registrationId)
        stores.storeLocalDeviceId(deviceId)
        let signedRecord = try SignedPreKeyRecord(
            id: signedId, timestamp: nowMs, privateKey: signedPriv, signature: signedSig
        )
        try stores.storeSignedPreKey(signedRecord, id: signedId, context: ctx)
        let kyberRecord = try KyberPreKeyRecord(
            id: kyberId, timestamp: nowMs, keyPair: kyberKp, signature: kyberSig
        )
        try stores.storeKyberPreKey(kyberRecord, id: kyberId, context: ctx)
        for o in gen {
            let record = try PreKeyRecord(id: o.id, privateKey: o.priv)
            try stores.storePreKey(record, id: o.id, context: ctx)
        }
        print("[SignalBootstrap] re-issued libsignal identity for UIN=\(ownUIN), device=\(deviceId)")
    }

    private static func topUpIfNeeded(ownUIN: Int) async {
        let stores = SignalProtocolStores.shared
        do {
            let status: KeyStatus = try await APIClient.shared.request("GET", "/keys/me/status")
            guard let local = try stores.loadLocalIdentity() else { return }
            let ownIdentityB64 = local.identityKeyPair.publicKey.serialize().base64EncodedString()
            let myDeviceId = stores.localDeviceId

            if myDeviceId != 1 {
                // Everything `status` reports belongs to the PRIMARY slot: it
                // is another install's bundle and another install's prekey
                // pool, and neither says anything about us. A missing bundle
                // is therefore no reason to touch a perfectly live secondary —
                // our registration is gone only when the device list keeps
                // coming back without our id.
                await SignalCryptoService.invalidatePeerDevices(forPeerUIN: ownUIN)
                if let devices = await SignalCryptoService.peerDeviceIDs(forPeerUIN: ownUIN) {
                    if devices.contains(myDeviceId) {
                        if stores.missingDeviceStrikes != 0 { stores.storeMissingDeviceStrikes(0) }
                    } else {
                        // ONE list without our id is not evidence enough to act
                        // on. Wiping on it cost the identity, every session and
                        // the whole prekey pool of a device that a single failed
                        // or stale read had said nothing about; re-registering
                        // costs a device row. So: ask again, and when the answer
                        // repeats, take a fresh slot while KEEPING all of it —
                        // the slot is the only thing actually missing.
                        //
                        // "Again" means the NEXT launch as much as the next
                        // top-up, so the count is on disk. Cleared only once
                        // the re-registration went through: a strike lost to a
                        // failed one puts this install back to needing two more
                        // readings, and it is deaf to fan-out senders for all
                        // of them.
                        let strikes = stores.missingDeviceStrikes + 1
                        stores.storeMissingDeviceStrikes(strikes)
                        if strikes >= missingDeviceStrikesToAct {
                            print("[SignalBootstrap] device \(myDeviceId) missing from \(strikes) device lists in a row, re-registering")
                            try await registerSecondary(
                                ownUIN: ownUIN,
                                identity: local.identityKeyPair,
                                registrationId: local.registrationId,
                                ctx: RCQStoreContext.shared
                            )
                            stores.storeMissingDeviceStrikes(0)
                        }
                        return
                    }
                }
                // Our own pool, which `one_time_prekey_count` counts for the
                // primary and for nobody else. The local store is the only
                // measure we have of it.
                let mine = stores.preKeyCount()
                if mine < topUpThreshold {
                    try await replenishOPKs(count: max(targetOPKCount - mine, 0), deviceId: myDeviceId)
                }
                return
            }

            if !status.has_bundle {
                // Server forgot us (db wipe) — clear local stores and rebootstrap.
                print("[SignalBootstrap] server has no bundle, re-bootstrapping")
                SignalProtocolDB.shared.wipe()
                try await freshBootstrap(ownUIN: local.uin, ctx: RCQStoreContext.shared)
                return
            }
            // A nil key means the island predates per-device keys and cannot
            // say who owns the slot; it has exactly one, and assuming it is
            // ours is what every build before this did.
            if let published = status.signal_identity_key, published != ownIdentityB64 {
                // Another install holds the primary while we were addressed as
                // device 1 — every peer now keys their half of the session by
                // ITS bundle, so ours is unreachable until we take a slot of
                // our own.
                try await registerSecondary(
                    ownUIN: ownUIN,
                    identity: local.identityKeyPair,
                    registrationId: local.registrationId,
                    ctx: RCQStoreContext.shared
                )
                return
            }
            // The published key is ours, so the primary slot is ours, and the
            // pool the status counts is the one `/keys/prekeys` tops up.
            if status.signal_identity_key == ownIdentityB64 { stores.storeLocalDeviceId(1) }
            if status.one_time_prekey_count < topUpThreshold {
                let needed = max(targetOPKCount - status.one_time_prekey_count, 0)
                try await replenishOPKs(count: needed)
            }
        } catch {
            print("[SignalBootstrap] top-up check failed: \(error)")
        }
    }

    /// Mint [count] fresh one-time pre-keys and publish them into the pool of
    /// [deviceId] — the account's primary pool, or the private one a secondary
    /// device registered with.
    private static func replenishOPKs(count: Int, deviceId: Int = 1) async throws {
        guard count > 0 else { return }
        let stores = SignalProtocolStores.shared
        let ctx = RCQStoreContext.shared
        struct OPKBody: Encodable { let one_time_prekeys: [OPKOut] }
        var batch: [OPKOut] = []
        for _ in 0..<count {
            let id = UInt32.random(in: 1...0x7FFFFFFF)
            let priv = PrivateKey.generate()
            let record = try PreKeyRecord(id: id, privateKey: priv)
            try stores.storePreKey(record, id: id, context: ctx)
            batch.append(OPKOut(id: id, publicKey: priv.publicKey.serialize().base64EncodedString()))
        }
        let path = deviceId == 1 ? "/keys/prekeys" : "/keys/devices/\(deviceId)/prekeys"
        let _: EmptyResponse = try await APIClient.shared.request(
            "POST", path, body: OPKBody(one_time_prekeys: batch)
        )
        print("[SignalBootstrap] replenished \(batch.count) OPKs for device \(deviceId)")
    }
}

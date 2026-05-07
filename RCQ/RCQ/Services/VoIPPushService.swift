import CallKit
import Foundation
import PushKit

/// PushKit / VoIP-push integration. iOS sends a special "VoIP" push
/// (apns-push-type: voip, topic: <bundle>.voip) when our backend's
/// call-offer relay finds the recipient offline. The OS wakes the app
/// even from killed state — we have a few seconds to:
///
///   1. Parse the call info from the push payload (call_id, caller,
///      media kind, offer SDP).
///   2. **Synchronously** call `CallProvider.reportIncoming` so CallKit
///      shows the system incoming UI. Skipping this gets us terminated
///      and VoIP delivery suspended for hours.
///   3. Hand the offer SDP off to `CallService` so the eventual Accept
///      action can run the WebRTC handshake.
///
/// VoIP push tokens are separate from regular APNs tokens. We register
/// them under `platform="ios-voip"` in `device_tokens` so the backend
/// can pick the right list when fanning out.
@MainActor
final class VoIPPushService: NSObject {
    static let shared = VoIPPushService()

    private let registry = PKPushRegistry(queue: .main)
    private(set) var voipToken: String?

    private static let lastSentTokenKey = "rcq.voip.lastSentToken"
    /// Match `NotificationService.lastSentAtKey` semantics — re-upload
    /// after a TTL even when the (uin, token) pair didn't change so a
    /// backend that lost the row eventually self-heals.
    private static let lastSentAtKey = "rcq.voip.lastSentAt"
    private static let lastSentMaxAgeSec: TimeInterval = 12 * 60 * 60

    private override init() {
        super.init()
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        // PKPushRegistry's `didUpdate` callback only fires when Apple
        // *issues or rotates* a token — on subsequent launches the
        // existing token is cached but no callback fires. Poll the
        // registry synchronously here so `voipToken` is populated
        // immediately and `refreshTokenSubmission` from AppState.boot
        // has something to upload to the server. Without this, after a
        // re-register (Keychain wipe) the new UIN never gets its VoIP
        // token re-uploaded → `send_voip_to_user` finds no row → calls
        // to a killed app silently drop.
        if let cached = registry.pushToken(for: .voIP) {
            voipToken = cached.map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Idempotent. Holding a reference to `VoIPPushService.shared` is
    /// enough to start receiving VoIP pushes — the registry's lifetime
    /// is tied to the singleton.
    func register() { _ = self }

    /// Re-attempt token submission once we've authenticated. Mirror of
    /// `NotificationService.refreshTokenSubmission()` for the regular
    /// APNs path. `force=true` bypasses the local cache so the backend
    /// always receives the upload at boot — necessary when the server
    /// lost its row but the client cache still says "already sent".
    func refreshTokenSubmission() async {
        await submitTokenIfNeeded(force: true)
    }

    /// Burn-account hook — clear the cached "already-sent token" sentinel
    /// so the next registration uploads fresh credentials to the new UIN.
    func wipe() {
        UserDefaults.standard.removeObject(forKey: Self.lastSentTokenKey)
        voipToken = nil
    }

    private func submitTokenIfNeeded(force: Bool = false) async {
        guard let token = voipToken else { return }
        guard let uin = AuthService.shared.ownUIN else {
            // Not logged in yet — token will be re-submitted from
            // AppState.boot when auth completes.
            return
        }
        // Cache key bundles the UIN with the token. Without this, after
        // a re-register (Keychain wipe → new UIN) the cache says "we
        // already sent this token" and we skip the upload — leaving the
        // server with the token mapped to the *old* UIN, so VoIP pushes
        // to the new UIN find nothing and silently drop.
        let cacheKey = "\(uin):\(token)"
        let now = Date().timeIntervalSince1970
        let lastSentAt = UserDefaults.standard.double(forKey: Self.lastSentAtKey)
        let aged = now - lastSentAt > Self.lastSentMaxAgeSec
        if !force && !aged && UserDefaults.standard.string(forKey: Self.lastSentTokenKey) == cacheKey {
            return
        }
        struct Body: Encodable { let token: String; let platform: String }
        do {
            let _: EmptyResponse = try await APIClient.shared.request(
                "POST", "/users/me/push-token",
                body: Body(token: token, platform: "ios-voip")
            )
            UserDefaults.standard.set(cacheKey, forKey: Self.lastSentTokenKey)
            UserDefaults.standard.set(now, forKey: Self.lastSentAtKey)
        } catch {
            // Transient — try again on next boot.
        }
    }
}

// MARK: - PKPushRegistryDelegate

extension VoIPPushService: PKPushRegistryDelegate {
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        let hex = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor [weak self] in
            self?.voipToken = hex
            await self?.submitTokenIfNeeded()
        }
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        // Apple revoked our token (rare — usually means the user disabled
        // push for our app). Drop the cache so the next register re-submits.
        Task { @MainActor [weak self] in
            self?.voipToken = nil
            UserDefaults.standard.removeObject(forKey: Self.lastSentTokenKey)
        }
    }

    /// **Critical path** — see class doc. We MUST call
    /// `provider.reportNewIncomingCall` synchronously, before this
    /// function returns. Going through `Task { @MainActor in ... }` would
    /// schedule the report asynchronously — pushRegistry returns first,
    /// iOS sees us as having ignored the push, terminates the app, and
    /// suspends VoIP delivery for hours. The original cause of every
    /// "call ends immediately" bug.
    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        let dict = payload.dictionaryPayload

        // Caller cancelled while this device's WS wasn't connected
        // to receive the regular `callEnd` event — server falls
        // back to a VoIP push with `kind=end` so we can dismiss
        // the still-ringing CallKit UI here. We must STILL call
        // `reportNewIncomingCall` to satisfy Apple's PushKit
        // contract (or iOS terminates us and suspends VoIP for
        // hours), but we do it on a throwaway UUID and end it
        // immediately — same escape-hatch pattern as the
        // malformed-payload branch below. Then we tear down the
        // real call by its `call_id` so the existing UUID's UI
        // also clears.
        if let kind = dict["kind"] as? String, kind == "end",
           let endCallID = dict["call_id"] as? String {
            let throwaway = UUID()
            let update = CXCallUpdate()
            update.remoteHandle = CXHandle(type: .generic, value: "")
            CallProvider.shared.reportIncomingMalformed(uuid: throwaway, update: update)
            let reason = (dict["reason"] as? String) ?? "remote_ended"
            Task { @MainActor in
                CallService.shared.handleRemoteEnd(callID: endCallID, reason: reason)
                completion()
            }
            return
        }

        guard
            let callID = dict["call_id"] as? String,
            let fromUIN = dict["from_uin"] as? Int,
            let mediaStr = dict["media"] as? String,
            let sdp = dict["sdp"] as? String
        else {
            // Malformed payload — still must call reportNewIncomingCall
            // before completion, otherwise iOS treats this as a
            // protocol violation. Report-then-immediately-end is the
            // documented escape hatch.
            let bogusUUID = UUID()
            let update = CXCallUpdate()
            update.remoteHandle = CXHandle(type: .generic, value: "Unknown")
            CallProvider.shared.reportIncomingMalformed(uuid: bogusUUID, update: update)
            completion()
            return
        }
        let nickname = (dict["nickname"] as? String) ?? "Stranger"
        let media = CallMedia(rawValue: mediaStr) ?? .video

        // SYNC report to CallKit — this call is what iOS measures and what
        // it kills the app over if missed. CallProvider is no longer
        // @MainActor isolated; the call goes through directly.
        let uuid = CallProvider.shared.reportIncoming(
            callID: callID,
            peerName: nickname,
            hasVideo: media == .video
        )

        // SDP stashing + completion are async (state lives on @MainActor
        // CallService). By the time the user can tap Accept, this Task
        // has run and pendingRemoteOffer is in place.
        Task { @MainActor in
            CallService.shared.handleVoIPIncoming(
                callKitUUID: uuid,
                callID: callID,
                fromUIN: fromUIN,
                nickname: nickname,
                media: media,
                sdp: sdp
            )
            completion()
        }
    }
}

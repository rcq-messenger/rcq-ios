import CallKit
import Foundation
import PushKit

/// PushKit/VoIP-push integration. Must call `CallProvider.reportIncoming` synchronously or iOS suspends VoIP delivery.
@MainActor
final class VoIPPushService: NSObject {
    static let shared = VoIPPushService()

    private let registry = PKPushRegistry(queue: .main)
    private(set) var voipToken: String?

    private static let lastSentTokenKey = "rcq.voip.lastSentToken"
    private static let lastSentAtKey = "rcq.voip.lastSentAt"
    private static let lastSentMaxAgeSec: TimeInterval = 12 * 60 * 60

    private override init() {
        super.init()
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        // didUpdate only fires on token issue/rotate. Poll synchronously so boot has a token to upload.
        if let cached = registry.pushToken(for: .voIP) {
            voipToken = cached.map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Idempotent.
    func register() { _ = self }

    /// Re-submit at boot. `force=true` bypasses the local sent-cache.
    func refreshTokenSubmission() async {
        await submitTokenIfNeeded(force: true)
    }

    /// Burn-account hook. Clears the sent-token cache.
    func wipe() {
        UserDefaults.standard.removeObject(forKey: Self.lastSentTokenKey)
        voipToken = nil
    }

    private func submitTokenIfNeeded(force: Bool = false) async {
        guard let token = voipToken else { return }
        guard let uin = AuthService.shared.ownUIN else {
            return
        }
        // Cache key includes UIN so a re-register against a new UIN re-submits the same token.
        let cacheKey = "\(uin):\(token)"
        let now = Date().timeIntervalSince1970
        let lastSentAt = UserDefaults.standard.double(forKey: Self.lastSentAtKey)
        let aged = now - lastSentAt > Self.lastSentMaxAgeSec
        if !force && !aged && UserDefaults.standard.string(forKey: Self.lastSentTokenKey) == cacheKey {
            return
        }
        struct Body: Encodable { let token: String; let platform: String; let device_id: String }
        do {
            let _: EmptyResponse = try await APIClient.shared.request(
                "POST", "/users/me/push-token",
                body: Body(token: token, platform: "ios-voip", device_id: KeychainStore.deviceID())
            )
            UserDefaults.standard.set(cacheKey, forKey: Self.lastSentTokenKey)
            UserDefaults.standard.set(now, forKey: Self.lastSentAtKey)
        } catch {
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
        Task { @MainActor [weak self] in
            self?.voipToken = nil
            UserDefaults.standard.removeObject(forKey: Self.lastSentTokenKey)
        }
    }

    /// MUST call `provider.reportNewIncomingCall` synchronously before returning.
    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        let dict = payload.dictionaryPayload

        // kind=end fallback (caller cancel during WS gap). Still must report-then-end on a throwaway UUID.
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
            // Malformed payload: report-then-end is the documented escape hatch for the PushKit contract.
            let bogusUUID = UUID()
            let update = CXCallUpdate()
            update.remoteHandle = CXHandle(type: .generic, value: "Unknown")
            CallProvider.shared.reportIncomingMalformed(uuid: bogusUUID, update: update)
            completion()
            return
        }
        let nickname = (dict["nickname"] as? String) ?? "Stranger"
        let media = CallMedia(rawValue: mediaStr) ?? .video

        // Sync report to CallKit — iOS measures this call and terminates if missed.
        let uuid = CallProvider.shared.reportIncoming(
            callID: callID,
            peerName: nickname,
            hasVideo: media == .video
        )

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

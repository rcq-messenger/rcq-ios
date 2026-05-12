import Combine
import Foundation

/// Single source of truth for the user's own status + status message. Pushes to backend
/// over HTTP; the backend then fans out a presence event to all watching contacts.
@MainActor
final class PresenceService: ObservableObject {
    static let shared = PresenceService()

    @Published var status: UserStatus = .online
    @Published var statusMessage: String? = nil

    private init() {}

    func setStatus(_ status: UserStatus, message: String? = nil) async {
        self.status = status
        self.statusMessage = message
        // Propagate to the group-member cache for our own UIN. The
        // backend `presence_watchers` audience excludes self, so the
        // user never receives a WS presence event for themselves —
        // without this local hop their own row in any GroupInfoView
        // stays stuck on whatever status they had at app launch.
        if let me = AuthService.shared.ownUIN {
            GroupService.shared.updateMemberPresence(uin: me, status: status)
        }
        struct Body: Encodable { let status: String; let status_message: String? }
        do {
            let _: EmptyResponse = try await APIClient.shared.request(
                "POST",
                "/presence/status",
                body: Body(status: status.rawValue, status_message: message)
            )
        } catch {
            // Soft-fail: presence is eventually-consistent. The next reconnect re-publishes.
        }
    }
}

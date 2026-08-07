import Combine
import Foundation

/// Single source of truth for the user's own status + status message. Pushes to backend
/// over HTTP; the backend then fans out a presence event to all watching contacts.
@MainActor
final class PresenceService: ObservableObject {
    static let shared = PresenceService()

    @Published var status: UserStatus = .online
    @Published var statusMessage: String? = nil

    /// The account's own profile picture, held here rather than in a screen's
    /// local state.
    ///
    /// It used to live only inside SettingsView's `@State`, loaded by a `.task`
    /// hung on the avatar picker — so it existed only once the settings screen
    /// had been opened, and the main screen's header had nowhere to read it
    /// from and drew the status flower forever. Seeded synchronously from the
    /// last known values so a cold start draws the picture on the first frame
    /// instead of swapping it in a moment later.
    @Published var ownAvatarID: String? = UserDefaults.standard.string(forKey: "rcq.ownAvatarID")
    @Published var ownAvatarKey: String? = UserDefaults.standard.string(forKey: "rcq.ownAvatarKey")

    func setOwnAvatar(id: String?, key: String?) {
        let id = (id?.isEmpty ?? true) ? nil : id
        let key = (key?.isEmpty ?? true) ? nil : key
        ownAvatarID = id
        ownAvatarKey = key
        UserDefaults.standard.set(id, forKey: "rcq.ownAvatarID")
        UserDefaults.standard.set(key, forKey: "rcq.ownAvatarKey")
    }

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

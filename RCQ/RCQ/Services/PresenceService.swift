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
        // A decoy session must never overwrite the real account's saved picture
        // — it would survive the duress session and the real user would come
        // back to a blank header.
        guard !PanicPINService.shared.isDecoy else { return }
        let id = (id?.isEmpty ?? true) ? nil : id
        let key = (key?.isEmpty ?? true) ? nil : key
        ownAvatarID = id
        ownAvatarKey = key
        UserDefaults.standard.set(id, forKey: "rcq.ownAvatarID")
        UserDefaults.standard.set(key, forKey: "rcq.ownAvatarKey")
    }

    /// Drop the account's own picture for the duration of a decoy session.
    ///
    /// IN MEMORY ONLY — the UserDefaults mirror is left alone and read back by
    /// `reloadOwnAvatarFromDisk()` on the way out. This is not cosmetic: the
    /// picture is the user's own face, it is held in a singleton that `lock()`
    /// never cleared, and it was being drawn on the home header AND at the top
    /// of Settings above a synthetic nickname and a synthetic UIN. A decoy
    /// identity with the real person's photograph is both a leak and the
    /// loudest possible tell that the account on screen is not the real one.
    func clearForDecoy() {
        ownAvatarID = nil
        ownAvatarKey = nil
    }

    func reloadOwnAvatarFromDisk() {
        ownAvatarID = UserDefaults.standard.string(forKey: "rcq.ownAvatarID")
        ownAvatarKey = UserDefaults.standard.string(forKey: "rcq.ownAvatarKey")
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

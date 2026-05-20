import Combine
import Foundation

/// Lightweight client for `/news` + unread-badge state.
///
/// `latestID` from the server is the authoritative "what's the
/// newest post" pointer. Local UserDefaults holds `lastReadNewsID`,
/// updated whenever the user opens the news sheet. The published
/// `hasUnread` flag drives the red dot on the 3-dot menu.
///
/// We don't push-notify news (yet) — the badge fires on the next
/// `refresh()` which `ContactListView.task` calls on appear, plus
/// scenePhase → .active. That feels alive without burning APNS
/// budget on broadcasts.
@MainActor
final class NewsService: ObservableObject {
    static let shared = NewsService()

    @Published private(set) var items: [NewsPost] = []
    @Published private(set) var latestID: Int = 0
    @Published private(set) var lastSeenID: Int

    private static let lastSeenKey = "rcq.news.lastSeenID"

    var hasUnread: Bool { latestID > lastSeenID }
    /// Count of unread posts (latest fetched, since `lastSeenID`).
    /// Drives the badge next to the "News" item inside the 3-dot
    /// menu — the bare red dot on the ellipsis itself doesn't tell
    /// the user how many new posts they actually have.
    var unreadCount: Int {
        items.filter { $0.id > lastSeenID }.count
    }

    private init() {
        self.lastSeenID = UserDefaults.standard.integer(forKey: Self.lastSeenKey)
    }

    func refresh() async {
        struct Out: Decodable {
            let items: [NewsPost]
            let latest_id: Int
        }
        do {
            let out: Out = try await APIClient.shared.request("GET", "/news")
            self.items = out.items
            self.latestID = out.latest_id
        } catch {
            // Silent — news isn't load-bearing for the rest of the
            // UI; failing the fetch just leaves the badge stale
            // until the next refresh.
        }
    }

    /// Mark the newest fetched post as seen. Called when the user
    /// opens the news sheet, so the red dot clears on first view.
    func markAllSeen() {
        guard latestID > lastSeenID else { return }
        lastSeenID = latestID
        UserDefaults.standard.set(lastSeenID, forKey: Self.lastSeenKey)
    }
}

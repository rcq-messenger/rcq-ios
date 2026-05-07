import Combine
import Foundation
import os.log

@MainActor
final class ContactService: ObservableObject {
    static let shared = ContactService()

    private static let log = OSLog(subsystem: "app.rcq.client", category: "ContactService")

    @Published private(set) var contacts: [Contact] = []
    @Published private(set) var pendingRequests: [PendingRequest] = []

    struct PendingRequest: Identifiable, Codable, Hashable {
        let id: Int
        let from_uin: Int
        let nickname: String
        let state: String
    }

    private init() {}

    func refresh() async {
        do {
            var list: [Contact] = try await APIClient.shared.request("GET", "/contacts")
            // Server doesn't track per-client unread counts (privacy
            // posture: unread is a local UI concern). Fold persisted
            // counters back into the freshly-decoded contact rows so
            // a cold launch lands with badges intact.
            let persisted = UnreadStore.shared.allPeerCounts
            for i in list.indices {
                if let n = persisted[list[i].uin], n > 0 {
                    list[i].unread = n
                }
            }
            self.contacts = list
            let pending: [PendingRequest] = try await APIClient.shared.request("GET", "/contacts/pending")
            self.pendingRequests = pending
            // Push the latest uin → nickname map into the App Group
            // cache so the NSE can resolve sender names on push.
            var nickMap: [Int: String] = [:]
            for c in list { nickMap[c.uin] = c.nickname }
            NicknameCache.setAll(nickMap)
        } catch {
            // Keep current cached state on failure.
        }
    }

    func updatePresence(uin: Int, status: UserStatus, statusMessage: String?) {
        guard let idx = contacts.firstIndex(where: { $0.uin == uin }) else { return }
        contacts[idx].status = status
        contacts[idx].statusMessage = statusMessage
    }

    func appendPendingRequest(_ req: PendingRequest) {
        if !pendingRequests.contains(where: { $0.id == req.id }) {
            pendingRequests.append(req)
        }
    }

    func sendAddRequest(to uin: Int) async throws {
        struct Body: Encodable { let to_uin: Int }
        let _: EmptyResponse = try await APIClient.shared.request(
            "POST", "/contacts/request", body: Body(to_uin: uin)
        )
    }

    func respond(requestID: Int, accept: Bool) async throws {
        struct Body: Encodable { let request_id: Int; let accept: Bool }
        let _: EmptyResponse = try await APIClient.shared.request(
            "POST", "/contacts/respond", body: Body(request_id: requestID, accept: accept)
        )
        pendingRequests.removeAll { $0.id == requestID }
        if accept { await refresh() }
    }

    func remove(_ uin: Int) async throws {
        let _: EmptyResponse = try await APIClient.shared.request(
            "DELETE", "/contacts/\(uin)"
        )
        contacts.removeAll { $0.uin == uin }
        // Drop any persisted unread for the removed peer too — they
        // shouldn't reappear with stale counts if the user re-adds
        // them later.
        UnreadStore.shared.clearPeer(uin)
    }

    func toggleBlock(_ uin: Int) async throws {
        struct Out: Decodable { let blocked: Bool }
        let out: Out = try await APIClient.shared.request("POST", "/contacts/\(uin)/block")
        if let idx = contacts.firstIndex(where: { $0.uin == uin }) {
            contacts[idx].blocked = out.blocked
        }
    }

    func incrementUnread(for uin: Int) {
        // Persist FIRST so the count survives even when the contact
        // isn't in our in-memory list yet (cold-launch push tap, or
        // the sender re-registered after our last contact-list
        // refresh and the new UIN hasn't been pulled). The contact
        // list refresh that lands later folds the persisted count
        // back into `contacts` via `applyPersistedUnread`.
        UnreadStore.shared.incrementPeer(uin)
        if let idx = contacts.firstIndex(where: { $0.uin == uin }) {
            contacts[idx].unread += 1
        } else {
            os_log("incrementUnread: unknown UIN %d — count persisted, awaiting contact refresh",
                   log: Self.log, type: .info, uin)
        }
    }

    func clearUnread(for uin: Int) {
        UnreadStore.shared.clearPeer(uin)
        guard let idx = contacts.firstIndex(where: { $0.uin == uin }) else { return }
        contacts[idx].unread = 0
    }

    /// Local cache reset used by the burn flow.
    func wipe() {
        contacts = []
        pendingRequests = []
        UnreadStore.shared.wipeAll()
    }
}

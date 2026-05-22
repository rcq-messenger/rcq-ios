import Combine
import Foundation

@MainActor
final class JetonStore: ObservableObject {
    static let shared = JetonStore()

    @Published private(set) var totals: [UUID: Int] = [:]

    private var cancellables = Set<AnyCancellable>()

    private init() {
        WebSocketService.shared.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard case .jetonReact(_, let mid, let total, _, _) = event else { return }
                self?.apply(messageID: mid, total: total)
            }
            .store(in: &cancellables)
    }

    func total(for id: UUID) -> Int { totals[id] ?? 0 }

    func apply(messageID: String, total: Int) {
        guard let uuid = UUID(uuidString: messageID) else { return }
        if total > (totals[uuid] ?? 0) { totals[uuid] = total }
    }

    func apply(messageID: UUID, total: Int) {
        if total > (totals[messageID] ?? 0) { totals[messageID] = total }
    }

    func loadGroup(_ groupID: Int) async {
        guard let rows = try? await APIClient.shared.fetchGroupJetons(groupID: groupID) else { return }
        for row in rows {
            guard let uuid = UUID(uuidString: row.messageID) else { continue }
            totals[uuid] = max(totals[uuid] ?? 0, row.totalJetons)
        }
    }
}

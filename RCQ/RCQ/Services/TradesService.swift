import Combine
import Foundation
import UIKit

/// Trade lifecycle store. Cache of pending incoming/outgoing trades,
/// driven by WebSocket events and pull-to-refresh.
@MainActor
final class TradesService: ObservableObject {
    static let shared = TradesService()

    @Published private(set) var incoming: [Trade] = []
    @Published private(set) var outgoing: [Trade] = []
    /// Most recent `trade_received` to fire the global banner.
    @Published var freshIncoming: Trade?

    private var cancellables = Set<AnyCancellable>()

    private init() {
        WebSocketService.shared.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in self?.handle(event) }
            .store(in: &cancellables)
    }

    var pendingIncomingCount: Int { incoming.count }

    // MARK: - REST

    func refreshAll() async {
        async let inc: () = refreshIncoming()
        async let out: () = refreshOutgoing()
        _ = await (inc, out)
    }

    func refreshIncoming() async {
        do {
            let res: [Trade] = try await APIClient.shared.request("GET", "/trades/incoming")
            self.incoming = res
        } catch {
            #if DEBUG
            print("⚠️ refreshIncoming failed: \(error)")
            #endif
        }
    }

    func refreshOutgoing() async {
        do {
            let res: [Trade] = try await APIClient.shared.request("GET", "/trades/outgoing")
            self.outgoing = res
        } catch {
            #if DEBUG
            print("⚠️ refreshOutgoing failed: \(error)")
            #endif
        }
    }

    @discardableResult
    func propose(
        toUIN: Int,
        offeredItems: [Item],
        requestedItems: [Item],
        offeredUins: [Int] = [],
        requestedUins: [Int] = [],
        offeredTokens: Int,
        offeredScrolls: Int,
        requestedTokens: Int,
        requestedScrolls: Int,
        note: String?,
    ) async -> Trade? {
        let body = ProposeBody(
            to_uin: toUIN,
            offered_item_ids: offeredItems.map { $0.id.lowercased() },
            requested_item_ids: requestedItems.map { $0.id.lowercased() },
            offered_uin_ids: offeredUins,
            requested_uin_ids: requestedUins,
            offered_tokens: offeredTokens,
            offered_scrolls: offeredScrolls,
            requested_tokens: requestedTokens,
            requested_scrolls: requestedScrolls,
            note: note,
        )
        // Optimistic decrement: max-reconcile in refreshInventory below
        // would otherwise preserve the stale-high local over server-low truth.
        ItemsService.shared.applyWalletDelta(
            tokens: -offeredTokens, scrolls: -offeredScrolls
        )
        do {
            let trade: Trade = try await APIClient.shared.request("POST", "/trades", body: body)
            self.outgoing.insert(trade, at: 0)
            await ItemsService.shared.refreshInventory(forceWallet: true)
            return trade
        } catch {
            // Revert optimistic deduction on failure.
            ItemsService.shared.applyWalletDelta(
                tokens: offeredTokens, scrolls: offeredScrolls
            )
            #if DEBUG
            print("⚠️ propose failed: \(error)")
            #endif
            return nil
        }
    }

    @discardableResult
    func accept(_ trade: Trade) async -> Trade? {
        let id = trade.id.lowercased()
        do {
            let updated: Trade = try await APIClient.shared.request(
                "POST", "/trades/\(id)/accept", body: EmptyBody(),
            )
            self.incoming.removeAll { $0.id == trade.id }
            await ItemsService.shared.refreshInventory(forceWallet: true)
            return updated
        } catch {
            #if DEBUG
            print("⚠️ accept failed: \(error)")
            #endif
            return nil
        }
    }

    @discardableResult
    func decline(_ trade: Trade) async -> Trade? {
        let id = trade.id.lowercased()
        do {
            let updated: Trade = try await APIClient.shared.request(
                "POST", "/trades/\(id)/decline", body: EmptyBody(),
            )
            self.incoming.removeAll { $0.id == trade.id }
            return updated
        } catch {
            #if DEBUG
            print("⚠️ decline failed: \(error)")
            #endif
            return nil
        }
    }

    @discardableResult
    func cancel(_ trade: Trade) async -> Trade? {
        let id = trade.id.lowercased()
        do {
            let updated: Trade = try await APIClient.shared.request(
                "POST", "/trades/\(id)/cancel", body: EmptyBody(),
            )
            self.outgoing.removeAll { $0.id == trade.id }
            await ItemsService.shared.refreshInventory(forceWallet: true)
            return updated
        } catch {
            #if DEBUG
            print("⚠️ cancel failed: \(error)")
            #endif
            return nil
        }
    }

    // MARK: - WS dispatch

    private func handle(_ event: WebSocketService.Event) {
        switch event {
        case .tradeReceived(let trade):
            if !incoming.contains(where: { $0.id == trade.id }) {
                incoming.insert(trade, at: 0)
            }
            // The instant pop-up sheet is opt-out: when the user
            // disabled real-time trade pop-ups in Settings the offer
            // still lands in the trades list + as an InlineTradeCard
            // in the chat thread, just without interrupting them.
            // Default true (key absent → object(forKey:) is nil).
            let popupEnabled = (UserDefaults.standard.object(
                forKey: "rcq.trades.realtime_popup") as? Bool) ?? true
            if popupEnabled {
                freshIncoming = trade
                SoundService.shared.playIncoming(fromUIN: trade.fromUIN, thread: nil)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }

        case .tradeAccepted(let trade):
            outgoing.removeAll { $0.id == trade.id }
            incoming.removeAll { $0.id == trade.id }
            if freshIncoming?.id == trade.id { freshIncoming = nil }
            Task { await ItemsService.shared.refreshInventory(forceWallet: true) }

        case .tradeDeclined(let id):
            outgoing.removeAll { $0.id == id }
            Task { await ItemsService.shared.refreshInventory(forceWallet: true) }

        case .tradeCancelled(let id):
            incoming.removeAll { $0.id == id }
            if freshIncoming?.id == id { freshIncoming = nil }

        default:
            break
        }
    }
}

// MARK: - Wire types

private struct ProposeBody: Encodable {
    let to_uin: Int
    let offered_item_ids: [String]
    let requested_item_ids: [String]
    let offered_uin_ids: [Int]
    let requested_uin_ids: [Int]
    let offered_tokens: Int
    let offered_scrolls: Int
    let requested_tokens: Int
    let requested_scrolls: Int
    let note: String?
}

private struct EmptyBody: Encodable {}

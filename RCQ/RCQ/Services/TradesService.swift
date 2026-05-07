import Combine
import Foundation
import UIKit

/// Trade lifecycle store. Server is authoritative on state — this
/// class is just a published cache of incoming/outgoing pending
/// trades, plus a queue for "fresh" trade_received events that the
/// global incoming-trade banner picks up.
///
/// Real-time over WebSocket: subscribes to `WebSocketService.events`
/// and reacts to `trade_received` / `trade_accepted` /
/// `trade_declined` / `trade_cancelled` by refreshing the relevant
/// list. Refreshes are cheap (one query each side, both filtered by
/// status=pending).
@MainActor
final class TradesService: ObservableObject {
    static let shared = TradesService()

    @Published private(set) var incoming: [Trade] = []
    @Published private(set) var outgoing: [Trade] = []
    /// Most recent `trade_received` to fire the global banner. UI
    /// clears this after the user accepts / declines / dismisses.
    @Published var freshIncoming: Trade?

    private var cancellables = Set<AnyCancellable>()

    private init() {
        WebSocketService.shared.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in self?.handle(event) }
            .store(in: &cancellables)
    }

    /// Pending count for the inventory's bell badge.
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
        // Optimistic local decrement so the sender's wallet bubble
        // drops the instant they tap Send. Without this they'd see
        // the stale balance until the next refresh, AND the
        // refreshInventory() max-reconcile below would preserve
        // the stale-high value over the server-low truth.
        ItemsService.shared.applyWalletDelta(
            tokens: -offeredTokens, scrolls: -offeredScrolls
        )
        do {
            let trade: Trade = try await APIClient.shared.request("POST", "/trades", body: body)
            self.outgoing.insert(trade, at: 0)
            // Authoritative refresh — overwrites with server's
            // post-escrow wallet so any drift between optimistic
            // local and server reality (rounding, partial spend
            // rejection) reconciles correctly.
            await ItemsService.shared.refreshInventory(forceWallet: true)
            return trade
        } catch {
            // Revert the optimistic deduction on failure so the
            // user's wallet doesn't show a phantom debit they
            // never actually committed.
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
            // Inventory + wallet just changed — pull a fresh snapshot.
            // forceWallet because the recipient receives offered
            // items + tokens; the server response is authoritative
            // and (depending on direction) may be lower than the
            // local cache.
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
            // Server returned the escrowed tokens to us — refresh
            // wallet authoritatively so the bubble climbs back to
            // the pre-propose value.
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
            // Insert at the front — newest first — and surface the
            // banner via `freshIncoming` so the root NavigationStack
            // can show "X wants to trade". Same incoming-message
            // cue the chat list uses, so the trade lands with the
            // exact attention the user gives a regular DM.
            if !incoming.contains(where: { $0.id == trade.id }) {
                incoming.insert(trade, at: 0)
            }
            freshIncoming = trade
            SoundService.shared.playIncoming(fromUIN: trade.fromUIN, thread: nil)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        case .tradeAccepted(let trade):
            // Either side gets this. If it was outgoing we drop it
            // from outgoing; if it was incoming we drop from incoming.
            outgoing.removeAll { $0.id == trade.id }
            incoming.removeAll { $0.id == trade.id }
            // Fresh banner clears too — nothing to act on.
            if freshIncoming?.id == trade.id { freshIncoming = nil }
            Task { await ItemsService.shared.refreshInventory(forceWallet: true) }

        case .tradeDeclined(let id):
            outgoing.removeAll { $0.id == id }
            // Sender's escrow was returned by the server — refresh
            // authoritatively so the wallet bubble climbs back.
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
    /// Premium UIN values being staked on each side. Default empty
    /// for trades that don't involve UIN transfer; backend reads
    /// missing arrays as empty too.
    let offered_uin_ids: [Int]
    let requested_uin_ids: [Int]
    let offered_tokens: Int
    let offered_scrolls: Int
    let requested_tokens: Int
    let requested_scrolls: Int
    let note: String?
}

private struct EmptyBody: Encodable {}

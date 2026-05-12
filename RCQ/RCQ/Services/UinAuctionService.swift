import Combine
import Foundation

/// Live state of the single active premium-UIN auction + the user's
/// won-UINs inventory. WS-driven, no polling.
@MainActor
final class UinAuctionService: ObservableObject {
    static let shared = UinAuctionService()

    @Published private(set) var active: UinAuction?
    @Published private(set) var bids: [UinAuctionBid] = []
    @Published private(set) var minNextBid: Int = 0
    @Published private(set) var owned: [OwnedUIN] = []
    @Published private(set) var recentWinners: [UinAuctionRecentWinner] = []
    @Published var lastError: String?
    @Published var celebrateWonUIN: Int?

    @Published private(set) var isMinimized: Bool = false
    @Published private(set) var isHidden: Bool = false

    var iHaveBidInRound: Bool {
        guard let me = AuthService.shared.ownUIN else { return false }
        return bids.contains { $0.bidderUIN == me }
    }

    var iAmHighBidder: Bool {
        guard let me = AuthService.shared.ownUIN, let a = active else { return false }
        return a.highBidderUIN == me
    }

    var shouldShowMini: Bool {
        isMinimized && !isHidden && active != nil && iHaveBidInRound
    }

    func minimize() {
        isMinimized = true
    }

    func expand() {
        isMinimized = false
        isHidden = false
    }

    func hideMini() {
        isHidden = true
    }

    private var cancellables = Set<AnyCancellable>()

    private init() {
        WebSocketService.shared.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in self?.handle(event) }
            .store(in: &cancellables)
    }

    // MARK: - HTTP

    func refresh() async {
        await refreshActive()
        await refreshOwned()
        await refreshRecent()
    }

    func refreshActive() async {
        do {
            let snap: UinAuction? = try await APIClient.shared.request(
                "GET", "/uin_auctions/active"
            )
            self.active = snap
            if let id = snap?.id {
                await refreshDetail(auctionID: id)
            } else {
                self.bids = []
                self.minNextBid = 0
            }
        } catch {
            print("[UinAuctionService] refreshActive failed: \(error)")
        }
    }

    func refreshDetail(auctionID: Int) async {
        do {
            let detail: UinAuctionDetail = try await APIClient.shared.request(
                "GET", "/uin_auctions/\(auctionID)"
            )
            self.active = detail.auction
            self.bids = detail.bids
            self.minNextBid = detail.minNextBid
        } catch {
            print("[UinAuctionService] refreshDetail failed: \(error)")
        }
    }

    func refreshOwned() async {
        do {
            let list: [OwnedUIN] = try await APIClient.shared.request(
                "GET", "/uin/owned"
            )
            self.owned = list
        } catch {
            print("[UinAuctionService] refreshOwned failed: \(error)")
        }
    }

    func refreshRecent() async {
        do {
            let list: [UinAuctionRecentWinner] = try await APIClient.shared.request(
                "GET", "/uin_auctions/recent_winners"
            )
            self.recentWinners = list
        } catch {
            print("[UinAuctionService] refreshRecent failed: \(error)")
        }
    }

    enum BidResult {
        case success
        case bidTooLow(minRequired: Int)
        case insufficientTokens(required: Int, have: Int)
        case alreadyHighBidder
        case ended
        case other(String)
    }

    func placeBid(amount: Int) async -> BidResult {
        guard let auction = active else { return .ended }
        struct Body: Encodable { let amount: Int }
        struct Out: Decodable {
            let auction: UinAuction
            let your_locked_tokens_after: Int
        }
        do {
            let resp: Out = try await APIClient.shared.request(
                "POST", "/uin_auctions/\(auction.id)/bid",
                body: Body(amount: amount)
            )
            self.active = resp.auction
            // Optimistic local insert. The WS `uin_auction_bid`
            // broadcast races with the HTTP response and has dropped
            // bids in the past (e.g. when the `ends_at` ISO parse
            // failed in WS dispatch, silently swallowing the entire
            // event). Inserting here guarantees the bidder sees their
            // own bid the moment the server confirms it — the
            // `_dedupBid` filter below skips the duplicate when the
            // WS frame eventually arrives.
            if let me = AuthService.shared.ownUIN {
                let myNick = AuthService.shared.nickname
                let bid = UinAuctionBid(
                    bidderUIN: me,
                    bidderNickname: myNick.isEmpty ? String(me) : myNick,
                    amount: amount,
                    placedAt: Date(),
                )
                appendBid(bid)
            }
            // forceWallet bypasses defensive max() in refreshInventory so the counter drops.
            await ItemsService.shared.refreshInventory(forceWallet: true)
            SoundService.shared.play(.auctionBidPlaced)
            return .success
        } catch APIError.http(400, let body) {
            if let parsed = Self.parseBidTooLow(body) { return parsed }
            if Self.detectAlreadyHighBidder(body) { return .alreadyHighBidder }
            return .other("uin_auction.error.generic".localized)
        } catch APIError.http(402, let body) {
            if let parsed = Self.parseInsufficient(body) { return parsed }
            return .insufficientTokens(required: amount, have: 0)
        } catch APIError.http(409, _) {
            return .ended
        } catch {
            return .other(error.localizedDescription)
        }
    }

    func activate(uin: Int) async -> AppState.MigrationResult {
        await AppState.shared.migrateAccount(targetUIN: uin)
    }

    // MARK: - WS event handling

    private var softCloseAnnounced: Bool = false

    private func handle(_ event: WebSocketService.Event) {
        switch event {
        case .uinAuctionStarted(let auction):
            self.active = auction
            self.bids = []
            self.minNextBid = auction.startingBid
            self.softCloseAnnounced = false
            Task { await self.refreshRecent() }
        case .uinAuctionBid(let auctionID, let amount, let bidderUIN, let nick, let highBid, let highBidderUIN, let endsAt, _):
            guard var a = active, a.id == auctionID else { return }
            a.highBid = highBid
            a.highBidderUIN = highBidderUIN
            a.highBidderNickname = nick
            a.endsAt = endsAt
            self.active = a
            let bid = UinAuctionBid(
                bidderUIN: bidderUIN,
                bidderNickname: nick,
                amount: amount,
                placedAt: Date(),
            )
            appendBid(bid)
            self.minNextBid = max(highBid + 50, Int(Double(highBid) * 1.05))
            // Soft-close cue: fires once per auction when endsAt enters the 30s window.
            if !softCloseAnnounced {
                let remaining = endsAt.timeIntervalSinceNow
                if remaining > 0 && remaining <= 30 {
                    softCloseAnnounced = true
                    SoundService.shared.play(.auctionSoftClose)
                }
            }
        case .uinAuctionEnded(let auctionID, _, _, let winnerUIN, _):
            guard let a = active, a.id == auctionID else { return }
            self.active = nil
            self.bids = []
            self.minNextBid = 0
            self.softCloseAnnounced = false
            if let me = AuthService.shared.ownUIN, winnerUIN == me {
                celebrateWonUIN = a.uin
                Task { await self.refreshOwned() }
                SoundService.shared.play(.auctionWon)
            }
            Task { await self.refreshRecent() }
        case .uinAuctionOutbid(_, _, let refund, _):
            Task { await ItemsService.shared.refreshInventory() }
            lastError = String(format: "uin_auction.outbid_refund".localized, refund)
            SoundService.shared.play(.auctionOutbid)
            // In-app banner so the user knows they were outbid without
            // having to sit on the auction screen. Tap routes to the
            // auction full-screen so they can rebid in one motion.
            MessageBannerService.shared.tryPresentSystem(
                title: "uin_auction.banner.outbid.title".localized,
                body: String(format: "uin_auction.banner.outbid.body".localized, refund),
                target: .auction,
            )
        default:
            break
        }
    }

    // MARK: - bid list helpers

    /// Prepend a bid, deduping against the recent head. Two bids match
    /// when same bidder, same amount, and within a 5s window — that's
    /// the optimistic-insert vs WS-echo race. Without the dedup the
    /// bidder would see their own bid twice (once from `placeBid`,
    /// once from the `uin_auction_bid` broadcast).
    private func appendBid(_ bid: UinAuctionBid) {
        let dupWindow: TimeInterval = 5
        if let head = bids.first,
           head.bidderUIN == bid.bidderUIN,
           head.amount == bid.amount,
           abs(head.placedAt.timeIntervalSince(bid.placedAt)) <= dupWindow {
            return
        }
        var next = [bid] + bids
        if next.count > 50 { next = Array(next.prefix(50)) }
        bids = next
    }

    // MARK: - error parsing

    private static func parseBidTooLow(_ body: String?) -> BidResult? {
        guard let raw = body?.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let detail = json["detail"] as? [String: Any],
              detail["code"] as? String == "bid_too_low",
              let minReq = detail["min_required"] as? Int else {
            return nil
        }
        return .bidTooLow(minRequired: minReq)
    }

    private static func detectAlreadyHighBidder(_ body: String?) -> Bool {
        guard let raw = body?.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            return false
        }
        if let detail = json["detail"] as? String,
           detail.lowercased().contains("highest bidder") {
            return true
        }
        return false
    }

    private static func parseInsufficient(_ body: String?) -> BidResult? {
        guard let raw = body?.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let detail = json["detail"] as? [String: Any] else {
            return nil
        }
        let required = detail["required"] as? Int ?? 0
        let have = detail["have"] as? Int ?? 0
        return .insufficientTokens(required: required, have: have)
    }

    func acknowledgeError() { lastError = nil }
    func acknowledgeCelebration() { celebrateWonUIN = nil }

    func wipe() {
        active = nil
        bids = []
        owned = []
        recentWinners = []
        celebrateWonUIN = nil
        lastError = nil
    }
}

import Combine
import Foundation

/// Holds the live state of the single active premium-UIN auction +
/// the user's "won UINs" inventory. Subscribes to WS events so the
/// UI ticks in real-time across bid wars and soft-close extensions
/// without the UI needing to poll.
///
/// Single-auction-at-a-time on the server — the iOS view is a
/// dedicated tab in the Games surface that hosts the current round
/// only. Recent winners + history live in a sibling sheet.
@MainActor
final class UinAuctionService: ObservableObject {
    static let shared = UinAuctionService()

    /// Current live auction (or nil during the ~15s gap between rounds).
    @Published private(set) var active: UinAuction?
    /// Bid history for the active auction. Newest first. Capped at
    /// 50 by the server.
    @Published private(set) var bids: [UinAuctionBid] = []
    /// Server-computed minimum next bid (max of starting_bid +5% or
    /// flat +50). Cached after each fetch / live bid.
    @Published private(set) var minNextBid: Int = 0
    /// Premium UINs the user has won. Drives the inventory section.
    @Published private(set) var owned: [OwnedUIN] = []
    /// Last 10 finished auctions for the "history" tab.
    @Published private(set) var recentWinners: [UinAuctionRecentWinner] = []
    /// Sticky surface flag set when the LAST refresh hit a network
    /// error or the user's last bid failed. Surfaced as a one-shot
    /// alert by the view.
    @Published var lastError: String?
    /// Set when an auction ENDED in this session AND the local user
    /// was the winner — drives a celebratory toast in the auction view.
    @Published var celebrateWonUIN: Int?

    // ── Mini-bar state ──────────────────────────────────────────────
    /// True when the user left the full auction view AND has a bid
    /// in the current round (leading or outbid). Drives
    /// `AuctionMinimizedBar` visibility.
    @Published private(set) var isMinimized: Bool = false
    /// User explicitly closed the mini-bar via the X. Suppresses
    /// re-show until the user opens the full auction view again.
    @Published private(set) var isHidden: Bool = false

    /// True if there's a bid by the local user in the current round's
    /// `bids` list — covers both "leading" and "outbid" cases.
    var iHaveBidInRound: Bool {
        guard let me = AuthService.shared.ownUIN else { return false }
        return bids.contains { $0.bidderUIN == me }
    }

    /// True if the local user holds the high bid right now.
    var iAmHighBidder: Bool {
        guard let me = AuthService.shared.ownUIN, let a = active else { return false }
        return a.highBidderUIN == me
    }

    /// Mini-bar shows only when the user actually has skin in the
    /// game — leading or outbid.
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

    /// Pull the active auction snapshot + my owned UINs + recent
    /// winners. Called on tab open and pull-to-refresh.
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

    /// Place a bid. Server deducts the bid amount immediately and
    /// refunds the previous high bidder. On 402 we surface a typed
    /// error so the view can route to the BuyTokens shop instead of
    /// just showing "couldn't bid".
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
            // Wallet just got debited server-side. forceWallet bypasses
            // the defensive max() in refreshInventory so the visible
            // token counter actually drops instead of preserving the
            // pre-bid cached value.
            await ItemsService.shared.refreshInventory(forceWallet: true)
            SoundService.shared.play(.auctionBidPlaced)
            return .success
        } catch APIError.http(400, let body) {
            if let parsed = Self.parseBidTooLow(body) { return parsed }
            if Self.detectAlreadyHighBidder(body) { return .alreadyHighBidder }
            // Never surface raw server JSON to the user — fall back to
            // a localized generic error.
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

    /// Activate a won UIN — kicks the existing migrate flow with
    /// `target_uin` set. Costs 99 tokens (the migrate fee). Returns
    /// the new UIN on success, nil on any failure (the caller surfaces
    /// `lastError`).
    func activate(uin: Int) async -> AppState.MigrationResult {
        await AppState.shared.migrateAccount(targetUIN: uin)
    }

    // MARK: - WS event handling

    /// Set on the first bid event whose `endsAt` lands within the
    /// soft-close window. Used to fire the tense-beep cue exactly
    /// once per auction instead of on every late bid. Reset on a
    /// fresh round.
    private var softCloseAnnounced: Bool = false

    private func handle(_ event: WebSocketService.Event) {
        switch event {
        case .uinAuctionStarted(let auction):
            self.active = auction
            self.bids = []
            self.minNextBid = auction.startingBid
            self.softCloseAnnounced = false
            // Pull recent-winners so the history strip refreshes too.
            Task { await self.refreshRecent() }
        case .uinAuctionBid(let auctionID, let amount, let bidderUIN, let nick, let highBid, let highBidderUIN, let endsAt, _):
            guard var a = active, a.id == auctionID else { return }
            a.highBid = highBid
            a.highBidderUIN = highBidderUIN
            a.highBidderNickname = nick
            a.endsAt = endsAt
            self.active = a
            // Prepend to bid history (newest first, capped at 50).
            let bid = UinAuctionBid(
                bidderUIN: bidderUIN,
                bidderNickname: nick,
                amount: amount,
                placedAt: Date(),
            )
            var nextBids = [bid] + self.bids
            if nextBids.count > 50 { nextBids = Array(nextBids.prefix(50)) }
            self.bids = nextBids
            // Recompute min-next-bid locally so the input field
            // updates without an extra round-trip.
            self.minNextBid = max(highBid + 50, Int(Double(highBid) * 1.05))
            // Soft-close enter cue — fires once per auction the
            // first time a bid's resulting `endsAt` lands within
            // the 30-second soft-close window.
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
            // Was the winner us? Pull updated owned + flag the toast.
            if let me = AuthService.shared.ownUIN, winnerUIN == me {
                celebrateWonUIN = a.uin
                Task { await self.refreshOwned() }
                SoundService.shared.play(.auctionWon)
            }
            Task { await self.refreshRecent() }
        case .uinAuctionOutbid(_, _, let refund, _):
            // Wallet just got the refund credited — refresh visible balance.
            Task { await ItemsService.shared.refreshInventory() }
            lastError = String(format: "uin_auction.outbid_refund".localized, refund)
            SoundService.shared.play(.auctionOutbid)
        default:
            break
        }
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

    /// Server returns `{"detail":"you are already the highest bidder"}`
    /// on a self-outbid attempt — plain string, not the structured
    /// `{detail: {code: ...}}` shape. Match on substring so a backend
    /// copy tweak doesn't break the UX.
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

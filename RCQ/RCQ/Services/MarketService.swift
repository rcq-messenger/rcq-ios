import Combine
import Foundation

/// Live state for the item + UIN marketplaces. Subscribes to WS events
/// so `marketplace_listing_sold` updates "My listings" without polling.
@MainActor
final class MarketService: ObservableObject {
    static let shared = MarketService()

    /// Current browse window. Replaced wholesale on each refresh.
    @Published private(set) var listings: [MarketplaceListing] = []
    @Published private(set) var total: Int = 0
    @Published private(set) var isLoadingMore: Bool = false

    /// Local user's market listings — active + history.
    @Published private(set) var myListings: [MarketplaceListing] = []

    /// UIN listings — parallel surface, keyed on `uin: Int`.
    @Published private(set) var uinListings: [UinMarketplaceListing] = []
    @Published private(set) var uinListingsTotal: Int = 0
    @Published private(set) var isLoadingMoreUins: Bool = false
    @Published private(set) var myUinListings: [UinMarketplaceListing] = []

    private struct ItemPageParams {
        var rarity: ItemRarity?
        var section: ItemSection?
        var kindID: String?
        var minPrice: Int?
        var maxPrice: Int?
        var sort: MarketSort
        var pageSize: Int
    }
    private struct UinPageParams {
        var tier: String?
        var minPrice: Int?
        var maxPrice: Int?
        var sort: MarketSort
        var pageSize: Int
    }
    private var lastItemParams: ItemPageParams?
    private var lastUinParams: UinPageParams?

    /// Set on browse/buy/sell failure. UI surfaces via `acknowledgeError()`.
    @Published var lastError: String?

    /// Set on successful buy/list/cancel — toast trigger.
    @Published var lastSuccessKey: String?

    private var cancellables = Set<AnyCancellable>()

    private init() {
        WebSocketService.shared.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in self?.handle(event) }
            .store(in: &cancellables)
    }

    // ── HTTP ───────────────────────────────────────────────────────

    func refresh(
        rarity: ItemRarity? = nil,
        section: ItemSection? = nil,
        kindID: String? = nil,
        minPrice: Int? = nil,
        maxPrice: Int? = nil,
        sort: MarketSort = .newest,
        limit: Int = 50,
        offset: Int = 0
    ) async {
        let params = ItemPageParams(
            rarity: rarity, section: section, kindID: kindID,
            minPrice: minPrice, maxPrice: maxPrice,
            sort: sort, pageSize: limit,
        )
        struct BrowseOut: Decodable {
            let listings: [MarketplaceListing]
            let total: Int
        }
        let query = buildItemQuery(params: params, offset: offset)
        do {
            let resp: BrowseOut = try await APIClient.shared.request(
                "GET", "/market/listings", query: query
            )
            // offset==0 is a fresh refresh; non-zero is a stale paginate
            // racing a refresh — drop it.
            if offset == 0 {
                self.listings = resp.listings
                self.total = resp.total
                self.lastItemParams = params
            }
        } catch is CancellationError {
            // Stay quiet on cancellation — request was abandoned by us.
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            return
        } catch {
            print("[MarketService] refresh failed: \(error)")
            lastError = "market.error.browse".localized
        }
    }

    /// Append the next page of items using the filters captured by the
    /// last `refresh()`. No-op when nothing more to load or already paging.
    func loadMoreItems() async {
        guard !isLoadingMore else { return }
        guard let params = lastItemParams else { return }
        guard listings.count < total else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        struct BrowseOut: Decodable {
            let listings: [MarketplaceListing]
            let total: Int
        }
        let query = buildItemQuery(params: params, offset: listings.count)
        do {
            let resp: BrowseOut = try await APIClient.shared.request(
                "GET", "/market/listings", query: query
            )
            // De-dup in case a sold/relisted broadcast raced this page.
            let known = Set(listings.map(\.id))
            let fresh = resp.listings.filter { !known.contains($0.id) }
            self.listings.append(contentsOf: fresh)
            self.total = resp.total
        } catch is CancellationError {
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            return
        } catch {
            print("[MarketService] loadMoreItems failed: \(error)")
        }
    }

    private func buildItemQuery(params: ItemPageParams, offset: Int) -> [String: String] {
        // APIClient percent-encodes the path — query params MUST go
        // through `query:`, never appended with `?...` (gets escaped → 404).
        var query: [String: String] = [
            "sort": params.sort.rawValue,
            "limit": String(params.pageSize),
            "offset": String(offset),
        ]
        if let r = params.rarity { query["rarity"] = r.rawValue }
        if let s = params.section { query["section"] = s.rawValue }
        if let k = params.kindID { query["kind_id"] = k }
        if let mn = params.minPrice { query["min_price"] = String(mn) }
        if let mx = params.maxPrice { query["max_price"] = String(mx) }
        return query
    }

    func refreshMine() async {
        do {
            let list: [MarketplaceListing] = try await APIClient.shared.request(
                "GET", "/market/listings/mine"
            )
            self.myListings = list
        } catch {
            print("[MarketService] refreshMine failed: \(error)")
        }
    }

    /// Single-listing fetch used by `MarketLinkBubble` (the rich card
    /// rendered for a `rcq://market/{id}` URL embedded in a chat
    /// message) and by the deep-link open path. Returns nil for 404,
    /// network failure, or any other non-200 — callers fall back to
    /// the plain URL bubble in that case.
    func fetchListing(id: String) async -> MarketplaceListing? {
        do {
            let listing: MarketplaceListing = try await APIClient.shared.request(
                "GET", "/market/listings/\(id)"
            )
            return listing
        } catch {
            return nil
        }
    }

    /// Parallel of `fetchListing(id:)` for the UIN marketplace.
    func fetchUinListing(id: String) async -> UinMarketplaceListing? {
        do {
            let listing: UinMarketplaceListing = try await APIClient.shared.request(
                "GET", "/market/uin-listings/\(id)"
            )
            return listing
        } catch {
            return nil
        }
    }

    enum ListResult {
        case success(MarketplaceListing)
        case alreadyListed
        case equipped
        case tooManyListings(max: Int)
        case other(String)
    }

    func list(itemID: String, priceTokens: Int) async -> ListResult {
        struct Body: Encodable { let item_id: String; let price_tokens: Int }
        do {
            let listing: MarketplaceListing = try await APIClient.shared.request(
                "POST", "/market/listings",
                body: Body(item_id: itemID, price_tokens: priceTokens)
            )
            myListings.insert(listing, at: 0)
            await ItemsService.shared.refreshInventory(forceWallet: true)
            lastSuccessKey = "market.success.listed"
            return .success(listing)
        } catch APIError.http(409, let body) {
            if let code = Self.parseCode(body) {
                switch code {
                case "already_listed": return .alreadyListed
                case "item_equipped": return .equipped
                case "too_many_listings":
                    return .tooManyListings(max: Self.parseMax(body) ?? 20)
                default: break
                }
            }
            return .other("market.error.list".localized)
        } catch {
            return .other(error.localizedDescription)
        }
    }

    enum BuyResult {
        case success(MarketplaceListing)
        case insufficientTokens(required: Int, have: Int)
        case notActive
        case selfBuy
        case ownershipDrift
        case itemGone
        case other(String)
    }

    func buy(listingID: String) async -> BuyResult {
        struct Out: Decodable {
            let listing: MarketplaceListing
            let wallet: Wallet
        }
        do {
            let resp: Out = try await APIClient.shared.request(
                "POST", "/market/listings/\(listingID)/buy"
            )
            // Mirror authoritative wallet so the badge ticks down
            // before the next /me/inventory resolves.
            ItemsService.shared.setWalletTokens(resp.wallet.tokens)
            // Drop the bought row locally — server has marked it sold.
            listings.removeAll { $0.id == listingID }
            await ItemsService.shared.refreshInventory(forceWallet: true)
            lastSuccessKey = "market.success.bought"
            return .success(resp.listing)
        } catch APIError.http(402, let body) {
            if let req = Self.parseInt(body, key: "required"),
               let have = Self.parseInt(body, key: "have") {
                return .insufficientTokens(required: req, have: have)
            }
            return .other("market.error.buy".localized)
        } catch APIError.http(409, let body) {
            if let code = Self.parseCode(body) {
                switch code {
                case "self_buy": return .selfBuy
                case "ownership_drift": return .ownershipDrift
                case "listing_not_active": return .notActive
                default: break
                }
            }
            return .other("market.error.buy".localized)
        } catch APIError.http(410, _) {
            return .itemGone
        } catch {
            return .other(error.localizedDescription)
        }
    }

    enum CancelResult {
        case success(MarketplaceListing)
        case notActive
        case other(String)
    }

    func cancel(listingID: String) async -> CancelResult {
        do {
            let listing: MarketplaceListing = try await APIClient.shared.request(
                "DELETE", "/market/listings/\(listingID)"
            )
            if let idx = myListings.firstIndex(where: { $0.id == listingID }) {
                myListings[idx] = listing
            }
            await ItemsService.shared.refreshInventory()
            lastSuccessKey = "market.success.cancelled"
            return .success(listing)
        } catch APIError.http(409, _) {
            return .notActive
        } catch {
            return .other(error.localizedDescription)
        }
    }

    // ── UIN marketplace HTTP ──────────────────────────────────────

    /// Tier filter: "common" / "mid" / "legendary".
    func refreshUinListings(
        tier: String? = nil,
        minPrice: Int? = nil,
        maxPrice: Int? = nil,
        sort: MarketSort = .newest,
        limit: Int = 50,
        offset: Int = 0
    ) async {
        let params = UinPageParams(
            tier: tier, minPrice: minPrice, maxPrice: maxPrice,
            sort: sort, pageSize: limit,
        )
        struct BrowseOut: Decodable {
            let listings: [UinMarketplaceListing]
            let total: Int
        }
        let query = buildUinQuery(params: params, offset: offset)
        do {
            let resp: BrowseOut = try await APIClient.shared.request(
                "GET", "/market/uin-listings", query: query
            )
            if offset == 0 {
                self.uinListings = resp.listings
                self.uinListingsTotal = resp.total
                self.lastUinParams = params
            }
        } catch is CancellationError {
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            return
        } catch {
            print("[MarketService] refreshUinListings failed: \(error)")
            lastError = "market.error.browse".localized
        }
    }

    func loadMoreUins() async {
        guard !isLoadingMoreUins else { return }
        guard let params = lastUinParams else { return }
        guard uinListings.count < uinListingsTotal else { return }
        isLoadingMoreUins = true
        defer { isLoadingMoreUins = false }
        struct BrowseOut: Decodable {
            let listings: [UinMarketplaceListing]
            let total: Int
        }
        let query = buildUinQuery(params: params, offset: uinListings.count)
        do {
            let resp: BrowseOut = try await APIClient.shared.request(
                "GET", "/market/uin-listings", query: query
            )
            let known = Set(uinListings.map(\.id))
            let fresh = resp.listings.filter { !known.contains($0.id) }
            self.uinListings.append(contentsOf: fresh)
            self.uinListingsTotal = resp.total
        } catch is CancellationError {
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            return
        } catch {
            print("[MarketService] loadMoreUins failed: \(error)")
        }
    }

    private func buildUinQuery(params: UinPageParams, offset: Int) -> [String: String] {
        var query: [String: String] = [
            "sort": params.sort.rawValue,
            "limit": String(params.pageSize),
            "offset": String(offset),
        ]
        if let t = params.tier { query["tier"] = t }
        if let mn = params.minPrice { query["min_price"] = String(mn) }
        if let mx = params.maxPrice { query["max_price"] = String(mx) }
        return query
    }

    func refreshMyUinListings() async {
        do {
            let list: [UinMarketplaceListing] = try await APIClient.shared.request(
                "GET", "/market/uin-listings/mine"
            )
            self.myUinListings = list
        } catch {
            print("[MarketService] refreshMyUinListings failed: \(error)")
        }
    }

    enum ListUinResult {
        case success(UinMarketplaceListing)
        /// UIN isn't in the user's OwnedUin inventory (or it's the active identity).
        case notInInventory
        case alreadyListed
        case tooManyListings(max: Int)
        case other(String)
    }

    func listUin(uin: Int, priceTokens: Int) async -> ListUinResult {
        struct Body: Encodable { let uin: Int; let price_tokens: Int }
        do {
            let listing: UinMarketplaceListing = try await APIClient.shared.request(
                "POST", "/market/uin-listings",
                body: Body(uin: uin, price_tokens: priceTokens)
            )
            myUinListings.insert(listing, at: 0)
            lastSuccessKey = "market.success.listed"
            return .success(listing)
        } catch APIError.http(403, _) {
            return .notInInventory
        } catch APIError.http(409, let body) {
            if let code = Self.parseCode(body) {
                switch code {
                case "already_listed": return .alreadyListed
                case "too_many_uin_listings":
                    return .tooManyListings(max: Self.parseMax(body) ?? 5)
                default: break
                }
            }
            return .other("market.error.list".localized)
        } catch {
            return .other(error.localizedDescription)
        }
    }

    enum BuyUinResult {
        case success(UinMarketplaceListing)
        case insufficientTokens(required: Int, have: Int)
        case notActive
        case selfBuy
        case ownershipDrift
        case uinGone
        case other(String)
    }

    func buyUin(listingID: String) async -> BuyUinResult {
        struct Out: Decodable {
            let listing: UinMarketplaceListing
            let wallet: Wallet
        }
        do {
            let resp: Out = try await APIClient.shared.request(
                "POST", "/market/uin-listings/\(listingID)/buy"
            )
            ItemsService.shared.setWalletTokens(resp.wallet.tokens)
            uinListings.removeAll { $0.id == listingID }
            // Buyer's OwnedUIN inventory gained a UIN — refresh auction service.
            Task { await UinAuctionService.shared.refreshOwned() }
            lastSuccessKey = "market.success.bought"
            return .success(resp.listing)
        } catch APIError.http(402, let body) {
            if let req = Self.parseInt(body, key: "required"),
               let have = Self.parseInt(body, key: "have") {
                return .insufficientTokens(required: req, have: have)
            }
            return .other("market.error.buy".localized)
        } catch APIError.http(409, let body) {
            if let code = Self.parseCode(body) {
                switch code {
                case "self_buy": return .selfBuy
                case "ownership_drift": return .ownershipDrift
                case "listing_not_active": return .notActive
                default: break
                }
            }
            return .other("market.error.buy".localized)
        } catch APIError.http(410, _) {
            return .uinGone
        } catch {
            return .other(error.localizedDescription)
        }
    }

    enum CancelUinResult {
        case success(UinMarketplaceListing)
        case notActive
        case other(String)
    }

    func cancelUin(listingID: String) async -> CancelUinResult {
        do {
            let listing: UinMarketplaceListing = try await APIClient.shared.request(
                "DELETE", "/market/uin-listings/\(listingID)"
            )
            if let idx = myUinListings.firstIndex(where: { $0.id == listingID }) {
                myUinListings[idx] = listing
            }
            lastSuccessKey = "market.success.cancelled"
            return .success(listing)
        } catch APIError.http(409, _) {
            return .notActive
        } catch {
            return .other(error.localizedDescription)
        }
    }

    // ── WS event handling ─────────────────────────────────────────

    private func handle(_ event: WebSocketService.Event) {
        switch event {
        case .marketplaceListingSold(let listing):
            if let idx = myListings.firstIndex(where: { $0.id == listing.id }) {
                myListings[idx] = listing
            } else {
                myListings.insert(listing, at: 0)
            }
            // forceWallet bypasses the defensive max() reconciliation.
            Task { await ItemsService.shared.refreshInventory(forceWallet: true) }
        case .uinMarketplaceListingSold(let listing):
            if let idx = myUinListings.firstIndex(where: { $0.id == listing.id }) {
                myUinListings[idx] = listing
            } else {
                myUinListings.insert(listing, at: 0)
            }
            Task { await ItemsService.shared.refreshInventory(forceWallet: true) }
            Task { await UinAuctionService.shared.refreshOwned() }
        default:
            break
        }
    }

    // ── Error parsing helpers ─────────────────────────────────────

    func acknowledgeError() { lastError = nil }
    func acknowledgeSuccess() { lastSuccessKey = nil }

    func wipe() {
        listings.removeAll()
        myListings.removeAll()
        uinListings.removeAll()
        myUinListings.removeAll()
        total = 0
        uinListingsTotal = 0
        lastItemParams = nil
        lastUinParams = nil
        isLoadingMore = false
        isLoadingMoreUins = false
        lastError = nil
        lastSuccessKey = nil
    }

    private static func parseCode(_ body: String?) -> String? {
        guard let raw = body?.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let detail = json["detail"] as? [String: Any] else {
            return nil
        }
        return detail["code"] as? String
    }

    private static func parseMax(_ body: String?) -> Int? {
        return parseInt(body, key: "max")
    }

    private static func parseInt(_ body: String?, key: String) -> Int? {
        guard let raw = body?.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let detail = json["detail"] as? [String: Any] else {
            return nil
        }
        return detail[key] as? Int
    }
}

import Combine
import Foundation

/// Live state holder for the item marketplace. Browses listings,
/// owns the user's own active+resolved listings, exposes the buy /
/// sell / cancel transactions. Subscribes to the WS event stream so
/// `marketplace_listing_sold` flips the seller's "My listings" view
/// without polling.
@MainActor
final class MarketService: ObservableObject {
    static let shared = MarketService()

    /// Current browse window. Replaced wholesale on each refresh
    /// (no incremental pagination yet — closed-beta size makes
    /// 100-row chunks reasonable).
    @Published private(set) var listings: [MarketplaceListing] = []
    /// Total count reported by the server for the active filter. Used
    /// by the UI to render "Showing 50 of N" hints.
    @Published private(set) var total: Int = 0

    /// Listings the local user has on the market — active + history.
    @Published private(set) var myListings: [MarketplaceListing] = []

    /// UIN listings on the parallel UIN-marketplace surface. Same
    /// browse/buy/cancel shape as items, just keyed on a `uin: Int`
    /// instead of an item snapshot.
    @Published private(set) var uinListings: [UinMarketplaceListing] = []
    @Published private(set) var uinListingsTotal: Int = 0
    @Published private(set) var myUinListings: [UinMarketplaceListing] = []

    /// Sticky surface flag — set when the last browse / buy / sell
    /// failed. UI surfaces a one-shot alert via `acknowledgeError()`.
    @Published var lastError: String?

    /// Set on a successful buy/list/cancel — toast trigger in the UI.
    @Published var lastSuccessKey: String?

    private var cancellables = Set<AnyCancellable>()

    private init() {
        WebSocketService.shared.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in self?.handle(event) }
            .store(in: &cancellables)
    }

    // ── HTTP ───────────────────────────────────────────────────────

    /// Browse with optional filters. The view passes its current
    /// filter chip set + sort + price range; we just forward them.
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
        struct BrowseOut: Decodable {
            let listings: [MarketplaceListing]
            let total: Int
        }
        // APIClient percent-encodes the path verbatim — query params
        // MUST go through the typed `query:` argument, not appended
        // into the URL with `?...` (which gets escaped to `%3F` and
        // ends up as part of the path → 404).
        var query: [String: String] = [
            "sort": sort.rawValue,
            "limit": String(limit),
            "offset": String(offset),
        ]
        if let rarity { query["rarity"] = rarity.rawValue }
        if let section { query["section"] = section.rawValue }
        if let kindID { query["kind_id"] = kindID }
        if let minPrice { query["min_price"] = String(minPrice) }
        if let maxPrice { query["max_price"] = String(maxPrice) }
        do {
            let resp: BrowseOut = try await APIClient.shared.request(
                "GET", "/market/listings", query: query
            )
            self.listings = resp.listings
            self.total = resp.total
        } catch is CancellationError {
            // Pull-to-refresh + an immediately-following category
            // toggle (or view dismiss) cancels the in-flight request.
            // Surfacing that as "couldn't load market" was wrong —
            // the request was abandoned by us, not failed by the
            // server. Stay quiet on the cancel path.
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            // URLSession-level cancellation — same story.
            return
        } catch {
            print("[MarketService] refresh failed: \(error)")
            lastError = "market.error.browse".localized
        }
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

    /// List `item` for `priceTokens`. On success we refresh the
    /// inventory so the tile gets its `listed` badge, and re-fetch
    /// "My listings" so the new row shows up.
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
            // Authoritative new wallet after the deduction. Mirror it
            // straight in so the inventory wallet badge ticks down
            // before the next /me/inventory refresh resolves.
            ItemsService.shared.setWalletTokens(resp.wallet.tokens)
            // Drop the bought row from the live browse list locally
            // — the server has marked it sold, but the UI shouldn't
            // wait on a re-fetch to reflect that.
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
            // Mirror locally: bump the row out of "My listings"' active
            // section by re-pulling. Inventory tile loses its badge on
            // next inventory refresh.
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

    /// Browse UIN listings. Tier filter accepts "common" / "mid" /
    /// "legendary" (matches backend regex). Sort + price-range mirror
    /// the item-marketplace shape.
    func refreshUinListings(
        tier: String? = nil,
        minPrice: Int? = nil,
        maxPrice: Int? = nil,
        sort: MarketSort = .newest,
        limit: Int = 50,
        offset: Int = 0
    ) async {
        struct BrowseOut: Decodable {
            let listings: [UinMarketplaceListing]
            let total: Int
        }
        var query: [String: String] = [
            "sort": sort.rawValue,
            "limit": String(limit),
            "offset": String(offset),
        ]
        if let tier { query["tier"] = tier }
        if let minPrice { query["min_price"] = String(minPrice) }
        if let maxPrice { query["max_price"] = String(maxPrice) }
        do {
            let resp: BrowseOut = try await APIClient.shared.request(
                "GET", "/market/uin-listings", query: query
            )
            self.uinListings = resp.listings
            self.uinListingsTotal = resp.total
        } catch is CancellationError {
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            return
        } catch {
            print("[MarketService] refreshUinListings failed: \(error)")
            lastError = "market.error.browse".localized
        }
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
        /// UIN isn't in the local user's `OwnedUin` inventory (or it's
        /// the active identity — same backend code path).
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
            // Buyer's OwnedUIN inventory just gained a UIN — refresh
            // the auction service which holds that list.
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
            // Replace the row in `myListings` with the resolved version
            // so "My listings" tab shows it as sold + crediting payout.
            if let idx = myListings.firstIndex(where: { $0.id == listing.id }) {
                myListings[idx] = listing
            } else {
                myListings.insert(listing, at: 0)
            }
            // Wallet got credited server-side — re-fetch so the UI
            // catches up immediately. forceWallet bypasses the
            // defensive max() reconciliation.
            Task { await ItemsService.shared.refreshInventory(forceWallet: true) }
        case .uinMarketplaceListingSold(let listing):
            // Same pattern as items — patch myUinListings, refresh wallet,
            // and refresh OwnedUINs so the seller's inventory loses the
            // UIN that just changed hands.
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

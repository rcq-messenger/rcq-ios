import Combine
import Foundation
import UIKit

/// Item / inventory / wallet store. Single source of truth on the
/// server; this class is just a published cache of the latest server
/// response. Everywhere SwiftUI needs inventory it observes
/// `ItemsService.shared` and reads `items` / `wallet` / `catalog`.
///
/// Defensive reconcile: when refreshing wallet from a partial response
/// (e.g. `/me/inventory`), apply `max(local, server)` so an in-flight
/// grant the server hasn't seen yet doesn't get clobbered. Authoritative
/// responses (`/pulls/open`, `/tokens/buy-pack`) overwrite directly —
/// they're the single transaction the server just committed.
@MainActor
final class ItemsService: ObservableObject {
    static let shared = ItemsService()

    @Published private(set) var catalog: ItemCatalog?
    @Published private(set) var items: [Item] = []
    @Published private(set) var wallet: Wallet = Wallet(tokens: 0, scrolls: 0)
    @Published private(set) var inventoryPublic: Bool = true

    /// Most recent pull's outcome — drives the LootboxView reveal
    /// overlay. Nil while idle.
    @Published var lastOutcome: PullOutcome?

    private init() {}

    // MARK: - Catalog

    /// Fetch (or refresh) the catalog. Cheap to call; the server
    /// returns ~30 entries even at full size. Idempotent.
    func refreshCatalog() async {
        do {
            let snap: ItemCatalog = try await APIClient.shared.request(
                "GET", "/catalog",
            )
            self.catalog = snap
        } catch {
            #if DEBUG
            print("⚠️ catalog refresh failed: \(error)")
            #endif
        }
    }

    // MARK: - Inventory

    /// `forceWallet=true` overrides the wallet with the server's
    /// snapshot directly, bypassing the defensive max-reconcile.
    /// Used by trade flows where the server's authoritative wallet
    /// is LOWER than the local cache (sender just escrowed tokens
    /// that haven't been reflected locally yet) — max() would
    /// preserve the stale-high local value and the user would
    /// never see their own deduction. The default `false` keeps
    /// the IX-inherited race-defence for cases where local might
    /// be the fresher value (a recent /pulls/open returned a
    /// grant, then a backgrounded /me/inventory races back stale).
    func refreshInventory(forceWallet: Bool = false) async {
        do {
            let snap: InventoryResponse = try await APIClient.shared.request(
                "GET", "/me/inventory",
            )
            self.items = snap.items
            if forceWallet {
                self.wallet = snap.wallet
            } else {
                // Defensive max-policy on wallet — see header comment.
                self.wallet = Wallet(
                    tokens: max(self.wallet.tokens, snap.wallet.tokens),
                    scrolls: max(self.wallet.scrolls, snap.wallet.scrolls),
                )
            }
            self.inventoryPublic = snap.public
        } catch {
            #if DEBUG
            print("⚠️ inventory refresh failed: \(error)")
            #endif
        }
    }

    /// Apply an in-flight delta to the wallet without round-tripping
    /// the server. Used by the trade-propose path for an optimistic
    /// local decrement so the sender sees their balance drop the
    /// instant they hit "Send" instead of waiting on the next
    /// inventory refresh. Caller is expected to revert on API
    /// failure. Clamps at 0 — never produces negative balances.
    func applyWalletDelta(tokens: Int = 0, scrolls: Int = 0) {
        self.wallet = Wallet(
            tokens: max(0, self.wallet.tokens + tokens),
            scrolls: max(0, self.wallet.scrolls + scrolls)
        )
    }

    /// Push an authoritative wallet snapshot from a non-inventory
    /// endpoint (Crash bet / cashout, future game settlements). Server
    /// returns the new absolute balance in its reply; we mirror it
    /// straight into the canonical `wallet` so every observer (toolbar
    /// badges, inventory grid wallet panel) updates in lockstep
    /// without waiting on a `/me/inventory` refresh.
    func setWalletTokens(_ tokens: Int) {
        self.wallet = Wallet(tokens: max(0, tokens), scrolls: self.wallet.scrolls)
    }

    /// Own equipped pet derived from the in-memory item list — used
    /// by the contact-list header (own status icon overlay) and any
    /// other surface that needs to render "what's MY pet right now"
    /// without an extra round-trip. Server-side `equipped_pet` on
    /// `/users/{ownUIN}/info` is the same value; this is the locally-
    /// cached version that reflects equip toggles instantly.
    var ownEquippedPet: EquippedPet? {
        guard let catalog = self.catalog else { return nil }
        for item in items where item.equipped {
            guard let kind = catalog.kind(by: item.kindID),
                  kind.appliesAs == .petCompanion else { continue }
            return EquippedPet(
                instanceID: item.id,
                kindID: item.kindID,
                rarity: item.rarity,
                mintNumber: item.mintNumber,
                level: item.level,
                baseEssence: item.baseEssence,
                purity: item.purity,
            )
        }
        return nil
    }

    func setInventoryPublic(_ value: Bool) async {
        do {
            let snap: InventoryResponse = try await APIClient.shared.request(
                "POST", "/me/inventory/privacy",
                body: ["public": value],
            )
            self.items = snap.items
            self.wallet = snap.wallet  // server-authoritative on this round-trip
            self.inventoryPublic = snap.public
        } catch {
            #if DEBUG
            print("⚠️ privacy toggle failed: \(error)")
            #endif
        }
    }

    // MARK: - Pull

    /// Open one box. Costs `catalog.pull_cost` tokens (default 2 —
    /// server is the source of truth, client uses the catalog
    /// snapshot for the wallet pre-flight). Returns either an
    /// item or a scroll bundle.
    @discardableResult
    func openPull() async -> PullOutcome? {
        let cost = catalog?.pullCost ?? 2
        guard wallet.tokens >= cost else { return nil }
        do {
            let res: PullResultResponse = try await APIClient.shared.request(
                "POST", "/pulls/open",
                body: EmptyBody(),
            )
            self.wallet = res.wallet
            switch res.outcome {
            case "item":
                guard let item = res.item else { return nil }
                self.items.insert(item, at: 0)
                let outcome = PullOutcome.item(item)
                self.lastOutcome = outcome
                return outcome
            case "scroll":
                guard let n = res.scrollYield else { return nil }
                let outcome = PullOutcome.scroll(count: n)
                self.lastOutcome = outcome
                return outcome
            default:
                #if DEBUG
                print("⚠️ unknown pull outcome: \(res.outcome)")
                #endif
                return nil
            }
        } catch {
            #if DEBUG
            print("⚠️ pull failed: \(error)")
            #endif
            return nil
        }
    }

    // MARK: - Temper / equip / disassemble (Session 2)

    /// Attempt a temper roll on an item. Server is authoritative —
    /// it deducts the scroll cost, rolls success against the same
    /// table the iOS pre-flight uses, and either bumps the level or
    /// destroys the row outright. iOS reconciles from the response;
    /// no local roll, no local scroll math.
    @discardableResult
    func temper(_ item: Item) async -> TemperOutcome? {
        guard wallet.scrolls >= TemperTables.scrollCost(at: item.level) else {
            return nil
        }
        guard items.contains(where: { $0.id == item.id }) else { return nil }
        let serverID = item.id.lowercased()
        do {
            let res: TemperResponse = try await APIClient.shared.request(
                "POST", "/items/\(serverID)/temper",
                body: EmptyBody(),
            )
            self.wallet = res.wallet
            switch res.outcome {
            case "success":
                guard let updated = res.item else { return nil }
                if let idx = items.firstIndex(where: { $0.id == item.id }) {
                    items[idx] = updated
                }
                return .success(newLevel: res.newLevel ?? updated.level, item: updated)
            case "burned":
                items.removeAll { $0.id == item.id }
                return .burned
            default:
                return nil
            }
        } catch {
            #if DEBUG
            print("⚠️ temper failed: \(error)")
            #endif
            return nil
        }
    }

    /// Toggle equip flag on a cosmetic. Server enforces per-kind
    /// exclusivity (only one instance of any kind can be equipped
    /// at once); skin themes are stricter (one skin total). Smiley /
    /// voice packs across different kinds stack additively.
    @discardableResult
    func toggleEquip(_ item: Item) async -> Bool {
        let serverID = item.id.lowercased()
        let nextEquipped = !item.equipped
        do {
            let res: Item = try await APIClient.shared.request(
                "POST", "/items/\(serverID)/equip",
                body: ["equipped": nextEquipped],
            )
            // Light haptic on successful flip — mirrors how the
            // status / TTL toggles in chat feel. Equip = pulse,
            // unequip = same; the user gets the same texture either
            // direction so they know the tap landed without having
            // to glance at the label change.
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            // Refresh inventory to pick up server-side knock-on
            // unequips (per-kind dups, skin exclusivity).
            await refreshInventory()
            if let idx = items.firstIndex(where: { $0.id == item.id }) {
                items[idx] = res
            }
            return true
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            #if DEBUG
            print("⚠️ toggleEquip failed: \(error)")
            #endif
            return false
        }
    }

    /// Disassemble — destroy item, gain scrolls + tokens. Burn is
    /// final, no recovery (same policy as the temper-burn path).
    /// Returns (scroll yield, token yield).
    @discardableResult
    func disassemble(_ item: Item) async -> DisassembleYield? {
        let serverID = item.id.lowercased()
        do {
            let res: DisassembleResponse = try await APIClient.shared.request(
                "POST", "/items/\(serverID)/disassemble",
                body: EmptyBody(),
            )
            self.wallet = res.wallet
            self.items.removeAll { $0.id == item.id }
            return DisassembleYield(scrolls: res.scrollYield, tokens: res.tokenYield)
        } catch {
            #if DEBUG
            print("⚠️ disassemble failed: \(error)")
            #endif
            return nil
        }
    }

    /// Bulk-disassemble. Server skips silently over stale ids (e.g.
    /// the user's selection includes an item that's been traded
    /// away in the same window) and returns only the ids that
    /// actually got destroyed.
    @discardableResult
    func disassembleBulk(_ batch: [Item]) async -> DisassembleYield? {
        guard !batch.isEmpty else { return nil }
        struct Body: Encodable { let item_ids: [String] }
        let body = Body(item_ids: batch.map { $0.id.lowercased() })
        do {
            let res: BulkDisassembleResponse = try await APIClient.shared.request(
                "POST", "/items/disassemble-bulk", body: body,
            )
            self.wallet = res.wallet
            let killed = Set(res.disassembledIDs)
            self.items.removeAll { killed.contains($0.id) }
            return DisassembleYield(scrolls: res.scrollYield, tokens: res.tokenYield)
        } catch {
            #if DEBUG
            print("⚠️ disassembleBulk failed: \(error)")
            #endif
            return nil
        }
    }

    // MARK: - Tokens

    /// Mock IAP — tap a pack, server credits the wallet immediately.
    /// Real StoreKit lands in Session 5; this stays as the dev path.
    @discardableResult
    func buyTokenPack(_ pack: TokenPack) async -> Bool {
        do {
            let res: Wallet = try await APIClient.shared.request(
                "POST", "/tokens/buy-pack",
                body: ["pack_id": pack.id],
            )
            self.wallet = res
            return true
        } catch {
            #if DEBUG
            print("⚠️ buyTokenPack failed: \(error)")
            #endif
            return false
        }
    }

    /// Dev-only token grant (server-gated on ENV != "prod"). Useful
    /// for debugging via the override base URL.
    @discardableResult
    func debugGrantTokens(_ tokens: Int) async -> Bool {
        do {
            let res: Wallet = try await APIClient.shared.request(
                "POST", "/debug/grant-tokens",
                body: ["tokens": tokens],
            )
            self.wallet = res
            return true
        } catch {
            #if DEBUG
            print("⚠️ debugGrantTokens failed: \(error)")
            #endif
            return false
        }
    }
}

// MARK: - Wire types

private struct InventoryResponse: Codable {
    let wallet: Wallet
    let items: [Item]
    let `public`: Bool
}

private struct PullResultResponse: Codable {
    let outcome: String
    let item: Item?
    let scrollYield: Int?
    let wallet: Wallet

    enum CodingKeys: String, CodingKey {
        case outcome, item
        case scrollYield = "scroll_yield"
        case wallet
    }
}

private struct EmptyBody: Encodable {}

/// Surfaced to the LootboxView to drive the reveal overlay.
enum PullOutcome: Equatable {
    case item(Item)
    case scroll(count: Int)
}

/// Outcome of a temper attempt — UI surfaces a celebratory or
/// dedicated burn screen depending on the value.
enum TemperOutcome: Equatable {
    case success(newLevel: Int, item: Item)
    case burned
}

private struct TemperResponse: Codable {
    let outcome: String
    let newLevel: Int?
    let item: Item?
    let wallet: Wallet

    enum CodingKeys: String, CodingKey {
        case outcome
        case newLevel = "new_level"
        case item, wallet
    }
}

struct DisassembleYield: Equatable {
    let scrolls: Int
    let tokens: Int
}

private struct DisassembleResponse: Codable {
    let scrollYield: Int
    let tokenYield: Int
    let wallet: Wallet

    enum CodingKeys: String, CodingKey {
        case scrollYield = "scroll_yield"
        case tokenYield = "token_yield"
        case wallet
    }
}

private struct BulkDisassembleResponse: Codable {
    let scrollYield: Int
    let tokenYield: Int
    let disassembledIDs: [String]
    let wallet: Wallet

    enum CodingKeys: String, CodingKey {
        case scrollYield = "scroll_yield"
        case tokenYield = "token_yield"
        case disassembledIDs = "disassembled_ids"
        case wallet
    }
}

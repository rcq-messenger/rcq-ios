import Combine
import Foundation
import UIKit

/// Published cache of inventory/wallet/catalog. Server is the source of truth.
@MainActor
final class ItemsService: ObservableObject {
    static let shared = ItemsService()

    @Published private(set) var catalog: ItemCatalog?
    @Published private(set) var items: [Item] = []
    @Published private(set) var wallet: Wallet = Wallet(tokens: 0, scrolls: 0)
    @Published private(set) var inventoryPublic: Bool = true

    @Published var lastOutcome: PullOutcome?

    private init() {}

    // MARK: - Catalog

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

    /// `forceWallet=true` overwrites the wallet directly; default uses max(local, server) to avoid clobbering in-flight grants.
    func refreshInventory(forceWallet: Bool = false) async {
        do {
            let snap: InventoryResponse = try await APIClient.shared.request(
                "GET", "/me/inventory",
            )
            self.items = snap.items
            if forceWallet {
                self.wallet = snap.wallet
            } else {
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

    /// Optimistic local delta. Caller reverts on failure. Clamps at 0.
    func applyWalletDelta(tokens: Int = 0, scrolls: Int = 0) {
        self.wallet = Wallet(
            tokens: max(0, self.wallet.tokens + tokens),
            scrolls: max(0, self.wallet.scrolls + scrolls)
        )
    }

    /// Authoritative token snapshot from a non-inventory endpoint (e.g. Crash settlements).
    func setWalletTokens(_ tokens: Int) {
        self.wallet = Wallet(tokens: max(0, tokens), scrolls: self.wallet.scrolls)
    }

    /// Own equipped pet derived from the in-memory item list.
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
            self.wallet = snap.wallet
            self.inventoryPublic = snap.public
        } catch {
            #if DEBUG
            print("⚠️ privacy toggle failed: \(error)")
            #endif
        }
    }

    // MARK: - Pull

    /// Open one box. `boost` is the pet-boost slider position [0,1] —
    /// raises pet odds + price. Returns either an item or a scroll
    /// bundle.
    @discardableResult
    func openPull(boost: Double = 0) async -> PullOutcome? {
        let cost = catalog?.boostedPullCost(boost) ?? (catalog?.pullCost ?? 2)
        guard wallet.tokens >= cost else { return nil }
        SmokeTracker.shared.tick(.openLootbox)
        struct OpenPullBody: Encodable { let boost: Double }
        do {
            let res: PullResultResponse = try await APIClient.shared.request(
                "POST", "/pulls/open",
                body: OpenPullBody(boost: boost),
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

    // MARK: - Temper / equip / disassemble

    /// Server-authoritative temper roll. Reconciles from response.
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

    /// Toggle equip flag. Server enforces per-kind exclusivity.
    @discardableResult
    func toggleEquip(_ item: Item) async -> Bool {
        let serverID = item.id.lowercased()
        let nextEquipped = !item.equipped
        do {
            let res: Item = try await APIClient.shared.request(
                "POST", "/items/\(serverID)/equip",
                body: ["equipped": nextEquipped],
            )
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
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

    /// Destroy item, gain scrolls + tokens. Burn is final.
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

    /// Bulk-disassemble. Server returns only the ids actually destroyed.
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

    /// Mock IAP. Server credits the wallet immediately.
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

    /// Dev-only token grant (server-gated on ENV != "prod").
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

enum PullOutcome: Equatable {
    case item(Item)
    case scroll(count: Int)
}

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

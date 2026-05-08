import Foundation

/// Snapshot of the user's currently equipped pet, returned with
/// `/pets/hunt/state`. Lightweight — full inventory query stays a
/// separate call.
struct HuntPetSummary: Codable, Hashable {
    let instanceID: String
    let kindID: String
    let rarity: ItemRarity
    let level: Int
    let purity: Double
    let baseEssence: Int
    let mintNumber: Int?

    enum CodingKeys: String, CodingKey {
        case instanceID = "instance_id"
        case kindID = "kind_id"
        case rarity, level, purity
        case baseEssence = "base_essence"
        case mintNumber = "mint_number"
    }
}

/// Pet Hunt main-screen state. Mirrors backend `HuntStateOut`.
/// `accumulated` is computed server-side at request time off
/// `lastClaimAt` — client renders it as-is + ticks it forward
/// locally between refreshes.
struct HuntState: Codable, Hashable {
    let pet: HuntPetSummary?
    let accumulated: Int        // tokens (жетоны) in mining buffer
    let accumulatedGems: Int    // gems (scrolls col in DB) in buffer
    let dailyYield: Int         // tokens/day at full uptime
    let dailyGems: Int          // gems/day at full uptime
    let capReached: Bool
    let lastClaimAt: Date?
    let huntsUsedToday: Int
    let huntsPerDay: Int
    let nextResetAt: Date

    enum CodingKeys: String, CodingKey {
        case pet, accumulated
        case accumulatedGems = "accumulated_gems"
        case dailyYield = "daily_yield"
        case dailyGems = "daily_gems"
        case capReached = "cap_reached"
        case lastClaimAt = "last_claim_at"
        case huntsUsedToday = "hunts_used_today"
        case huntsPerDay = "hunts_per_day"
        case nextResetAt = "next_reset_at"
    }

    var huntsLeft: Int { max(0, huntsPerDay - huntsUsedToday) }
}

/// One of three hunt zones — easy / medium / hardcore. Reward and
/// risk both scale up the rougher the zone. Pet quality modulates
/// success_rate; failure outcome is wound (-1 level, or death at
/// level 0) or disaster (death regardless).
enum HuntZone: String, Codable, CaseIterable, Identifiable {
    case forest, mountain, cave
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .forest:   return "pet_hunt.zone.forest".localized
        case .mountain: return "pet_hunt.zone.mountain".localized
        case .cave:     return "pet_hunt.zone.cave".localized
        }
    }

    /// Single-character glyph for the zone tile (no asset deps).
    var icon: String {
        switch self {
        case .forest:   return "leaf.fill"
        case .mountain: return "mountain.2.fill"
        case .cave:     return "fossil.shell.fill"
        }
    }
}

/// Result of a single hunt round. Mirrors backend `HuntResultOut`.
/// `outcome` is the canonical key the result-modal switches on;
/// numeric fields fill the body of that modal.
struct HuntResult: Codable, Hashable, Identifiable {
    enum Outcome: String, Codable {
        case success, wound, death
    }

    let outcome: Outcome
    let zone: HuntZone
    let reward: Int             // tokens
    let gemReward: Int          // gems — only > 0 on success
    let newLevel: Int
    let petDied: Bool
    let walletTokens: Int
    let walletGems: Int
    let huntsLeft: Int

    /// Synthetic id so SwiftUI's `.sheet(item:)` binding accepts the
    /// type. Each new hunt-result rolls a fresh UUID server-side so
    /// the sheet re-presents on back-to-back hunts.
    var id: String {
        "\(outcome.rawValue)-\(zone.rawValue)-\(reward)-\(gemReward)-\(newLevel)-\(petDied)"
    }

    enum CodingKeys: String, CodingKey {
        case outcome, zone, reward
        case gemReward = "gem_reward"
        case newLevel = "new_level"
        case petDied = "pet_died"
        case walletTokens = "wallet_tokens"
        case walletGems = "wallet_gems"
        case huntsLeft = "hunts_left"
    }
}

/// One row in the Memorial — a pet that died on a hunt. Surfaced
/// in `InventoryView`'s Memorial section as a read-only tombstone.
struct MemorialEntry: Codable, Hashable, Identifiable {
    let instanceID: String
    let kindID: String
    let rarity: ItemRarity
    let level: Int
    let purity: Double
    let mintNumber: Int?
    let diedAt: Date
    let diedZone: HuntZone?
    let acquiredAt: Date

    var id: String { instanceID }

    enum CodingKeys: String, CodingKey {
        case instanceID = "instance_id"
        case kindID = "kind_id"
        case rarity, level, purity
        case mintNumber = "mint_number"
        case diedAt = "died_at"
        case diedZone = "died_zone"
        case acquiredAt = "acquired_at"
    }
}

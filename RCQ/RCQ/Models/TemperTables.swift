import Foundation

/// Tempering tables — must stay in lockstep with the server's
/// `app/services/lootbox_catalog.py` (or the temper endpoint, which
/// is the single source of truth for the actual roll). The client
/// uses these only to render the confirmation sheet ("80% success,
/// costs 5 scrolls") and to gate the CTA. Drift = the user sees a
/// different number than the server rolls against; both halves must
/// be updated together.
///
/// Fibonacci-like cost ramp paired with a near-Russian-roulette
/// chance curve at the high end.
enum TemperTables {
    static let maxLevel: Int = 9

    /// Cost in scrolls for the +N → +(N+1) attempt.
    static func scrollCost(at level: Int) -> Int {
        let table = [1, 2, 3, 5, 8, 13, 21, 34, 55]
        if level < 0 { return table[0] }
        if level >= table.count { return table.last! }
        return table[level]
    }

    /// Probability the +N → +(N+1) attempt succeeds. Burn = `1 - this`.
    static func successChance(at level: Int) -> Double {
        switch level {
        case 0: return 1.00
        case 1: return 0.90
        case 2: return 0.80
        case 3: return 0.65
        case 4: return 0.50
        case 5: return 0.35
        case 6: return 0.25
        case 7: return 0.15
        case 8: return 0.08
        default: return 0.00
        }
    }
}

/// Disassembly yield. Burn the item, get scrolls + tokens back.
/// Same yield tables as IX, scaled to RCQ rarity tiers. Scrolls are
/// the headline reward; tokens are a steady trickle so users feel
/// progress on the wallet too. Both halves stay in lock-step with
/// `_disassemble_yield` / `_disassemble_tokens` on the server.
enum DisassembleTables {
    /// Scroll refund per disassembled item. Trimmed 2026-05 to keep the
    /// burn loop a controlled scroll faucet (was so generous when
    /// paired with the cheap PULL_COST that users could farm temper
    /// materials free of risk). Server source of truth lives in
    /// `_disassemble_yield` in `routers/items.py` — keep them aligned.
    static func scrollYield(rarity: ItemRarity, level: Int) -> Int {
        let base: Int
        switch rarity {
        case .common:    base = 1
        case .uncommon:  base = 2
        case .rare:      base = 5
        case .epic:      base = 18
        case .legendary: base = 75
        }
        let levelBoost = (Double(level) * 0.5) * Double(base)
        return base + Int(levelBoost.rounded())
    }

    /// Token refund per disassembled item. Trimmed 2026-05 alongside
    /// the PULL_COST 2 → 5 bump so the loop is a real bet again — a
    /// common burn returns ~20% of a fresh pull, an epic ~3 pulls.
    /// Server source of truth: `_disassemble_tokens` in
    /// `routers/items.py`.
    static func tokenYield(rarity: ItemRarity, level: Int) -> Int {
        let base: Int
        switch rarity {
        case .common:    base = 1
        case .uncommon:  base = 3
        case .rare:      base = 7
        case .epic:      base = 15
        case .legendary: base = 40
        }
        let levelBoost = (Double(level) * 0.25) * Double(base)
        return base + Int(levelBoost.rounded())
    }
}

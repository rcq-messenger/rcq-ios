import Foundation

/// Per-pack emoticon manifest. Each cosmetic-smileys kind ships a
/// fixed list of (asset, name, primary shortcode) entries. Equipping
/// the pack adds these on top of the default Kolobok palette — no
/// replacement, no exclusivity, per the smiley-pack rule.
///
/// When a new smiley pack is added on the server, register its kind
/// id and the contained gif filenames here so the client can surface
/// them in the chat picker. The asset filenames must match basenames
/// of files bundled into the iOS Resources tree (xcodegen flattens
/// the `Items/cosm1` subfolder to the .app root, so a plain
/// `Bundle.main.url(forResource:withExtension:)` lookup hits them).
enum CosmeticPacks {
    struct Entry: Hashable {
        let asset: String
        let name: String
        let primaryCode: String
    }

    // All non-default smiley packs were retired (cosmetics removed). The
    // manifest is intentionally empty: the chat picker shows only the
    // built-in Kolobok palette. Re-add a pack here + bundle its gifs to
    // bring one back.
    private static let manifest: [String: [Entry]] = [:]

    static func entries(for kindID: String) -> [Entry] {
        manifest[kindID] ?? []
    }

    /// Every known cosmetic-pack kind id. Used by the unified
    /// emoticon tokenizer so receivers can render pack-emoji even
    /// without equipping the pack themselves (assets are bundled
    /// into the .app regardless).
    static var allKindIDs: [String] {
        Array(manifest.keys)
    }

    /// Reverse lookup from an emoticon asset name to its pack kind id.
    /// Returns nil for default Kolobok glyphs and unknown assets.
    static func kindID(for asset: String) -> String? {
        if let hit = _assetToKind { return hit[asset] }
        var map: [String: String] = [:]
        for (kindID, entries) in manifest {
            for e in entries { map[e.asset] = kindID }
        }
        _assetToKind = map
        return map[asset]
    }

    private static var _assetToKind: [String: String]? = nil
}

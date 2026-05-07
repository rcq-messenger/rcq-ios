import Foundation

/// Per-pack emoticon manifest. Each cosmetic-smileys kind ships a
/// fixed list of (asset, name, primary shortcode) entries. Equipping
/// the pack adds these on top of the default Kolobok palette — no
/// replacement, no exclusivity. Mirrors the user's stated rule for
/// smiley packs.
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

    private static let manifest: [String: [Entry]] = [
        "forum_classics": [
            Entry(asset: "banana",   name: "Banana dance", primaryCode: ":banana:"),
            Entry(asset: "coolblue", name: "Cool blue",    primaryCode: ":coolblue:"),
            Entry(asset: "hail",     name: "Hail",         primaryCode: ":hail:"),
            Entry(asset: "hwluxx",   name: "Hwluxx",       primaryCode: ":hwluxx:"),
            Entry(asset: "mad",      name: "Mad",          primaryCode: ":mad:"),
            Entry(asset: "wallbash", name: "Wallbash",     primaryCode: ":wallbash:"),
        ],
    ]

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
}

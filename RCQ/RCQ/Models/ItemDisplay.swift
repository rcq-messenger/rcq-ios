import Foundation

/// Static slug→display-name mapping for catalog kinds. Lives on the
/// client because the server keeps the catalog as opaque slugs and
/// localization is an iOS concern. When a new kind is seeded on the
/// server, add its display + lore here. Unknown slugs fall back to a
/// titleized version of the slug — visible-but-ugly, surfaces the gap
/// without crashing.
enum ItemDisplay {
    /// Slugs we ship name + lore for. New kinds get added here and a
    /// matching pair of `Localizable.strings` keys
    /// (`item.name.<slug>` / `item.lore.<slug>`) in every lproj. Off
    /// the list, the name fall-back is a titleized version of the
    /// slug (visible-but-ugly, surfaces the gap), lore is `nil`.
    private static let knownSlugs: Set<String> = [
        "pet_trump", "pet_putin", "pet_jobs", "pet_kim",
        "pet_musk", "pet_snoop", "pet_doge", "pet_hamster",
        "pet_black_cat", "pet_devil",
        "forum_classics",
        "voice_pack_1", "voice_pack_2", "voice_pack_3",
        "voice_pack_4", "voice_pack_5", "voice_pack_6",
        "voice_pack_7", "voice_pack_8", "voice_pack_9",
        "voice_pack_10",
    ]

    static func name(for slug: String) -> String {
        guard knownSlugs.contains(slug) else {
            return slug.replacingOccurrences(of: "_", with: " ").capitalized
        }
        return "item.name.\(slug)".localized
    }

    /// Single-line lore string for the detail sheet. Optional —
    /// kinds without lore just hide the line.
    static func lore(for slug: String) -> String? {
        guard knownSlugs.contains(slug) else { return nil }
        return "item.lore.\(slug)".localized
    }
}

import Foundation

/// Lightweight snapshot of a user's currently-equipped pet, surfaced
/// on `Contact`, `UserProfile`, and `RCQGroupMember` payloads. Drives
/// the small overlay GIF on top of the status icon plus the
/// `PetPreviewSheet` when another user taps that overlay.
///
/// Minimal — just enough to render the GIF and route to a public
/// detail view. The full `Item` (with temper level, purity, history)
/// is fetched on demand via `GET /items/{id}` if the preview sheet's
/// "View details" CTA is used.
struct EquippedPet: Codable, Hashable {
    let instanceID: String
    let kindID: String
    /// Per-instance roll. Drives the rarity-tinted ring around the
    /// overlay so a Legendary pet reads as visually richer than a
    /// Common one without opening the sheet.
    let rarity: ItemRarity
    /// Mint slot the pet was rolled into. Server uses these for
    /// vanity badges (#1 / #100 / #777 / #1000 / #10000) on the
    /// public showcase; client renders the same badges on the preview sheet.
    /// Optional: uncapped kinds (no `limit` on KindRow) don't get
    /// minted into a slot at all, so the field is null in the JSON.
    /// A non-optional decode here would fail the whole /contacts
    /// response — see prior incident report.
    let mintNumber: Int?
    /// Temper level (0..9). Currently a hint for the preview sheet
    /// only — could later drive a small progression badge over the
    /// overlay if we want.
    let level: Int
    /// Base essence (rarity-bound 1..8000) and purity (0.6..1.4)
    /// rolls — surfaced on the preview sheet so peers can evaluate
    /// the pet's showcase value at a glance. Optional in the JSON
    /// for backwards-compat with older server builds that didn't
    /// include them.
    let baseEssence: Int?
    let purity: Double?

    enum CodingKeys: String, CodingKey {
        case instanceID = "instance_id"
        case kindID = "kind_id"
        case rarity
        case mintNumber = "mint_number"
        case level
        case baseEssence = "base_essence"
        case purity
    }
}

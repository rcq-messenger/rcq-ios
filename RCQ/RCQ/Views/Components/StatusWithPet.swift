import SwiftUI

/// Status icon with an optional equipped-pet GIF perched on its
/// bottom-right corner. The pet is sized close to the status icon
/// itself (no longer a tiny dot) and bleeds slightly past the
/// status frame via `.overlay` — the parent layout sees only the
/// `StatusIcon`'s frame, so adding a pet does NOT push neighbouring
/// labels around.
///
/// Visual:
///   ┌────────┐
///   │        │
///   │ status │
///   │      ⊙ ← pet (animated, ~95% of status size)
///   └─── ⊙──┘  (bleeds out of the icon's bounds via offset)
///
/// When `pet` is nil, this collapses to a plain `StatusIcon`.
struct StatusWithPet: View {
    let status: UserStatus
    let pet: EquippedPet?
    var size: CGFloat = 24

    /// Observe `ItemsService` so that when the catalog finishes
    /// loading mid-render (e.g. profile opened on cold launch
    /// before AppState.boot's eager refresh resolved), the view
    /// re-evaluates `petBasename(...)` and the GIF appears without
    /// a manual refresh. Read-only — we never write back.
    @StateObject private var items = ItemsService.shared

    /// Pet glyph relative size. ~0.95 makes the pet read as a
    /// "second focal point" sitting next to the status, not just an
    /// ornament. Combined with the bottom-right offset, the pet
    /// overlaps the corner of the status and extends out past it.
    private static let petScale: CGFloat = 0.95

    var body: some View {
        StatusIcon(status: status, size: size)
            // Overlay keeps layout stable: the parent HStack only
            // sees `StatusIcon`'s frame (= `size` × `size`), the pet
            // visually bleeds past the bottom-right corner without
            // claiming extra width — neighbouring nickname / UIN
            // labels stay where they were.
            .overlay(alignment: .bottomTrailing) {
                if let pet, let basename = petBasename(for: pet.kindID) {
                    petGlyph(basename: basename, rarity: pet.rarity)
                        .frame(width: size * Self.petScale,
                               height: size * Self.petScale)
                        // Push the pet diagonally so it sits half-on
                        // the status icon's bottom-right quadrant —
                        // clearly an "addition", not a replacement.
                        // Smaller y nudges the pet upward so it
                        // hugs the status icon's mid-line instead of
                        // dangling off the bottom corner.
                        .offset(x: size * 0.30, y: size * 0.10)
                        .allowsHitTesting(false)  // tap area = StatusIcon frame
                }
            }
    }

    @ViewBuilder
    private func petGlyph(basename: String, rarity: ItemRarity) -> some View {
        ZStack {
            // Soft rarity-tinted halo behind the GIF. Slightly
            // dialed back from the previous tuning — opacity 0.35
            // (was 0.55) so the glow reads as a subtle aura rather
            // than a colored disc behind the pet.
            Circle()
                .fill(rarity.color.opacity(0.35))
                .blur(radius: size * 0.18)
                .scaleEffect(1.10)
            // Bare animated GIF — no clip, no stroke ring. The
            // surrounding glow does the visual "this is a pet"
            // signal without the heavy outline that read as
            // "framed avatar".
            GIFImage(name: basename)
                .shadow(color: .black.opacity(0.30),
                        radius: size * 0.06, x: 0, y: size * 0.04)
        }
    }

    /// Resolve `kind_id` → bundled GIF basename via the catalog
    /// snapshot so adding a new pet kind on the server doesn't
    /// require an iOS code change. Falls back to nil (nothing
    /// renders) if the catalog hasn't loaded yet or the kind is
    /// unknown — `StatusIcon` alone keeps showing.
    private func petBasename(for kindID: String) -> String? {
        guard let kind = items.catalog?.kind(by: kindID) else { return nil }
        let basename = (kind.assetRef as NSString).lastPathComponent
        return (basename as NSString).deletingPathExtension
    }
}

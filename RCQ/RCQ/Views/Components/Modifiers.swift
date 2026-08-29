import SwiftUI

/// Tap-and-hold to expand/collapse a section header.
///
/// ONE glyph rotated, not two glyphs swapped: a swap cannot animate, so the
/// arrow used to snap while the fold itself now slides. The value-scoped
/// .animation keeps the turn smooth on the same curve as the fold
/// (ContactListView.foldAnimation) without leaking an ambient animation to
/// the header around it.
struct CollapseChevron: View {
    let collapsed: Bool
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(Theme.Color.textSecondary)
            .rotationEffect(.degrees(collapsed ? 0 : 90))
            .animation(.easeInOut(duration: 0.22), value: collapsed)
            .frame(width: 12)
    }
}

extension View {
    /// Conditionally apply a modifier when the chat target is NOT a
    /// random-peer session. Used by `ChatView` to skip
    /// `navigationDestination` in the random path (no enclosing
    /// NavigationStack there → SwiftUI logs a "misplaced modifier"
    /// warning on every render). `@ViewBuilder` keeps both branches
    /// the same opaque type so callers can use the result inline.
    @ViewBuilder
    func applyIfNotRandom<Result: View>(
        _ target: ChatTarget,
        @ViewBuilder _ transform: (Self) -> Result
    ) -> some View {
        if case .randomPeer = target {
            self
        } else {
            transform(self)
        }
    }
}

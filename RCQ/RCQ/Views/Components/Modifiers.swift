import SwiftUI

/// Tap-and-hold to expand/collapse a section header.
struct CollapseChevron: View {
    let collapsed: Bool
    var body: some View {
        Image(systemName: collapsed ? "chevron.right" : "chevron.down")
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(Theme.Color.textSecondary)
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

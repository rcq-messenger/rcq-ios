import SwiftUI

/// Where the message under the long-press menu is drawn.
///
/// ⚠ ONE anchor at a time. `MessageRow` publishes its bubble's bounds only
/// while it is the held row and publishes nothing otherwise, so the reduce
/// below never has to choose between two rows: the last non-nil wins, and
/// there is only ever one.
struct HeldBubbleAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// A dim with a rounded hole punched in it: how the long-press menu leaves the
/// held message visible exactly where the chat drew it instead of copying it
/// into the middle of the screen.
///
/// ⚠ `.blendMode(.destinationOut)` inside a `.compositingGroup()`, NOT an
/// even-odd `Path`. The even-odd version was written first and dimmed the whole
/// screen with no hole at all: the shape is laid out in the view's own bounds,
/// and once `.ignoresSafeArea()` moved those bounds out from under it the hole
/// was being cut somewhere off screen. A blend cuts where the cutting view is
/// positioned, which is the same coordinate space the anchor arrived in.
///
/// The dim itself is grown past the container so the status bar and the home
/// indicator area go dark too, while the hole stays in container coordinates.
struct DimWithHole: View {
    let hole: CGRect
    let radius: CGFloat
    var opacity: Double = 0.55

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(opacity))
                .padding(-400)
            if hole.width > 0, hole.height > 0 {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .frame(width: hole.width, height: hole.height)
                    .position(x: hole.midX, y: hole.midY)
                    .blendMode(.destinationOut)
            }
        }
        .compositingGroup()
    }
}

extension View {
    /// Publish this view's rectangle while `active`, and nothing otherwise.
    ///
    /// ⚠ Put it on what is PAINTED, never on a container that has been widened
    /// to the bubble's maximum. The first version anchored the whole bubble
    /// stack, and on a media message that stack is the full bubble width with
    /// the picture inside it: the hole came out as a white slab reaching half
    /// way across the chat with the video in one corner of it.
    func heldAnchor(_ active: Bool) -> some View {
        anchorPreference(key: HeldBubbleAnchorKey.self, value: .bounds) { anchor in
            active ? anchor : nil
        }
    }

    /// Report this view's size into a binding, once and on every change.
    /// Used by the long-press menu, which has to know how tall its own panels
    /// are before it can decide which side of the message they go on.
    func measured(_ size: Binding<CGSize>) -> some View {
        background(
            GeometryReader { g in
                Color.clear
                    .onAppear { size.wrappedValue = g.size }
                    // iOS 16 signature: this app still ships to 16.0, and the
                    // two-parameter closure is 17+.
                    .onChange(of: g.size) { new in size.wrappedValue = new }
            }
        )
    }
}

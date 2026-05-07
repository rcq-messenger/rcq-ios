import SwiftUI

/// The RCQ rose logo with a continuous slow 360° spin — 30 seconds
/// per revolution, linear, repeating forever without auto-reverse
/// (so the rotation glues seamlessly between cycles instead of
/// snapping back). Used wherever the mark appears at hero size:
/// onboarding pages, BootSplash, AboutSheet header, the
/// post-onboarding transition splash.
///
/// Falls back to an SF Symbol if the `Logo` image asset isn't
/// in the bundle (rare; keeps debug builds working without the
/// asset catalog).
struct SlowSpinningLogo: View {
    /// Edge length in points. Default 96 matches the size used in
    /// onboarding's hero slot.
    var size: CGFloat = 96
    /// Seconds per full revolution. The default 30s is "slow
    /// enough to feel ambient, fast enough that you notice the
    /// motion if you stare at the screen".
    var period: Double = 30

    @State private var angle: Double = 0

    var body: some View {
        Group {
            if UIImage(named: "Logo") != nil {
                Image("Logo").resizable().scaledToFit()
            } else {
                Image(systemName: "message.circle.fill")
                    .resizable().scaledToFit()
                    .foregroundColor(Theme.Color.accent)
            }
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(angle))
        .onAppear {
            withAnimation(.linear(duration: period).repeatForever(autoreverses: false)) {
                angle = 360
            }
        }
    }
}

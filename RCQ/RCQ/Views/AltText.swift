import SwiftUI

/// Two pieces of text taking turns in one line.
///
/// A contact row has room for one thing and two worth saying: when somebody was
/// last around, and the status message they left. Sharing the line truncates on
/// a phone, and letting the status message win outright hid the last seen for
/// about a third of offline contacts.
///
/// ⚠⚠ The halves must not fade AT THE SAME TIME. Overlaid and animated
/// together they both sit at half opacity for the whole crossfade, and the one
/// drawn on top smears over the one arriving, which reads as a lag in one
/// direction only. The outgoing half goes first and the incoming one waits for
/// it, so the swap looks the same both ways. Same bug and same cure as the
/// web's chat header.
///
/// Both halves stay laid out, so the row never changes height mid-swap.
struct AltText: View {
    let a: String
    let b: String
    var period: Double = 4
    var fade: Double = 0.5

    @State private var alt = false

    var body: some View {
        ZStack(alignment: .leading) {
            Text(a)
                .lineLimit(1)
                .opacity(alt ? 0 : 1)
                .animation(.easeInOut(duration: fade).delay(alt ? 0 : fade), value: alt)
            Text(b)
                .lineLimit(1)
                .opacity(alt ? 1 : 0)
                .animation(.easeInOut(duration: fade).delay(alt ? fade : 0), value: alt)
        }
        .task(id: "\(a)|\(b)") {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(period * 1_000_000_000))
                if Task.isCancelled { return }
                alt.toggle()
            }
        }
    }
}

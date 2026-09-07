import SwiftUI

/// The island's mark beside a name: a small seal coloured by kind. The kinds
/// are strings the island chooses; the ones this build knows get their colour
/// and anything newer is drawn neutral, so a kind added on the island before
/// the client learned it is still a mark rather than nothing. Draws nothing
/// for nil, the way GenderIcon does, so call sites need no guard.
///
/// Tapping the mark explains it: a half-height sheet with the seal large, a
/// slow glow in its own colour behind it, and what the mark was given for
/// (founder, 05.09). Rows that carry the mark keep their own tap: the inner
/// button wins only on the seal itself.
struct BadgeMark: View {
    let kind: String?
    var size: CGFloat = 13
    @State private var showInfo = false

    /// ⚠⚠ OBSERVED, not read through the static helper below.
    ///
    /// The colour and the name come from the island, and they arrive AFTER the
    /// first frame: `/server/info` is a fetch. `BadgeMark.color(for:)` reaches
    /// `AppState.shared` inside a static function, which SwiftUI cannot see as
    /// a dependency — so a row that never changes for any other reason keeps
    /// whatever colour it was first drawn with, for ever. An operator who
    /// recoloured a kind saw it change on every screen except the home list
    /// and the header, which are exactly the views that had no other reason to
    /// re-render (founder, 07.09).
    ///
    /// The static helpers stay: `BadgeInfoSheet` and the accessibility label
    /// still use them, and they are correct in a context that re-renders.
    @ObservedObject private var app = AppState.shared

    var body: some View {
        if let kind, !kind.isEmpty {
            Button { showInfo = true } label: {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: size, weight: .semibold))
                    // Read off the observed table so this view has a real
                    // dependency on it, then fall back exactly as the static
                    // helper does.
                    .foregroundColor(
                        BadgeMark.parseColor(app.serverBadges[kind]?.color)
                            ?? BadgeMark.builtInColor(for: kind)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(BadgeMark.label(for: kind))
            .sheet(isPresented: $showInfo) {
                BadgeInfoSheet(kind: kind)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    /// ⚠ THE ISLAND'S OWN WORDS FIRST, this build's strings only as a
    /// fallback. See `ServerInfoResponse.badges`: the stock description for
    /// `official` names the RCQ team, which is false on an island the RCQ team
    /// does not run, and a kind an operator invented had no name at all.
    ///
    /// A blank field means "I have not renamed this one", not "call it
    /// nothing", so each of label, description and colour falls back on its
    /// own. Bounded on the way out, because this text is drawn beside a
    /// contact's name and an operator must not be able to push a paragraph
    /// into a roster row.
    @MainActor
    private static func island(_ kind: String) -> BadgeTextResponse? {
        AppState.shared.serverBadges[kind]
    }

    private static func trimmed(_ s: String?, _ max: Int) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return String(t.prefix(max))
    }

    @MainActor
    static func color(for kind: String) -> Color {
        // An island can colour a kind this build has never heard of. Parsed
        // defensively: anything that is not #RRGGBB falls through to the
        // built-in colour rather than drawing nothing.
        return parseColor(island(kind)?.color) ?? builtInColor(for: kind)
    }

    /// The island's colour, or nil when it did not give a usable one. Split out
    /// so the view above can parse the value it OBSERVED rather than going back
    /// through a static read SwiftUI cannot track.
    static func parseColor(_ raw: String?) -> Color? {
        guard let hex = trimmed(raw, 16) else { return nil }
        return colorFromHex(hex)
    }

    private static func colorFromHex(_ hex: String) -> Color? {
        var s = hex
        guard s.hasPrefix("#") else { return nil }
        s.removeFirst()
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return Color(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255,
        )
    }

    static func builtInColor(for kind: String) -> Color {
        switch kind {
        case "official": return Color(red: 0.23, green: 0.62, blue: 0.91)
        case "tester":   return Color(red: 0.88, green: 0.64, blue: 0.11)
        case "special":  return Color(red: 0.88, green: 0.31, blue: 0.41)
        default:         return Theme.Color.textSecondary
        }
    }

    @MainActor
    static func label(for kind: String) -> String {
        if let l = trimmed(island(kind)?.label, 32) { return l }
        let key = "badge." + kind
        let s = key.localized
        return s == key ? kind : s
    }

    @MainActor
    static func description(for kind: String) -> String {
        if let d = trimmed(island(kind)?.description, 200) { return d }
        let key = "badge.desc." + kind
        let s = key.localized
        return s == key ? "badge.desc.unknown".localized : s
    }
}

/// The seal, large, over a glow that breathes in the seal's own colour, and
/// the words under it. Quiet on purpose: one mark, one sentence.
struct BadgeInfoSheet: View {
    let kind: String
    @State private var breathe = false

    var body: some View {
        let colour = BadgeMark.color(for: kind)
        VStack(spacing: 18) {
            Spacer(minLength: 28)
            ZStack {
                Circle()
                    .fill(colour.opacity(0.28))
                    .frame(width: 132, height: 132)
                    .blur(radius: 22)
                    .scaleEffect(breathe ? 1.12 : 0.88)
                    .opacity(breathe ? 0.9 : 0.55)
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 64, weight: .semibold))
                    .foregroundColor(colour)
                    .shadow(color: colour.opacity(0.35), radius: 10)
            }
            .frame(height: 150)
            .onAppear {
                withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) { breathe = true }
            }
            Text(BadgeMark.label(for: kind))
                .font(.title3.weight(.semibold))
                .foregroundColor(Theme.Color.textPrimary)
            Text(BadgeMark.description(for: kind))
                .font(.subheadline)
                .foregroundColor(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Theme.Color.bgPrimary.ignoresSafeArea())
    }
}

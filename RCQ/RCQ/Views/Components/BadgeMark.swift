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

    var body: some View {
        if let kind, !kind.isEmpty {
            Button { showInfo = true } label: {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: size, weight: .semibold))
                    .foregroundColor(BadgeMark.color(for: kind))
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

    static func color(for kind: String) -> Color {
        switch kind {
        case "official": return Color(red: 0.23, green: 0.62, blue: 0.91)
        case "tester":   return Color(red: 0.88, green: 0.64, blue: 0.11)
        case "special":  return Color(red: 0.88, green: 0.31, blue: 0.41)
        default:         return Theme.Color.textSecondary
        }
    }

    static func label(for kind: String) -> String {
        let key = "badge." + kind
        let s = key.localized
        return s == key ? kind : s
    }

    static func description(for kind: String) -> String {
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

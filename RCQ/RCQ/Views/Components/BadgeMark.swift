import SwiftUI

/// The island's mark beside a name: a small seal coloured by kind. The kinds
/// are strings the island chooses; the ones this build knows get their colour
/// and anything newer is drawn neutral, so a kind added on the island before
/// the client learned it is still a mark rather than nothing. Draws nothing
/// for nil, the way GenderIcon does, so call sites need no guard.
struct BadgeMark: View {
    let kind: String?
    var size: CGFloat = 13

    var body: some View {
        if let kind, !kind.isEmpty {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(color(for: kind))
                .accessibilityLabel(label(for: kind))
        }
    }

    private func color(for kind: String) -> Color {
        switch kind {
        case "official": return Color(red: 0.23, green: 0.62, blue: 0.91)
        case "tester":   return Color(red: 0.88, green: 0.64, blue: 0.11)
        case "special":  return Color(red: 0.88, green: 0.31, blue: 0.41)
        default:         return Theme.Color.textSecondary
        }
    }

    private func label(for kind: String) -> String {
        let key = "badge." + kind
        let s = key.localized
        return s == key ? kind : s
    }
}

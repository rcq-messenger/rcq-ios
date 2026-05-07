import SwiftUI

/// Tiny ♂/♀/⚧ glyph rendered next to a nickname when the
/// target user has explicitly set their gender AND chosen a
/// visibility scope that includes the current viewer. Server
/// applies the gating and either ships the literal
/// "male"/"female"/"other" string or null; this view just maps
/// the string to a coloured Unicode mars/venus glyph.
///
/// We use Unicode glyphs rather than SF Symbols because SFSymbol
/// has no semantic male/female pair, and the Unicode glyphs
/// already render as proper symbols at any text size.
struct GenderIcon: View {
    let gender: String?
    var size: CGFloat = 13

    var body: some View {
        if let label, let color {
            Text(label)
                .font(.system(size: size, weight: .bold))
                .foregroundColor(color)
                .accessibilityLabel(accessibilityLabel)
        }
    }

    private var label: String? {
        switch gender {
        case "male":   return "♂"
        case "female": return "♀"
        case "other":  return "⚧"
        default:       return nil
        }
    }

    private var color: Color? {
        switch gender {
        case "male":   return Color(red: 0.32, green: 0.62, blue: 0.95)  // light blue
        case "female": return Color(red: 0.95, green: 0.45, blue: 0.7)   // pink
        case "other":  return Color(red: 0.65, green: 0.45, blue: 0.85)  // purple
        default:       return nil
        }
    }

    private var accessibilityLabel: String {
        switch gender {
        case "male":   return "Male"
        case "female": return "Female"
        case "other":  return "Other"
        default:       return ""
        }
    }
}

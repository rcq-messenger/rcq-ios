import SwiftUI
import UIKit

/// Visual constants. Two palettes (light = classic ICQ 2002 white, dark = night mode).
/// Colors are dynamic via UIColor providers, so anywhere in the app we just write
/// `Theme.Color.bgPrimary` and SwiftUI picks the right variant from the current trait
/// collection. Switching theme is therefore a single `.preferredColorScheme(...)` flip
/// at the root of the app — no view needs to know about the active palette.
enum Theme {
    enum Color {
        static let bgPrimary       = dyn(light: 0xFFFFFF, dark: 0x1A1A1A)
        static let bgSecondary     = dyn(light: 0xF2F2F2, dark: 0x222222)
        static let bgRowHover      = dyn(light: 0xE6EFFA, dark: 0x2A2A2A)
        /// A surface that floats ABOVE a dimmed backdrop (the long-press chat
        /// preview). It cannot be `bgPrimary`: over the blurred material scrim
        /// that colour is within a hair of the backdrop in dark mode, so the
        /// card had no visible edge at all and its rounded corners read as
        /// square — the whole card looked like a rectangle of content.
        static let bgElevated      = dyn(light: 0xFFFFFF, dark: 0x2E2E2E)
        static let textPrimary     = dyn(light: 0x000000, dark: 0xEDEDED)
        static let textSecondary   = dyn(light: 0x555555, dark: 0x9A9A9A)
        static let textMono        = dyn(light: 0x222222, dark: 0xB8B8B8)

        /// ICQ "flower" green — the iconic shade from the 2002 client logo. Used for
        /// primary actions (Send, Save, Accept) and for the active-status accent.
        static let accent          = dyn(light: 0x6BB12C, dark: 0x84C32C)
        static let accentPressed   = dyn(light: 0x4F8E1C, dark: 0x6BB12C)

        static let bubbleSelf      = dyn(light: 0xDCEEFC, dark: 0x2E2E2E)
        static let bubbleOther     = dyn(light: 0xF2F2F2, dark: 0x222222)
        static let divider         = dyn(light: 0xCFCFCF, dark: 0x303030)

        // Status dots are spec-locked across both themes.
        static let statusOnline    = SwiftUI.Color(hex: 0x4CAF50)
        static let statusAway      = SwiftUI.Color(hex: 0xFFC107)
        static let statusBusy      = SwiftUI.Color(hex: 0xF44336)
        static let statusInvisible = SwiftUI.Color(hex: 0x9C27B0)
        static let statusOffline   = SwiftUI.Color(hex: 0x9E9E9E)

        private static func dyn(light: UInt32, dark: UInt32) -> SwiftUI.Color {
            SwiftUI.Color(uiColor: UIColor { trait in
                trait.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
            })
        }
    }

    enum Font {
        // De-mono'd per founder preference (monospace read as ugly everywhere).
        // Names kept for call-site stability; UIN/host/timestamp labels now use
        // the normal proportional font.
        static let mono         = SwiftUI.Font.system(.footnote)
        static let monoSmall    = SwiftUI.Font.system(.caption)
        static let nickname     = SwiftUI.Font.system(.body, weight: .semibold)
        static let statusLabel  = SwiftUI.Font.system(.caption)
        static let bubble       = SwiftUI.Font.system(.body)
        static let timestamp    = SwiftUI.Font.system(.caption2)
    }

    enum Metrics {
        static let avatarLg: CGFloat = 44
        static let avatarMd: CGFloat = 36
        static let avatarSm: CGFloat = 24
        static let statusDot: CGFloat = 9
        static let bubbleRadius: CGFloat = 6
        static let rowVPad: CGFloat = 6
        static let rowHPad: CGFloat = 10
    }
}

extension SwiftUI.Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1.0) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255
        let g = CGFloat((hex >> 8) & 0xFF) / 255
        let b = CGFloat(hex & 0xFF) / 255
        self.init(red: r, green: g, blue: b, alpha: alpha)
    }
}

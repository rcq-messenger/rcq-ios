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
        /// Amber, not red: a warning asks you to CHECK something, it does not
        /// forbid it. The safety-number banner used statusBusy (Material Red),
        /// which a tester read as "blocked". Android moved the same sign to
        /// amber in 12393e5; this keeps the status-dot palette out of warnings.
        static let warning         = SwiftUI.Color(hex: 0xF5A524)
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

        /// One trait-resolved wallpaper stop. Same mechanism as every colour
        /// above (`dyn` stays private so nothing outside the palette mints
        /// ad-hoc theme pairs); `Theme.Wallpaper` is the one caller.
        static func wallpaperStop(light: UInt32, dark: UInt32) -> SwiftUI.Color {
            dyn(light: light, dark: dark)
        }
    }

    /// Built-in wallpapers, authored PER THEME.
    ///
    /// ⚠ This exists because `Theme.Color` resolves from the UIKit trait
    /// collection while the wallpaper is picked independently of it, so the two
    /// disagree BY CONSTRUCTION: a light-theme user choosing "Midnight" got
    /// black text on a navy wallpaper, and a dark-theme user choosing "Cream"
    /// got the mirror image (Android hit the same thing as #554 and answered it
    /// the other way, by re-deriving every foreground from the wallpaper's top
    /// colour). Re-tokenising the whole screen off a wallpaper is a large and
    /// fragile change; making the WALLPAPER follow the theme is eight extra
    /// gradients and no call site that has to know. So each preset keeps its
    /// identity ("Ocean" is blue in both themes) and only its VALUE moves.
    ///
    /// The four presets that were already light (sunset, lavender, rose, cream)
    /// keep their shipped stops EXACTLY in the light column: nobody who is
    /// happy with their wallpaper today should find it repainted. The four that
    /// were dark by default (ocean, midnight, forest, graphite) gain a light
    /// counterpart, and all eight gain a dark one: the eight gradients this
    /// change is actually made of.
    ///
    /// Every light stop sits above the WCAG 0.179 relative-luminance line and
    /// every dark stop below it, so the palette can never be on the wrong side
    /// of the theme. The four new light gradients go further and clear a 4.5:1
    /// contrast ratio against `textSecondary`, the palest label the screen uses,
    /// on every stop. The four inherited ones do not (sunset's orange is 2.96:1)
    /// and are left alone anyway: they were like that before, and on this screen
    /// no label stands on bare wallpaper any more, everything has a surface
    /// under it (`wallpaperSurface` below).
    ///
    /// A CUSTOM image cannot be authored this way. See
    /// `ChatBackgroundStore.homeCustomIsLight`, which measures one instead.
    enum Wallpaper {
        struct Preset: Identifiable {
            let id: String
            /// Untranslated on purpose: the picker has shipped these eight
            /// names in every language since the feature existed.
            let label: String
            let light: [UInt32]
            let dark: [UInt32]

            /// The gradient stops for the ACTIVE theme. Dynamic colours, so a
            /// system light/dark flip repaints without anybody re-reading this.
            var colors: [SwiftUI.Color] {
                zip(light, dark).map { Theme.Color.wallpaperStop(light: $0, dark: $1) }
            }
        }

        /// Same ids and same order as every other client's preset list, so a
        /// selection made on one device reads the same wallpaper on the next.
        static let presets: [Preset] = [
            Preset(id: "ocean", label: "Ocean",
                   light: [0xC2D8F5, 0xD2F2F1], dark: [0x101B4D, 0x0B4F4E]),
            Preset(id: "midnight", label: "Midnight",
                   light: [0xD8E2E8, 0xCBD9E1, 0xBFD0DA], dark: [0x0F2027, 0x203A43, 0x2C5364]),
            Preset(id: "forest", label: "Forest",
                   light: [0xBFDBE0, 0xD6EEDC], dark: [0x0B2A33, 0x1E4630]),
            Preset(id: "sunset", label: "Sunset",
                   light: [0xFF8008, 0xFFC837], dark: [0x4A2503, 0x5C4310]),
            Preset(id: "lavender", label: "Lavender",
                   light: [0xE0C3FC, 0x8EC5FC], dark: [0x2A2043, 0x16304B]),
            Preset(id: "rose", label: "Rose",
                   light: [0xFFDEE9, 0xB5FFFC], dark: [0x40222C, 0x123634]),
            Preset(id: "cream", label: "Cream",
                   light: [0xF3EFE7, 0xF3EFE7], dark: [0x211E19, 0x211E19]),
            Preset(id: "graphite", label: "Graphite",
                   light: [0xE4E5E6, 0xD3D4D5], dark: [0x232526, 0x414345]),
        ]

        static func preset(_ id: String) -> Preset? { presets.first { $0.id == id } }

        /// The stops for a stored selection (`preset:<id>`), or nil when the
        /// selection is not a built-in one (default, or a custom image).
        static func colors(forSelection selection: String) -> [SwiftUI.Color]? {
            guard selection.hasPrefix("preset:") else { return nil }
            return preset(String(selection.dropFirst("preset:".count)))?.colors
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

/// How opaque a surface's theme tint stays when it is floating over a
/// wallpaper. `translucent` is the normal case, where the wallpaper is meant to
/// read through the chat list; `reasserted` is for a CUSTOM image that fights
/// the active theme (a white photo under the dark theme), where letting it
/// through would take the ground out from under text authored for that theme.
enum WallpaperSurface {
    case none
    case translucent
    case reasserted

    /// How much of the theme colour survives on top of the blur. Exposed
    /// because a surface that also casts a shadow has to build its own layer
    /// (a shadow taken on the composited view outlines the content too).
    var tint: Double {
        switch self {
        case .none:        return 1.0
        case .translucent: return 0.58
        case .reasserted:  return 0.93
        }
    }

    /// The same thing for a small CONTRAST PILL (the chat's day line, its
    /// unread line): a lozenge of theme colour a couple of words wide, sitting
    /// straight on the picture with no blur under it. It is nearly opaque
    /// where a whole surface is nearly transparent, and for the opposite
    /// reason: a big translucent panel still reads as a panel, while a small
    /// one at 0.58 is just a smudge on the wallpaper. 0.85 is the value the
    /// day line has shipped with; a custom image that fights the theme gets
    /// the rest of the way closed.
    var pillTint: Double {
        switch self {
        case .none:        return 1.0
        case .translucent: return 0.85
        case .reasserted:  return 0.95
        }
    }
}

extension WallpaperSurface {
    /// The mode a screen's chrome paints in, decided once from the stored
    /// wallpaper selection and the theme that is actually on screen.
    ///
    /// Two of the three answers cost nothing to reach. No wallpaper is `.none`.
    /// A BUILT-IN wallpaper is `.translucent` unconditionally, because
    /// `Theme.Wallpaper` authors every preset per theme: whatever ends up
    /// behind the chrome is already on the theme's side of the WCAG line, so
    /// the theme's own colours are the right colours and only their weight has
    /// to come down. Measuring a preset would only tell us what we authored.
    ///
    /// A CUSTOM image is the one case where nothing was authored, so it is the
    /// one case that has to be measured: `ChatBackgroundStore.customIsLight`,
    /// the mean tone of the top strip against the same 0.179 line Android's
    /// `needsLightChrome` uses. When the measurement agrees with the theme the
    /// picture behaves like a preset. When it disagrees, the theme is
    /// reasserted and takes its ground back, because a white photo under the
    /// dark theme would otherwise push a translucent surface light enough to
    /// lose the light text standing on it. An image whose decode has not landed
    /// yet reads as `.translucent`, which is also the answer it keeps if the
    /// measurement agrees.
    ///
    /// The preset is LOOKED UP, never built: `Wallpaper.colors(forSelection:)`
    /// mints two or three `UIColor(dynamicProvider:)` per call, and callers read
    /// this once per visible row on every pass of a list.
    static func mode(selection: String, customIsLight: Bool?, isLightTheme: Bool) -> WallpaperSurface {
        if selection == "custom" {
            guard let customIsLight else { return .translucent }
            return customIsLight == isLightTheme ? .translucent : .reasserted
        }
        guard selection.hasPrefix("preset:") else { return .none }
        let id = String(selection.dropFirst("preset:".count))
        return Theme.Wallpaper.preset(id) == nil ? .none : .translucent
    }
}

extension View {
    /// Paint `color` as this view's ground: flat when there is no wallpaper
    /// behind the screen, and a translucent tint over a blur when there is.
    ///
    /// The tint is kept rather than dropped for the material alone on purpose.
    /// A bare `.ultraThinMaterial` takes its tone from whatever is behind it,
    /// which is exactly the wallpaper we are trying not to be at the mercy of;
    /// keeping the theme colour on top means the row still stands on the colour
    /// its text was authored against, only thinner.
    @ViewBuilder
    func wallpaperSurface(_ color: SwiftUI.Color, _ mode: WallpaperSurface) -> some View {
        switch mode {
        case .none:
            background(color)
        case .translucent, .reasserted:
            background(color.opacity(mode.tint).background(.ultraThinMaterial))
        }
    }

    /// The same for floating chrome that has no ground of its own until a
    /// wallpaper puts one under it, such as the header's name/UIN pill. `.none` paints
    /// NOTHING here, unlike the row version: without a wallpaper this chrome is
    /// meant to sit bare on the nav bar, and giving it a fill would change how
    /// the screen looks for everybody who never set one.
    @ViewBuilder
    func wallpaperChromePill<S: Shape>(_ color: SwiftUI.Color, _ mode: WallpaperSurface, in shape: S) -> some View {
        switch mode {
        case .none:
            self
        case .translucent, .reasserted:
            background(shape.fill(color.opacity(mode.tint)).background(.ultraThinMaterial, in: shape))
        }
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

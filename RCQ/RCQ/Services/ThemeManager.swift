import Combine
import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "settings.appearance.theme.system".localized
        case .light:  return "settings.appearance.theme.light".localized
        case .dark:   return "settings.appearance.theme.dark".localized
        }
    }

    /// `nil` for system → SwiftUI inherits the OS-level dark/light setting.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

@MainActor
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @Published var theme: AppTheme {
        didSet {
            UserDefaults.standard.set(theme.rawValue, forKey: "rcq.theme")
            // Only tick on a real switch (init's didSet doesn't fire).
            if oldValue != theme {
                SmokeTracker.shared.tick(.switchTheme)
            }
        }
    }

    private init() {
        // Pre-existing installs have only seen `light`/`dark` written
        // here; treat any unknown value as `system` to give the new
        // default (follow OS) to anyone who hadn't explicitly picked.
        let stored = UserDefaults.standard.string(forKey: "rcq.theme")
        self.theme = stored.flatMap { AppTheme(rawValue: $0) } ?? .system
    }
}

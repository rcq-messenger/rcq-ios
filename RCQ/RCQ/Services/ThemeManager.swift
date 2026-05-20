import Combine
import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case light, dark
    var id: String { rawValue }
    var label: String { self == .light ? "Light" : "Dark" }

    var colorScheme: ColorScheme { self == .light ? .light : .dark }
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
        let stored = UserDefaults.standard.string(forKey: "rcq.theme") ?? AppTheme.light.rawValue
        self.theme = AppTheme(rawValue: stored) ?? .light
    }
}

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
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "rcq.theme") }
    }

    private init() {
        let stored = UserDefaults.standard.string(forKey: "rcq.theme") ?? AppTheme.light.rawValue
        self.theme = AppTheme(rawValue: stored) ?? .light
    }
}

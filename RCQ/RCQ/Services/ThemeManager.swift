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

/// In-app text size (#3 accessibility — the audience skews 30+ with imperfect
/// vision). `system` adds NO override (pure Dynamic Type = respects the OS
/// setting); the others force a larger size app-wide. The app already uses
/// Dynamic Type fonts (Theme.Font = .system(.body) etc.) so this scales
/// everything from one `.environment(\.dynamicTypeSize)` at the root.
enum AppTextSize: String, CaseIterable, Identifiable {
    case system, large, larger, largest
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system:  return "settings.textsize.system".localized
        case .large:   return "settings.textsize.large".localized
        case .larger:  return "settings.textsize.larger".localized
        case .largest: return "settings.textsize.largest".localized
        }
    }
    /// nil = don't override (follow the OS). Otherwise force this size.
    var override: DynamicTypeSize? {
        switch self {
        case .system:  return nil
        case .large:   return .xLarge
        case .larger:  return .xxLarge
        case .largest: return .xxxLarge
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

    @Published var textSize: AppTextSize {
        didSet { UserDefaults.standard.set(textSize.rawValue, forKey: "rcq.textsize") }
    }

    private init() {
        // Pre-existing installs have only seen `light`/`dark` written
        // here; treat any unknown value as `system` to give the new
        // default (follow OS) to anyone who hadn't explicitly picked.
        let stored = UserDefaults.standard.string(forKey: "rcq.theme")
        self.theme = stored.flatMap { AppTheme(rawValue: $0) } ?? .system
        let ts = UserDefaults.standard.string(forKey: "rcq.textsize")
        self.textSize = ts.flatMap { AppTextSize(rawValue: $0) } ?? .system
    }
}

/// Applies the in-app text-size override only when the user picked a
/// non-system size (so `system` keeps pure Dynamic Type / the OS setting).
struct AppTextSizeModifier: ViewModifier {
    let size: AppTextSize
    func body(content: Content) -> some View {
        if let dt = size.override { content.environment(\.dynamicTypeSize, dt) }
        else { content }
    }
}

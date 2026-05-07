import Foundation
import SwiftUI

/// Per-app language override. iOS picks the system locale by
/// default, but ICQ-era users expect a manual switcher in
/// Settings — and we eventually want the app to ship in the
/// dozen-ish languages that cover most of the messenger market.
///
/// This is the *fundament* — actual translations live in the
/// `Localizable.strings` files inside each `*.lproj` directory.
/// Adding a new language is two steps:
///   1. Add a case to `AppLanguage` (with code + display name)
///   2. Drop a translated `Localizable.strings` into
///      `RCQ/Resources/<code>.lproj/`
///
/// Strings in Swift code reach for the active language via
/// `String.localized` (see `String+Localized.swift`); calling
/// `set(_:)` here flips the active bundle and bumps `version`,
/// which `LocalizedText` views observe to re-render.
@MainActor
final class LanguageManager: ObservableObject {
    static let shared = LanguageManager()

    /// Currently active language. Persisted in UserDefaults so
    /// the choice survives app restarts.
    @Published private(set) var current: AppLanguage

    /// Bumped on every `set(_:)` so SwiftUI views that read
    /// localized strings re-render. Views observe by depending
    /// on `LanguageManager.shared.version` somewhere in their
    /// body (the `LocalizedText` helper does this implicitly).
    @Published private(set) var version: Int = 0

    private static let defaultsKey = "rcq.app_language"

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.defaultsKey)
        if let stored, let lang = AppLanguage(rawValue: stored) {
            current = lang
        } else if let prefix = Locale.preferredLanguages.first?.prefix(2),
                  let lang = AppLanguage(rawValue: String(prefix)) {
            // Fall back to the system's first preferred language
            // when the user hasn't picked one yet.
            current = lang
        } else {
            current = .english
        }
        applyToBundleSearchPath()
        mirrorToAppGroup()
    }

    func set(_ language: AppLanguage) {
        guard language != current else { return }
        current = language
        UserDefaults.standard.set(language.rawValue, forKey: Self.defaultsKey)
        applyToBundleSearchPath()
        mirrorToAppGroup()
        version &+= 1
    }

    /// Write the active language code into the App Group so the NSE
    /// (which runs in its own process and can't see the main app's
    /// standard UserDefaults) localizes push notifications against
    /// the same language the user picked in the app's Settings →
    /// Language picker.
    ///
    /// We write BOTH a flat file and the App Group UserDefaults.
    /// The file is the source of truth — App Group UserDefaults is
    /// flaky on iOS (cfprefsd routinely "detaches" the shared
    /// suite, after which writes silently stop propagating to the
    /// NSE process), but a single-line file in the shared container
    /// is rock-solid. UserDefaults stays as a secondary cache for
    /// callers that already use it.
    private func mirrorToAppGroup() {
        let code = current.rawValue
        try? code.data(using: .utf8)?.write(
            to: AppGroup.languageFileURL, options: .atomic
        )
        let shared = UserDefaults(suiteName: AppGroup.identifier)
        shared?.set(code, forKey: Self.defaultsKey)
    }

    /// Resolved bundle for the active language. Falls back to
    /// the main bundle when the requested lproj doesn't exist
    /// yet (translations land incrementally — missing keys read
    /// from the development language).
    var activeBundle: Bundle {
        if let path = Bundle.main.path(forResource: current.rawValue, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        return .main
    }

    /// Hint to UIKit's localization machinery for libraries (and
    /// our own `NSLocalizedString` calls without an explicit
    /// bundle) so a fresh launch picks up the right
    /// language. SwiftUI components mostly read via
    /// `String.localized`, but anything that hits
    /// `Bundle.main.localizedString` directly reads
    /// `AppleLanguages` first.
    private func applyToBundleSearchPath() {
        UserDefaults.standard.set([current.rawValue], forKey: "AppleLanguages")
    }
}

/// Languages we plan to ship, in display-friendly order. The
/// `rawValue` doubles as the lproj folder name and the code
/// stored in UserDefaults — keep them in sync with the
/// directory layout under `Resources/`.
enum AppLanguage: String, CaseIterable, Identifiable, Hashable {
    case english       = "en"
    case russian       = "ru"
    case spanish       = "es"
    case portuguese    = "pt"
    case french        = "fr"
    case german        = "de"
    case italian       = "it"
    case turkish       = "tr"
    case polish        = "pl"
    case ukrainian     = "uk"
    case chineseSimp   = "zh-Hans"
    case japanese      = "ja"
    case korean        = "ko"
    case arabic        = "ar"
    case hindi         = "hi"

    var id: String { rawValue }

    var nativeName: String {
        switch self {
        case .english:     return "English"
        case .russian:     return "Русский"
        case .spanish:     return "Español"
        case .portuguese:  return "Português"
        case .french:      return "Français"
        case .german:      return "Deutsch"
        case .italian:     return "Italiano"
        case .turkish:     return "Türkçe"
        case .polish:      return "Polski"
        case .ukrainian:   return "Українська"
        case .chineseSimp: return "简体中文"
        case .japanese:    return "日本語"
        case .korean:      return "한국어"
        case .arabic:      return "العربية"
        case .hindi:       return "हिन्दी"
        }
    }

    /// True iff the bundled `lproj/` actually carries the strings
    /// table. Today only en + ru are translated end-to-end; the
    /// other entries are visible-but-disabled in the picker so
    /// users see the roadmap without being able to switch into a
    /// half-translated UI. Add to this list as full translations
    /// land.
    var isAvailable: Bool {
        switch self {
        case .english, .russian: return true
        default: return false
        }
    }
}

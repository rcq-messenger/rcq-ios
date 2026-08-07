import Foundation
import SwiftUI

/// Per-app language override. ICQ-era users expect a manual switcher
/// in Settings. Translations live in `*.lproj/Localizable.strings`;
/// adding a language = add a case to `AppLanguage` + drop strings file.
/// `String.localized` reads the active bundle; `set(_:)` flips the
/// bundle and bumps `version` so `LocalizedText` re-renders.
@MainActor
final class LanguageManager: ObservableObject {
    static let shared = LanguageManager()

    @Published private(set) var current: AppLanguage

    /// Bumped on every `set(_:)` so SwiftUI views re-render.
    @Published private(set) var version: Int = 0

    private static let defaultsKey = "rcq.app_language"

    /// The active bundle, readable from ANY thread.
    ///
    /// `String.localized` used to reach `activeBundle` through
    /// `MainActor.assumeIsolated`, which is not a cast — it asserts, and traps
    /// the process when the assertion is wrong. Anything localising a string
    /// off the main actor therefore killed the app; the full network check did
    /// exactly that, because its first `await` resumes on a network queue and
    /// every line title after that is a `.localized`.
    ///
    /// A Bundle reference is immutable and safe to read concurrently, so the
    /// answer is to publish it rather than to assert about where the caller is.
    /// Written only from the main actor, on init and on every language change.
    nonisolated(unsafe) private(set) static var currentBundle: Bundle = .main

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.defaultsKey)
        if let stored, let lang = AppLanguage(rawValue: stored) {
            current = lang
        } else if let prefix = Locale.preferredLanguages.first?.prefix(2),
                  let lang = AppLanguage(rawValue: String(prefix)) {
            current = lang
        } else {
            current = .english
        }
        applyToBundleSearchPath()
        mirrorToAppGroup()
        Self.currentBundle = activeBundle
    }

    func set(_ language: AppLanguage) {
        guard language != current else { return }
        current = language
        UserDefaults.standard.set(language.rawValue, forKey: Self.defaultsKey)
        applyToBundleSearchPath()
        mirrorToAppGroup()
        Self.currentBundle = activeBundle
        version &+= 1
    }

    /// Hand the active language code over to the App Group so the NSE
    /// (separate process) localizes pushes against the same language the
    /// user picked. Writes BOTH a flat file (source of truth) and App
    /// Group UserDefaults — cfprefsd routinely detaches the shared
    /// suite, after which writes stop propagating to the NSE; the file
    /// is rock-solid.
    private func mirrorToAppGroup() {
        let code = current.rawValue
        try? code.data(using: .utf8)?.write(
            to: AppGroup.languageFileURL, options: .atomic
        )
        let shared = UserDefaults(suiteName: AppGroup.identifier)
        shared?.set(code, forKey: Self.defaultsKey)
    }

    /// Resolved bundle for the active language. Falls back to main
    /// bundle for missing lproj (translations land incrementally).
    var activeBundle: Bundle {
        if let path = Bundle.main.path(forResource: current.rawValue, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        return .main
    }

    /// Sets `AppleLanguages` so UIKit + bundle.localizedString reads pick
    /// up the right language on next launch.
    private func applyToBundleSearchPath() {
        UserDefaults.standard.set([current.rawValue], forKey: "AppleLanguages")
    }
}

/// `rawValue` doubles as the lproj folder name and the UserDefaults code.
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

    /// True iff the lproj has a full strings table. Other entries
    /// are visible-but-disabled in the picker so users see the roadmap
    /// without switching into a half-translated UI.
    var isAvailable: Bool {
        switch self {
        case .english, .russian: return true
        default: return false
        }
    }
}

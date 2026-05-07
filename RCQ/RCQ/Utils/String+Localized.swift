import Foundation

/// Lightweight bridge between the per-app language override (see
/// `LanguageManager`) and string lookups in Swift. Use
/// `"some.key".localized` instead of `NSLocalizedString` so the
/// override picks the right `Localizable.strings` file even
/// before iOS reloads its launch-time bundle.
///
/// Convention: keys are dotted, namespaced by feature
/// (`settings.privacy.last_seen`, `chat.input.placeholder`, etc.).
/// English copy lives in `Resources/en.lproj/Localizable.strings`
/// — that's also the development language and the fallback for
/// any key missing in another lproj.
extension String {
    /// Looks the receiver up in the active language's bundle.
    /// Falls back to the main bundle (development language)
    /// when the active lproj doesn't ship the key yet.
    var localized: String {
        let bundle = MainActor.assumeIsolated { LanguageManager.shared.activeBundle }
        let value = bundle.localizedString(forKey: self, value: nil, table: nil)
        if value != self { return value }
        // Fallback to the main bundle so a missing key in a
        // partial translation reads the English copy instead of
        // showing the raw dotted identifier.
        return Bundle.main.localizedString(forKey: self, value: self, table: nil)
    }

    /// Variadic-format variant for strings with `%@` / `%d`
    /// placeholders.
    func localized(_ args: CVarArg...) -> String {
        String(format: localized, arguments: args)
    }
}

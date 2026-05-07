import SwiftUI
import NaturalLanguage
#if canImport(Translation)
import Translation
#endif

/// Hidden runner that translates `vm.pendingTranslationMessage` via
/// Apple's iOS 18+ `TranslationSession` and writes the result back
/// into `vm.translatedTexts`. The bubble's text branch then renders
/// the translated body via `vm.displayText(for:)` — IN PLACE,
/// without a modal sheet, without Apple's "Open in Translate"
/// hand-off (which on a device with Google Translate installed
/// routes there). Same UX pattern as Argus mission briefings: tap
/// to translate, tap again to revert.
///
/// Pre-iOS-18 the runner is a no-op (Translation API isn't
/// programmatic there); the menu entry stays visible but the action
/// does nothing.
struct InPlaceTranslator: ViewModifier {
    @ObservedObject var vm: ChatViewModel

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.modifier(InPlaceTranslatorIOS18(vm: vm))
        } else {
            content.onChange(of: vm.pendingTranslationMessage?.id) { _ in
                vm.pendingTranslationMessage = nil
            }
        }
    }
}

@available(iOS 18.0, *)
private struct InPlaceTranslatorIOS18: ViewModifier {
    @ObservedObject var vm: ChatViewModel

    /// Built when `pendingTranslationMessage` is set + the source
    /// language has been auto-detected. Drives `.translationTask` to
    /// spin up a `TranslationSession` configured with the EXPLICIT
    /// source language (auto-detect via `NLLanguageRecognizer`) +
    /// the user's system locale as target. Cleared between requests
    /// so a structurally-equal configuration doesn't get skipped by
    /// the modifier.
    @State private var configuration: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .onChange(of: vm.pendingTranslationMessage?.id) { _ in
                guard let msg = vm.pendingTranslationMessage else { return }
                configureForTranslation(of: msg.text)
            }
            .translationTask(configuration) { session in
                await runSession(session)
            }
    }

    private func configureForTranslation(of text: String) {
        let target = Locale.current.language

        // Auto-detect the source language. `NLLanguageRecognizer` is
        // synchronous, runs in microseconds, and gives us an
        // explicit source locale to feed `TranslationSession.Configuration`
        // with. With `source: nil` Apple's preflight throws
        // TranslationErrorDomain Code=21 ("Can't resolve source
        // locale...") because LID needs an explicit source ahead of
        // the actual translate call — that's the symptom the user
        // saw as "нажимаю перевести и ничего не происходит".
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let detected = recognizer.dominantLanguage

        let sourceLanguage: Locale.Language?
        if let detected {
            let detectedLanguage = Locale.Language(identifier: detected.rawValue)
            // Same language → nothing to translate. Skip to keep the
            // bubble on the original text rather than firing a no-op
            // TranslationSession that may still throw.
            if detectedLanguage.languageCode == target.languageCode {
                vm.pendingTranslationMessage = nil
                return
            }
            sourceLanguage = detectedLanguage
        } else {
            // Detector couldn't decide — let Apple try with nil
            // source as a last resort.
            sourceLanguage = nil
        }

        // Reset + re-arm so a second translate request on a different
        // message kicks the modifier back on.
        configuration = nil
        DispatchQueue.main.async {
            configuration = TranslationSession.Configuration(
                source: sourceLanguage,
                target: target
            )
        }
    }

    @MainActor
    private func runSession(_ session: TranslationSession) async {
        guard let pending = vm.pendingTranslationMessage else { return }
        defer { vm.pendingTranslationMessage = nil }
        do {
            // With explicit `source:` set in the configuration above,
            // `prepareTranslation()` now has enough info to trigger
            // the system pack-install sheet inline if needed.
            try await session.prepareTranslation()
            let response = try await session.translate(pending.text)
            vm.translatedTexts[pending.id] = response.targetText
        } catch {
            // Silent failure — the bubble stays on the original text;
            // user can long-press → Translate again to retry.
        }
    }
}

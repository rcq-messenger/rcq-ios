import SwiftUI
import NaturalLanguage
#if canImport(Translation)
import Translation
#endif

/// In-place translator (iOS 18+ `TranslationSession`). Writes back into `vm.translatedTexts`.
/// Pre-iOS-18 is a no-op.
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

        // Explicit source required: `source: nil` throws TranslationErrorDomain Code=21.
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let detected = recognizer.dominantLanguage

        let sourceLanguage: Locale.Language?
        if let detected {
            let detectedLanguage = Locale.Language(identifier: detected.rawValue)
            if detectedLanguage.languageCode == target.languageCode {
                vm.pendingTranslationMessage = nil
                return
            }
            sourceLanguage = detectedLanguage
        } else {
            sourceLanguage = nil
        }

        // Reset + re-arm so a second translate request on a different message kicks the modifier back on.
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
            try await session.prepareTranslation()
            let response = try await session.translate(pending.text)
            vm.translatedTexts[pending.id] = response.targetText
        } catch {
            // Silent failure — bubble stays on original text; long-press to retry.
        }
    }
}

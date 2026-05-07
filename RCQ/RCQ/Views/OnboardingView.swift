import SwiftUI

/// First-launch tour. Lives behind a `@AppStorage("rcq.onboarded")`
/// flag in `RootView` so it survives an account burn — a returning
/// user who's already seen the tour doesn't get walked through it
/// again on the same device. Deleting the app clears UserDefaults
/// naturally, which is the right behaviour (truly fresh install =
/// see the tour again).
struct OnboardingView: View {
    let onFinish: () -> Void

    @State private var page: Int = 0
    /// Drives the language picker sheet from the top-bar pill on
    /// page 0. Read off `LanguageManager.shared` directly; flipping
    /// this here just opens the picker.
    @State private var showLanguagePicker = false
    /// True once the user taps "Get started" on the last page —
    /// transitions the whole view from the page deck to a brief
    /// branded animation surface, then calls `onFinish()` once the
    /// animation lands. First impression matters; the deck-to-app
    /// jump used to be a hard cut.
    @State private var entering: Bool = false
    /// Observed so a language switch from the picker forces a
    /// re-render of the page texts (the `pages` computed property
    /// reads `*.localized` off the active bundle, but SwiftUI needs
    /// a published source to recompute on language change).
    @StateObject private var lang = LanguageManager.shared

    /// Pages are computed off `LanguageManager.shared.activeBundle`
    /// at render time so a language switch from the in-onboarding
    /// pill re-localizes the tour without restart.
    private var pages: [Page] {
        [
            Page(
                kicker: "onboard.welcome.kicker".localized,
                title: "onboard.welcome.title".localized,
                body: "onboard.welcome.body".localized,
                hero: .logo,
            ),
            Page(
                kicker: "onboard.status.kicker".localized,
                title: "onboard.status.title".localized,
                body: "onboard.status.body".localized,
                hero: .statusRow,
            ),
            Page(
                kicker: "onboard.chat.kicker".localized,
                title: "onboard.chat.title".localized,
                body: "onboard.chat.body".localized,
                hero: .gif("smile"),
            ),
            Page(
                kicker: "onboard.nearby.kicker".localized,
                title: "onboard.nearby.title".localized,
                body: "onboard.nearby.body".localized,
                hero: .symbol("location.viewfinder"),
            ),
            Page(
                kicker: "onboard.calls.kicker".localized,
                title: "onboard.calls.title".localized,
                body: "onboard.calls.body".localized,
                hero: .symbol("video.circle.fill"),
            ),
            Page(
                kicker: "onboard.pets.kicker".localized,
                title: "onboard.pets.title".localized,
                body: "onboard.pets.body".localized,
                hero: .gif("pet9"),
            ),
            Page(
                kicker: "onboard.trade.kicker".localized,
                title: "onboard.trade.title".localized,
                body: "onboard.trade.body".localized,
                hero: .symbol("arrow.left.arrow.right.circle.fill"),
            ),
            Page(
                kicker: "onboard.privacy.kicker".localized,
                title: "onboard.privacy.title".localized,
                body: "onboard.privacy.body".localized,
                hero: .symbol("eye.slash.fill"),
            ),
        ]
    }

    var body: some View {
        // `lang` is observed via `@StateObject`, so a `set(_:)` from
        // the picker fires `objectWillChange` on LanguageManager
        // and SwiftUI re-renders this body. `pages` re-computes off
        // `*.localized` against the new bundle and the current page
        // index is preserved (no `.id(...)` forcing a state-resetting
        // re-mount).
        ZStack {
            Theme.Color.bgPrimary.ignoresSafeArea()
            if entering {
                EnteringTransitionView(onComplete: {
                    UserDefaults.standard.set(true, forKey: "rcq.onboarded")
                    onFinish()
                })
                .transition(.opacity)
            } else {
                deck
                    .transition(.opacity)
            }
        }
        .sheet(isPresented: $showLanguagePicker) {
            LanguagePickerSheet()
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: - top bar (Skip + language)

    private var topBar: some View {
        HStack {
            // Skip — visible from page 0; jumps straight to the
            // last page so the user can hit "Get started" without
            // scrolling through the whole deck. Hidden on the last
            // page itself (no-op there).
            if page < pages.count - 1 {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        page = pages.count - 1
                    }
                } label: {
                    Text("onboard.cta.skip".localized)
                        .font(.system(.footnote, weight: .semibold))
                        .foregroundColor(Theme.Color.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(Theme.Color.bgSecondary.opacity(0.6))
                        )
                }
            } else {
                // Reserve the slot so the language pill doesn't
                // jump horizontally on the last page.
                Color.clear.frame(width: 1, height: 1)
            }
            Spacer()
            // Language pill — opens the picker sheet. Compact form
            // (globe + native code) so it doesn't compete with the
            // hero. Available on every page; first impression
            // matters most on page 0 but a Russian-speaking user
            // who lands on the English copy mid-deck deserves the
            // same way out.
            Button {
                showLanguagePicker = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "globe")
                        .font(.system(size: 12, weight: .semibold))
                    Text(lang.current.shortLabel)
                        .font(.system(.footnote, weight: .semibold))
                }
                .foregroundColor(Theme.Color.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(Theme.Color.bgSecondary.opacity(0.6))
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    // MARK: - page deck

    private var deck: some View {
        VStack(spacing: 0) {
            topBar
            TabView(selection: $page) {
                ForEach(Array(pages.enumerated()), id: \.offset) { idx, p in
                    pageView(p)
                        .tag(idx)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.easeInOut(duration: 0.25), value: page)
            pageDots
            ctaRow
        }
    }

    // MARK: - Page model

    private struct Page {
        let kicker: String
        let title: String
        let body: String
        let hero: Hero
    }

    private enum Hero {
        case logo
        case symbol(String)
        case gif(String)
        case png(String)
        case statusRow
    }

    @ViewBuilder
    private func pageView(_ p: Page) -> some View {
        VStack(spacing: 18) {
            Spacer()
            heroView(for: p.hero)
            VStack(spacing: 8) {
                Text(p.kicker)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.Color.accent)
                    .tracking(3)
                Text(p.title)
                    .font(.custom("Georgia", size: 28))
                    .foregroundColor(Theme.Color.textPrimary)
                    .multilineTextAlignment(.center)
                Text(p.body)
                    .font(.callout)
                    .foregroundColor(Theme.Color.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }
            Spacer()
        }
    }

    /// Hero hub. Sized down from the previous 120pt to ~88pt so
    /// the body copy gets visual weight on smaller phones; the
    /// page reads as "look at the text" instead of "look at the
    /// big icon". Logo path uses our own Logo.imageset, not an
    /// SF Symbol fallback.
    @ViewBuilder
    private func heroView(for hero: Hero) -> some View {
        switch hero {
        case .logo:
            // Same continuous slow spin as BootSplash / AboutSheet
            // / final transition — keeps the brand mark in motion
            // wherever it shows at size. Encapsulated in
            // `SlowSpinningLogo` so each call site doesn't need
            // its own `@State angle`.
            SlowSpinningLogo(size: 96)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(Theme.Color.accent)
                .frame(height: 88)
        case .gif(let stem):
            // Use the chat's GIFImage loader rather than AnimatedGIFImage —
            // it has subdirectory fallbacks for the bundled `Emoticons/`
            // tree and re-kicks the animation across SwiftUI re-mounts,
            // matching how the chat picker renders the same asset.
            if GIFImage.cachedImage(for: stem) != nil {
                GIFImage(name: stem)
                    .frame(width: 88, height: 88)
            } else {
                Image(systemName: "face.smiling")
                    .font(.system(size: 64))
                    .frame(height: 88)
            }
        case .png(let stem):
            if let url = Bundle.main.url(forResource: stem, withExtension: "png"),
               let img = UIImage(contentsOfFile: url.path) {
                Image(uiImage: img)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: 88, height: 88)
            } else {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 64))
                    .frame(height: 88)
            }
        case .statusRow:
            HStack(spacing: 12) {
                ForEach(UserStatus.allCases) { s in
                    StatusIcon(status: s, size: 32)
                }
            }
            .frame(height: 88)
        }
    }

    // MARK: - Dots + CTA

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<pages.count, id: \.self) { i in
                Circle()
                    .fill(i == page ? Theme.Color.accent : Theme.Color.divider)
                    .frame(width: 7, height: 7)
            }
        }
        .padding(.bottom, 18)
        .padding(.top, 4)
    }

    private var ctaRow: some View {
        HStack(spacing: 10) {
            if page > 0 {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { page -= 1 }
                } label: {
                    Text("onboard.cta.back".localized)
                        .font(.system(.body, weight: .semibold))
                        .foregroundColor(Theme.Color.textPrimary)
                        .frame(width: 90, height: 50)
                        .background(Theme.Color.bgSecondary)
                        .cornerRadius(8)
                }
            }
            Button {
                if page < pages.count - 1 {
                    withAnimation(.easeInOut(duration: 0.25)) { page += 1 }
                } else {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    withAnimation(.easeInOut(duration: 0.5)) {
                        entering = true
                    }
                }
            } label: {
                Text((page < pages.count - 1
                      ? "onboard.cta.next"
                      : "onboard.cta.start").localized)
                    .font(.system(.body, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Theme.Color.accent)
                    .cornerRadius(8)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
    }
}

// MARK: - Language picker sheet

/// Picker presented from the onboarding top-bar globe pill. Same
/// surface shape as the language list inside `SettingsView`, but
/// pinned to a sheet so it doesn't pull the user out of onboarding.
private struct LanguagePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var lang = LanguageManager.shared

    var body: some View {
        NavigationStack {
            List {
                ForEach(AppLanguage.allCases) { language in
                    Button {
                        lang.set(language)
                        dismiss()
                    } label: {
                        HStack {
                            Text(language.nativeName)
                                .foregroundColor(Theme.Color.textPrimary)
                            Spacer()
                            if lang.current == language {
                                Image(systemName: "checkmark")
                                    .foregroundColor(Theme.Color.accent)
                            }
                        }
                    }
                }
            }
            .navigationTitle("settings.language".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("common.done".localized) { dismiss() }
                }
            }
        }
    }
}

// MARK: - Entering-transition surface

/// Brief branded surface shown after the user taps "Get started"
/// on the last onboarding page, before the contact list takes over.
/// Two beats: logo settles in (0.0–0.6s), tagline fades in
/// (0.6–1.2s), then a clean handoff at 2.4s. Total budget ≈ 2.4s —
/// long enough to register as intentional, short enough that an
/// impatient user doesn't rage-tap. The original third beat had an
/// expanding accent ring + full-screen accent colour sweep; both
/// were removed by request — the screen now just sits on the
/// logo+tagline until the handoff fires.
private struct EnteringTransitionView: View {
    let onComplete: () -> Void

    @State private var logoScale: CGFloat = 0.5
    @State private var logoOpacity: Double = 0
    @State private var taglineOpacity: Double = 0
    /// Continuous slow rotation — additive on top of the
    /// scale-in beat, runs the whole time the splash is visible.
    @State private var logoRotation: Double = 0

    var body: some View {
        ZStack {
            Theme.Color.bgPrimary
                .ignoresSafeArea()

            VStack(spacing: 22) {
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 110, height: 110)
                    .rotationEffect(.degrees(logoRotation))
                    .scaleEffect(logoScale)
                    .opacity(logoOpacity)
                Text("onboard.transition.tagline".localized)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.Color.accent)
                    .tracking(4)
                    .opacity(taglineOpacity)
            }
        }
        .onAppear {
            // Beat 1 — logo settles in.
            withAnimation(.spring(response: 0.55, dampingFraction: 0.65)) {
                logoScale = 1.0
                logoOpacity = 1.0
            }
            // Continuous spin — drives in parallel with the
            // scale-in via a separate `withAnimation` so the
            // spring on `logoScale` doesn't get yanked into the
            // linear curve. `.repeatForever(autoreverses: false)`
            // → tail of one revolution glues to head of the
            // next, no visible reset jolt.
            withAnimation(.linear(duration: 30).repeatForever(autoreverses: false)) {
                logoRotation = 360
            }
            // Beat 2 — tagline fade-in just after the logo lands.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                withAnimation(.easeOut(duration: 0.55)) {
                    taglineOpacity = 1.0
                }
            }
            // Hand-off — RootView swaps in the contact list at the
            // same beat the old colour sweep used to fire on, so
            // the overall transition timing the user is used to
            // doesn't shift.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                onComplete()
            }
        }
    }
}

private extension AppLanguage {
    /// Two-or-three-character label for the compact onboarding
    /// pill. Falls back to the language code itself, uppercased,
    /// for entries we want to keep terse on a small button. Native
    /// names live on `nativeName` and stay reserved for the
    /// full-list picker.
    var shortLabel: String {
        switch self {
        case .english:     return "EN"
        case .russian:     return "RU"
        case .spanish:     return "ES"
        case .portuguese:  return "PT"
        case .french:      return "FR"
        case .german:      return "DE"
        case .italian:     return "IT"
        case .turkish:     return "TR"
        case .polish:      return "PL"
        case .ukrainian:   return "UA"
        case .chineseSimp: return "中"
        case .japanese:    return "日"
        case .korean:      return "한"
        case .arabic:      return "ع"
        case .hindi:       return "हि"
        }
    }
}

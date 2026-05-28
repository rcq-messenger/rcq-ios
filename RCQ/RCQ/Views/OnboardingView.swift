import SwiftUI

/// First-launch tour gated by `@AppStorage("rcq.onboarded")` so it survives an account burn.
struct OnboardingView: View {
    let onFinish: () -> Void

    @State private var page: Int = 0
    @State private var showLanguagePicker = false
    @State private var showServerPicker = false
    @State private var entering: Bool = false
    @StateObject private var lang = LanguageManager.shared
    @AppStorage("rcq.baseURL") private var customServer: String = ""

    private var pages: [Page] {
        [
            Page(
                kicker: "onboard.welcome.kicker".localized,
                title: "onboard.welcome.title".localized,
                body: "onboard.welcome.body".localized,
                hero: .logo,
            ),
            Page(
                kicker: "onboard.anon.kicker".localized,
                title: "onboard.anon.title".localized,
                body: "onboard.anon.body".localized,
                hero: .symbol("number.circle.fill"),
            ),
            Page(
                kicker: "onboard.mesh.kicker".localized,
                title: "onboard.mesh.title".localized,
                body: "onboard.mesh.body".localized,
                hero: .symbol("antenna.radiowaves.left.and.right"),
            ),
            Page(
                kicker: "onboard.chat.kicker".localized,
                title: "onboard.chat.title".localized,
                body: "onboard.chat.body".localized,
                hero: .symbol("lock.fill"),
            ),
            Page(
                kicker: "onboard.pin.kicker".localized,
                title: "onboard.pin.title".localized,
                body: "onboard.pin.body".localized,
                hero: .symbol("lock.shield.fill"),
            ),
            Page(
                kicker: "onboard.status.kicker".localized,
                title: "onboard.status.title".localized,
                body: "onboard.status.body".localized,
                hero: .statusRow,
            ),
        ]
    }

    var body: some View {
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
        .sheet(isPresented: $showServerPicker) {
            ServerPickerSheet()
        }
    }

    // MARK: - top bar (Skip + language)

    private var topBar: some View {
        HStack {
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
                serverPill
            }
            Spacer()
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

    // MARK: - Server picker affordance

    /// Compact pill in the top-leading slot of the toolbar on the
    /// last onboarding page. Same Skip-button-slot the deck uses on
    /// earlier pages — on the last page Skip is gone (no later page
    /// to jump to), so the slot hosts the server picker affordance
    /// instead. Tapping opens `ServerPickerSheet` to choose a
    /// different backend from the public catalogue. Sized to match
    /// the language pill on the trailing edge.
    private var serverPill: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            showServerPicker = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "server.rack")
                    .font(.system(size: 12, weight: .semibold))
                Text(activeServerHost)
                    .font(.system(.footnote, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundColor(Theme.Color.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(Theme.Color.bgSecondary.opacity(0.6))
            )
        }
        .buttonStyle(.plain)
    }

    /// Host portion of the current `rcq.baseURL`, defaulting to
    /// `api.rcq.app` when nothing is overridden.
    private var activeServerHost: String {
        let raw = customServer.isEmpty ? "https://api.rcq.app" : customServer
        return URL(string: raw)?.host ?? raw
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

    @ViewBuilder
    private func heroView(for hero: Hero) -> some View {
        switch hero {
        case .logo:
            SlowSpinningLogo(size: 96)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(Theme.Color.accent)
                .frame(height: 88)
        case .gif(let stem):
            // GIFImage has the Emoticons/ subdirectory fallbacks AnimatedGIFImage lacks.
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
                    // Mint Account[0] in AccountManager BEFORE the
                    // boot pipeline runs. Without this, AuthService's
                    // first /auth/register writes Keychain under the
                    // legacy unprefixed slot (because
                    // AppGroup.readActiveAccountID returns nil with
                    // an empty roster), and the account-switcher pill
                    // in ContactListView stays hidden until the next
                    // launch's legacy-migration mints Account[0]
                    // retroactively. By calling add() here, the
                    // active account is set up front: subsequent
                    // KeychainStore.set writes land in the prefixed
                    // slot directly, ContactListView renders with
                    // accountManager.active non-nil, pill shows.
                    let chosenURL = customServer.isEmpty
                        ? "https://api.rcq.app"
                        : customServer
                    AccountManager.shared.add(serverURL: chosenURL)
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

private struct EnteringTransitionView: View {
    let onComplete: () -> Void

    @State private var logoScale: CGFloat = 0.5
    @State private var logoOpacity: Double = 0
    @State private var taglineOpacity: Double = 0
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
            withAnimation(.spring(response: 0.55, dampingFraction: 0.65)) {
                logoScale = 1.0
                logoOpacity = 1.0
            }
            // Spin runs on a separate withAnimation so the spring on logoScale isn't linearized.
            withAnimation(.linear(duration: 30).repeatForever(autoreverses: false)) {
                logoRotation = 360
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                withAnimation(.easeOut(duration: 0.55)) {
                    taglineOpacity = 1.0
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                onComplete()
            }
        }
    }
}

private extension AppLanguage {
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

import SwiftUI

/// Premium-feel UIN marketplace. The hero is the rarity-tinted plate
/// — pick a number and the plate paints itself in the colour of its
/// scarcity (legendary gold for a 3-digit, epic violet for 4, fading
/// down to a calm teal for everyday 8-9 digit handles). Price is NOT
/// shown until the server confirms the candidate is free, at which
/// point it springs up as a counter roll under the plate. The
/// suggestions strip surfaces server-picked free UINs across mixed
/// lengths so the user has a fast on-ramp without typing random
/// digits.
struct UINShopView: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var plateFocused: Bool

    @State private var typed: String = ""
    @State private var quote: QuoteResponse?
    @State private var suggestions: [SuggestionResponse] = []
    @State private var checking = false
    @State private var buying = false
    @State private var showConfirm = false
    @State private var error: String?
    @State private var quoteTask: Task<Void, Never>?
    @State private var sparkle = false
    @State private var revealedCents: Int = 0

    private var ownUIN: Int? { AuthService.shared.ownUIN }

    private var typedDigits: [Character] { Array(typed) }
    private var typedLength: Int { typed.count }
    private var isValidLength: Bool { (3...9).contains(typedLength) }

    private var rarity: UINRarity { UINRarity.forLength(typedLength) }

    private var displayedQuote: QuoteResponse? {
        guard let q = quote, q.uin == Int(typed) else { return nil }
        return q
    }

    private var isAvailable: Bool {
        displayedQuote?.available ?? false
    }

    private var canBuy: Bool {
        isValidLength && isAvailable && !buying
    }

    var body: some View {
        ZStack {
            backdrop
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 22) {
                        plateSection
                            .padding(.top, 18)
                        statusRow
                        priceReveal
                        suggestionsSection
                        Color.clear.frame(height: 130) // room under floating CTA
                    }
                    .padding(.horizontal, 20)
                }
            }

            VStack {
                Spacer()
                floatingBuy
            }
        }
        .background(
            // Invisible numeric field — focused via the plate tap.
            TextField("", text: $typed)
                .keyboardType(.numberPad)
                .focused($plateFocused)
                .opacity(0)
                .frame(width: 1, height: 1)
                .onChange(of: typed) { newValue in
                    let filtered = String(newValue.filter(\.isNumber).prefix(9))
                    if filtered != newValue { typed = filtered; return }
                    quote = nil
                    error = nil
                    scheduleQuote()
                }
        )
        .task { await refreshSuggestions() }
        .confirmationDialog(
            confirmTitle,
            isPresented: $showConfirm,
            titleVisibility: .visible
        ) {
            Button(confirmCTA, role: .destructive) {
                Task { await runPurchase() }
            }
            Button("common.cancel".localized, role: .cancel) {}
        } message: {
            Text("uin_shop.confirm.body".localized)
        }
    }

    // MARK: - Backdrop

    private var backdrop: some View {
        ZStack {
            Theme.Color.bgPrimary
            // Soft animated glow that tints the whole screen toward
            // the picked rarity. Goes near-invisible for common
            // (8-9 digit) picks, intensifies for rare ones.
            RadialGradient(
                colors: [rarity.glow.opacity(rarity.glowOpacity), .clear],
                center: .top,
                startRadius: 40,
                endRadius: 520
            )
            .blendMode(.plusLighter)
            .animation(.easeInOut(duration: 0.5), value: rarity)
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.Color.textPrimary)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Theme.Color.bgSecondary))
            }
            Spacer()
            VStack(spacing: 1) {
                Text("uin_shop.title".localized)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.Color.textPrimary)
                Text(currentSubtitle)
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(Theme.Color.textSecondary)
            }
            Spacer()
            Color.clear.frame(width: 32, height: 32)
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var currentSubtitle: String {
        if let uin = ownUIN {
            return String(format: "uin_shop.subtitle_current".localized, String(uin))
        }
        return "uin_shop.subtitle_pick".localized
    }

    // MARK: - Plate

    private var plateSection: some View {
        VStack(spacing: 12) {
            UINPlate(
                digits: typedDigits,
                length: typedLength,
                rarity: rarity,
                isActive: plateFocused,
                sparkle: sparkle
            )
            .frame(maxWidth: .infinity)
            .frame(height: 168)
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .onTapGesture { plateFocused = true }

            rarityChip
        }
    }

    @ViewBuilder
    private var rarityChip: some View {
        if isValidLength {
            HStack(spacing: 6) {
                Circle().fill(rarity.glow).frame(width: 6, height: 6)
                Text(rarity.label)
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.4)
                    .foregroundColor(rarity.labelTint)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(rarity.glow.opacity(0.14))
            )
            .overlay(
                Capsule().strokeBorder(rarity.glow.opacity(0.35), lineWidth: 1)
            )
            .transition(.scale(scale: 0.6).combined(with: .opacity))
        } else {
            Text("uin_shop.plate.tap_hint".localized)
                .font(.caption2)
                .foregroundColor(Theme.Color.textSecondary)
                .transition(.opacity)
        }
    }

    // MARK: - Status row

    @ViewBuilder
    private var statusRow: some View {
        if typed.isEmpty {
            statusPill(text: "uin_shop.status.idle".localized, icon: "keyboard", tint: Theme.Color.textSecondary)
                .transition(.opacity)
        } else if !isValidLength {
            statusPill(text: shortStatusText, icon: "ellipsis", tint: Theme.Color.textSecondary)
        } else if checking, displayedQuote == nil {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.8)
                Text("uin_shop.status.checking".localized)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.Color.textSecondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Capsule().fill(Theme.Color.bgSecondary))
        } else if let q = displayedQuote {
            if q.available {
                statusPill(text: "uin_shop.status.available".localized, icon: "checkmark.seal.fill", tint: .green)
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
            } else {
                statusPill(text: reasonText(q.reason ?? "taken"), icon: "xmark.octagon.fill", tint: .red.opacity(0.85))
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
            }
        }
    }

    private func statusPill(text: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(tint)
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.Color.textPrimary)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Capsule().fill(Theme.Color.bgSecondary))
        .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 1))
    }

    private var shortStatusText: String {
        if typedLength < 3 { return "uin_shop.hint.too_short".localized }
        return "uin_shop.hint.tap_to_check".localized
    }

    // MARK: - Price reveal

    @ViewBuilder
    private var priceReveal: some View {
        if isAvailable, let cents = displayedQuote?.priceCents {
            VStack(spacing: 4) {
                Text("uin_shop.price.label".localized)
                    .font(.system(size: 10, weight: .bold))
                    .tracking(2)
                    .foregroundColor(Theme.Color.textSecondary)
                Text(priceDisplay(cents: revealedCents))
                    .font(.system(size: 56, weight: .heavy, design: .rounded))
                    .foregroundStyle(rarity.priceGradient)
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: false))
                    .animation(.spring(response: 0.55, dampingFraction: 0.7), value: revealedCents)
            }
            .padding(.vertical, 8)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .onAppear { animateReveal(toCents: cents) }
            .onChange(of: cents) { newCents in animateReveal(toCents: newCents) }
        } else {
            Color.clear.frame(height: 1)
        }
    }

    private func animateReveal(toCents target: Int) {
        revealedCents = 0
        // Two-step: snap to ~62% almost immediately so the animation
        // feels fast at first, then settle to the final number with
        // the spring; gives the slot-machine impression without a
        // long count-up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeOut(duration: 0.18)) {
                revealedCents = Int(Double(target) * 0.62)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) {
                revealedCents = target
            }
            sparkle.toggle()
        }
    }

    private func priceDisplay(cents: Int) -> String {
        let dollars = Double(cents) / 100.0
        return String(format: "$%.2f", dollars)
    }

    // MARK: - Suggestions

    @ViewBuilder
    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("uin_shop.suggestions.header".localized)
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.4)
                    .foregroundColor(Theme.Color.textSecondary)
                Spacer()
                Button {
                    Task { await refreshSuggestions(force: true) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        Text("uin_shop.suggestions.refresh".localized)
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.Color.accent)
                }
                .buttonStyle(.plain)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    if suggestions.isEmpty {
                        ForEach(0..<5, id: \.self) { _ in placeholderChip }
                    } else {
                        ForEach(suggestions) { s in
                            SuggestionCard(suggestion: s) {
                                typed = String(s.uin)
                                plateFocused = true
                                scheduleQuote()
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var placeholderChip: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Theme.Color.bgSecondary)
            .frame(width: 120, height: 64)
            .opacity(0.5)
    }

    // MARK: - Floating Buy

    @ViewBuilder
    private var floatingBuy: some View {
        if buying {
            HStack(spacing: 10) {
                ProgressView().tint(.white)
                Text("uin_shop.buy.processing".localized)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
            }
            .padding(.vertical, 16).frame(maxWidth: .infinity)
            .background(
                LinearGradient(colors: [rarity.glow, rarity.glow.opacity(0.7)],
                               startPoint: .leading, endPoint: .trailing)
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
            .transition(.opacity)
        } else if canBuy, let cents = displayedQuote?.priceCents {
            Button {
                showConfirm = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "creditcard.fill")
                        .font(.system(size: 16, weight: .bold))
                    Text(String(format: "uin_shop.buy.cta".localized, priceDisplay(cents: cents)))
                        .font(.system(size: 16, weight: .bold))
                    Spacer()
                    Image(systemName: "arrow.right")
                        .font(.system(size: 14, weight: .bold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
                .background(
                    LinearGradient(
                        colors: [rarity.glow, rarity.glow.opacity(0.7)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: rarity.glow.opacity(0.45), radius: 18, y: 6)
            }
            .buttonStyle(BuyButtonStyle())
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if let error {
            Text(error)
                .font(.caption2.weight(.semibold))
                .foregroundColor(.red)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
        }
    }

    // MARK: - Buy / quote orchestration

    private var confirmTitle: String {
        guard let q = displayedQuote, q.available, let cents = q.priceCents else {
            return "uin_shop.confirm.title".localized
        }
        return String(format: "uin_shop.confirm.title_priced".localized, String(q.uin), priceDisplay(cents: cents))
    }

    private var confirmCTA: String {
        guard let q = displayedQuote, q.available, let cents = q.priceCents else {
            return "uin_shop.confirm.cta".localized
        }
        return String(format: "uin_shop.confirm.cta_priced".localized, priceDisplay(cents: cents))
    }

    private func scheduleQuote() {
        quoteTask?.cancel()
        guard let parsed = Int(typed), parsed > 0, isValidLength else {
            quote = nil
            return
        }
        quoteTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            await fetchQuote(parsed)
        }
    }

    private func fetchQuote(_ uin: Int) async {
        checking = true
        defer { checking = false }
        struct Body: Encodable { let uin: Int }
        do {
            let resp: QuoteResponse = try await APIClient.shared.request(
                "POST", "/uin/quote", body: Body(uin: uin)
            )
            if !Task.isCancelled, Int(typed) == uin {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
                    quote = resp
                }
            }
        } catch {
            // soft fail; user can retype
        }
    }

    private func refreshSuggestions(force: Bool = false) async {
        if !force && !suggestions.isEmpty { return }
        do {
            let resp: [SuggestionResponse] = try await APIClient.shared.request(
                "GET", "/uin/suggestions", query: ["count": "6"]
            )
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                suggestions = resp
            }
        } catch {
            // No suggestions surface: composer still works manually.
        }
    }

    private func runPurchase() async {
        guard let parsed = Int(typed) else { return }
        buying = true
        defer { buying = false }
        let mockReceipt = "mock-iap-\(Date().timeIntervalSince1970)"
        let result = await AppState.shared.purchaseUIN(parsed, receipt: mockReceipt)
        switch result {
        case .success:
            dismiss()
        case .taken:
            error = "uin_shop.error.taken".localized
            quote = nil
            await refreshSuggestions(force: true)
        case .cooldown:
            error = "uin_shop.error.cooldown".localized
        case .other(let msg):
            error = msg
        }
    }

    private func reasonText(_ reason: String) -> String {
        switch reason {
        case "taken": return "uin_shop.status.taken".localized
        case "too_short": return "uin_shop.status.too_short".localized
        case "too_long": return "uin_shop.status.too_long".localized
        case "self": return "uin_shop.status.self".localized
        default: return "uin_shop.status.unavailable".localized
        }
    }
}

// MARK: - Plate

private struct UINPlate: View {
    let digits: [Character]
    let length: Int
    let rarity: UINRarity
    let isActive: Bool
    let sparkle: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(rarity.plateFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [rarity.glow.opacity(0.6), rarity.glow.opacity(0.15)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.2
                        )
                )
                .shadow(color: rarity.glow.opacity(isActive ? 0.45 : 0.22),
                        radius: isActive ? 28 : 18, y: isActive ? 12 : 8)
            // Inner highlight band
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.06), .clear],
                        startPoint: .top,
                        endPoint: .center
                    )
                )

            HStack(spacing: 6) {
                ForEach(0..<9, id: \.self) { i in
                    digitSlot(i: i)
                }
            }
            .padding(.horizontal, 18)
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: rarity)
    }

    @ViewBuilder
    private func digitSlot(i: Int) -> some View {
        if i < digits.count {
            Text(String(digits[i]))
                .font(.system(size: 52, weight: .black, design: .rounded))
                .foregroundStyle(rarity.digitGradient)
                .frame(minWidth: 24)
                .transition(.asymmetric(
                    insertion: .scale(scale: 1.4).combined(with: .opacity).combined(with: .move(edge: .bottom)),
                    removal: .opacity
                ))
                .id("d-\(i)-\(digits[i])")
                .animation(.spring(response: 0.35, dampingFraction: 0.62), value: digits)
        } else {
            Text("_")
                .font(.system(size: 38, weight: .heavy, design: .rounded))
                .foregroundColor(Theme.Color.textSecondary.opacity(i < 3 ? 0.6 : 0.3))
                .frame(minWidth: 22)
                .offset(y: 6)
        }
    }
}

// MARK: - Suggestion card

private struct SuggestionCard: View {
    let suggestion: SuggestionResponse
    let onTap: () -> Void

    private var rarity: UINRarity { UINRarity.forLength(suggestion.length) }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                Text(rarity.shortLabel)
                    .font(.system(size: 9, weight: .black))
                    .tracking(1.2)
                    .foregroundColor(rarity.labelTint)
                Text(String(suggestion.uin))
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .foregroundStyle(rarity.digitGradient)
                    .monospacedDigit()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minWidth: 110, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(rarity.plateFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(rarity.glow.opacity(0.35), lineWidth: 1)
            )
            .shadow(color: rarity.glow.opacity(0.25), radius: 10, y: 4)
        }
        .buttonStyle(SuggestionPressStyle())
    }
}

private struct SuggestionPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

private struct BuyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Rarity table

private struct UINRarity: Equatable {
    let label: String
    let shortLabel: String
    let labelTint: Color
    let glow: Color
    let glowOpacity: Double
    let plateFill: AnyShapeStyle
    let digitGradient: AnyShapeStyle
    let priceGradient: AnyShapeStyle

    static func forLength(_ n: Int) -> UINRarity {
        switch n {
        case 3:
            return UINRarity(
                label: "uin_shop.rarity.legendary".localized,
                shortLabel: "LGD",
                labelTint: Color(red: 1.0, green: 0.85, blue: 0.4),
                glow: Color(red: 1.0, green: 0.74, blue: 0.2),
                glowOpacity: 0.32,
                plateFill: AnyShapeStyle(LinearGradient(
                    colors: [
                        Color(red: 0.30, green: 0.20, blue: 0.05),
                        Color(red: 0.18, green: 0.10, blue: 0.02),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )),
                digitGradient: AnyShapeStyle(LinearGradient(
                    colors: [
                        Color(red: 1.0, green: 0.94, blue: 0.55),
                        Color(red: 1.0, green: 0.72, blue: 0.20),
                    ],
                    startPoint: .top, endPoint: .bottom
                )),
                priceGradient: AnyShapeStyle(LinearGradient(
                    colors: [
                        Color(red: 1.0, green: 0.94, blue: 0.55),
                        Color(red: 1.0, green: 0.55, blue: 0.20),
                    ],
                    startPoint: .top, endPoint: .bottom
                ))
            )
        case 4:
            return UINRarity(
                label: "uin_shop.rarity.epic".localized,
                shortLabel: "EPIC",
                labelTint: Color(red: 0.88, green: 0.72, blue: 1.0),
                glow: Color(red: 0.72, green: 0.36, blue: 0.95),
                glowOpacity: 0.28,
                plateFill: AnyShapeStyle(LinearGradient(
                    colors: [
                        Color(red: 0.20, green: 0.10, blue: 0.32),
                        Color(red: 0.10, green: 0.05, blue: 0.18),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )),
                digitGradient: AnyShapeStyle(LinearGradient(
                    colors: [
                        Color(red: 0.95, green: 0.70, blue: 1.0),
                        Color(red: 0.60, green: 0.35, blue: 0.95),
                    ],
                    startPoint: .top, endPoint: .bottom
                )),
                priceGradient: AnyShapeStyle(LinearGradient(
                    colors: [
                        Color(red: 0.95, green: 0.70, blue: 1.0),
                        Color(red: 0.55, green: 0.30, blue: 0.95),
                    ],
                    startPoint: .top, endPoint: .bottom
                ))
            )
        case 5:
            return UINRarity(
                label: "uin_shop.rarity.rare".localized,
                shortLabel: "RARE",
                labelTint: Color(red: 0.65, green: 0.86, blue: 1.0),
                glow: Color(red: 0.30, green: 0.62, blue: 1.0),
                glowOpacity: 0.22,
                plateFill: AnyShapeStyle(LinearGradient(
                    colors: [
                        Color(red: 0.07, green: 0.15, blue: 0.28),
                        Color(red: 0.03, green: 0.08, blue: 0.15),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )),
                digitGradient: AnyShapeStyle(LinearGradient(
                    colors: [
                        Color(red: 0.70, green: 0.90, blue: 1.0),
                        Color(red: 0.30, green: 0.55, blue: 1.0),
                    ],
                    startPoint: .top, endPoint: .bottom
                )),
                priceGradient: AnyShapeStyle(LinearGradient(
                    colors: [
                        Color(red: 0.70, green: 0.90, blue: 1.0),
                        Color(red: 0.20, green: 0.45, blue: 0.95),
                    ],
                    startPoint: .top, endPoint: .bottom
                ))
            )
        case 6:
            return UINRarity(
                label: "uin_shop.rarity.uncommon".localized,
                shortLabel: "UNC",
                labelTint: Color(red: 0.55, green: 0.95, blue: 0.80),
                glow: Color(red: 0.20, green: 0.78, blue: 0.60),
                glowOpacity: 0.18,
                plateFill: AnyShapeStyle(LinearGradient(
                    colors: [
                        Color(red: 0.05, green: 0.18, blue: 0.14),
                        Color(red: 0.03, green: 0.10, blue: 0.08),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )),
                digitGradient: AnyShapeStyle(LinearGradient(
                    colors: [
                        Color(red: 0.70, green: 0.95, blue: 0.85),
                        Color(red: 0.25, green: 0.72, blue: 0.55),
                    ],
                    startPoint: .top, endPoint: .bottom
                )),
                priceGradient: AnyShapeStyle(LinearGradient(
                    colors: [
                        Color(red: 0.70, green: 0.95, blue: 0.85),
                        Color(red: 0.25, green: 0.65, blue: 0.55),
                    ],
                    startPoint: .top, endPoint: .bottom
                ))
            )
        case 7:
            return UINRarity(
                label: "uin_shop.rarity.common".localized,
                shortLabel: "COM",
                labelTint: Color(red: 0.78, green: 0.94, blue: 0.7),
                glow: Color(red: 0.45, green: 0.80, blue: 0.45),
                glowOpacity: 0.14,
                plateFill: AnyShapeStyle(LinearGradient(
                    colors: [
                        Color(red: 0.08, green: 0.16, blue: 0.10),
                        Color(red: 0.04, green: 0.10, blue: 0.06),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )),
                digitGradient: AnyShapeStyle(LinearGradient(
                    colors: [
                        Color(red: 0.85, green: 0.95, blue: 0.80),
                        Color(red: 0.50, green: 0.78, blue: 0.50),
                    ],
                    startPoint: .top, endPoint: .bottom
                )),
                priceGradient: AnyShapeStyle(LinearGradient(
                    colors: [
                        Color(red: 0.85, green: 0.95, blue: 0.80),
                        Color(red: 0.40, green: 0.72, blue: 0.50),
                    ],
                    startPoint: .top, endPoint: .bottom
                ))
            )
        default:
            return UINRarity(
                label: "uin_shop.rarity.standard".localized,
                shortLabel: "STD",
                labelTint: Color(white: 0.78),
                glow: Color(red: 0.35, green: 0.42, blue: 0.55),
                glowOpacity: 0.08,
                plateFill: AnyShapeStyle(LinearGradient(
                    colors: [
                        Color(red: 0.10, green: 0.11, blue: 0.14),
                        Color(red: 0.06, green: 0.07, blue: 0.10),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )),
                digitGradient: AnyShapeStyle(LinearGradient(
                    colors: [
                        Color(white: 0.95),
                        Color(white: 0.70),
                    ],
                    startPoint: .top, endPoint: .bottom
                )),
                priceGradient: AnyShapeStyle(LinearGradient(
                    colors: [
                        Color(white: 0.95),
                        Color(white: 0.65),
                    ],
                    startPoint: .top, endPoint: .bottom
                ))
            )
        }
    }

    static func == (lhs: UINRarity, rhs: UINRarity) -> Bool {
        lhs.shortLabel == rhs.shortLabel
    }
}

// MARK: - DTOs

private struct QuoteResponse: Decodable {
    let uin: Int
    let length: Int
    let available: Bool
    let priceCents: Int?
    let priceDisplay: String?
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case uin, length, available, reason
        case priceCents = "price_cents"
        case priceDisplay = "price_display"
    }
}

private struct SuggestionResponse: Decodable, Identifiable {
    let uin: Int
    let length: Int
    let priceCents: Int
    let priceDisplay: String

    var id: Int { uin }

    enum CodingKeys: String, CodingKey {
        case uin, length
        case priceCents = "price_cents"
        case priceDisplay = "price_display"
    }
}

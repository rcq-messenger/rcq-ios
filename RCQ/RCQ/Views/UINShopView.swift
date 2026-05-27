import SwiftUI

/// Minimal UIN marketplace. Type a number, the server says if it's
/// free, the price appears underneath. One button buys. Fullscreen
/// presentation, generous whitespace, no chrome.
struct UINShopView: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var fieldFocused: Bool

    @State private var typed: String = ""
    @State private var quote: QuoteResponse?
    @State private var suggestions: [SuggestionResponse] = []
    @State private var checking = false
    @State private var buying = false
    @State private var showConfirm = false
    @State private var error: String?
    @State private var quoteTask: Task<Void, Never>?
    @State private var revealedCents: Int = 0

    private var ownUIN: Int? { AuthService.shared.ownUIN }
    private var typedLength: Int { typed.count }
    private var isValidLength: Bool { (3...9).contains(typedLength) }

    private var displayedQuote: QuoteResponse? {
        guard let q = quote, q.uin == Int(typed) else { return nil }
        return q
    }

    private var isAvailable: Bool { displayedQuote?.available ?? false }
    private var canBuy: Bool { isValidLength && isAvailable && !buying }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.Color.bgPrimary.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    Spacer().frame(height: 24)
                    plate
                        .padding(.top, 48)
                        .padding(.bottom, 28)
                    statusLine
                        .frame(height: 18)
                    priceLine
                        .frame(minHeight: 88)
                    Spacer().frame(height: 24)
                    suggestionsRow
                    Spacer().frame(height: 220)
                }
                .frame(maxWidth: .infinity)
            }

            topBar

            VStack {
                Spacer()
                bottomCTA
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            }
        }
        .background(
            TextField("", text: $typed)
                .keyboardType(.numberPad)
                .focused($fieldFocused)
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
        .onAppear {
            // Auto-focus so the keyboard is up and the user can start
            // typing immediately. Premium-feel: no extra tap to begin.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                fieldFocused = true
            }
        }
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

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.Color.textSecondary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            Spacer()
            Text("uin_shop.title".localized)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.Color.textPrimary)
            Spacer()
            Color.clear.frame(width: 36, height: 36)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    // MARK: - Plate

    private var plate: some View {
        Button(action: { fieldFocused = true }) {
            VStack(spacing: 10) {
                Text(displayedNumber)
                    .font(.system(size: 56, weight: .heavy, design: .monospaced))
                    .foregroundColor(typedLength == 0 ? Theme.Color.textSecondary.opacity(0.25) : Theme.Color.textPrimary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.spring(response: 0.32, dampingFraction: 0.78), value: typed)
                Text(typedLength == 0
                     ? "uin_shop.plate.hint".localized
                     : String(format: "uin_shop.plate.digits".localized, typedLength))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.Color.textSecondary.opacity(0.6))
                    .animation(.easeInOut(duration: 0.18), value: typedLength)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var displayedNumber: String {
        if typed.isEmpty { return "_ _ _" }
        return typed
    }

    // MARK: - Status line

    @ViewBuilder
    private var statusLine: some View {
        Group {
            if typed.isEmpty {
                Color.clear
            } else if !isValidLength {
                Text("uin_shop.hint.too_short".localized)
                    .foregroundColor(Theme.Color.textSecondary)
            } else if checking, displayedQuote == nil {
                Text("uin_shop.status.checking".localized)
                    .foregroundColor(Theme.Color.textSecondary)
            } else if let q = displayedQuote {
                if q.available {
                    Text("uin_shop.status.available".localized)
                        .foregroundColor(Theme.Color.accent)
                } else {
                    Text(reasonText(q.reason ?? "taken"))
                        .foregroundColor(Theme.Color.textSecondary)
                }
            } else {
                Color.clear
            }
        }
        .font(.system(size: 13, weight: .medium))
        .transition(.opacity)
    }

    // MARK: - Price

    @ViewBuilder
    private var priceLine: some View {
        if isAvailable, let cents = displayedQuote?.priceCents {
            Text(priceDisplay(cents: revealedCents))
                .font(.system(size: 72, weight: .black, design: .rounded))
                .foregroundColor(Theme.Color.textPrimary)
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: false))
                .animation(.spring(response: 0.55, dampingFraction: 0.7), value: revealedCents)
                .padding(.top, 6)
                .onAppear { animateReveal(toCents: cents) }
                .onChange(of: cents) { newCents in animateReveal(toCents: newCents) }
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
        } else {
            Color.clear
        }
    }

    private func animateReveal(toCents target: Int) {
        revealedCents = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeOut(duration: 0.18)) {
                revealedCents = Int(Double(target) * 0.6)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) {
                revealedCents = target
            }
        }
    }

    private func priceDisplay(cents: Int) -> String {
        let dollars = Double(cents) / 100.0
        if dollars >= 100 {
            return String(format: "$%.0f", dollars)
        }
        return String(format: "$%.2f", dollars)
    }

    // MARK: - Suggestions

    @ViewBuilder
    private var suggestionsRow: some View {
        VStack(spacing: 14) {
            Text("uin_shop.suggestions.header".localized)
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.6)
                .foregroundColor(Theme.Color.textSecondary.opacity(0.55))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    if suggestions.isEmpty {
                        ForEach(0..<4, id: \.self) { _ in
                            Text("———")
                                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                                .foregroundColor(Theme.Color.textSecondary.opacity(0.25))
                        }
                    } else {
                        ForEach(suggestions) { s in
                            Button {
                                typed = String(s.uin)
                                fieldFocused = true
                                scheduleQuote()
                            } label: {
                                Text(String(s.uin))
                                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                                    .foregroundColor(Theme.Color.textPrimary)
                                    .monospacedDigit()
                            }
                            .buttonStyle(SubtlePressStyle())
                        }
                    }
                }
                .padding(.horizontal, 24)
            }
            .frame(height: 26)
        }
    }

    // MARK: - Bottom CTA

    @ViewBuilder
    private var bottomCTA: some View {
        if buying {
            HStack(spacing: 10) {
                ProgressView().tint(.white)
                Text("uin_shop.buy.processing".localized)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(Theme.Color.accent)
            .clipShape(Capsule())
        } else if canBuy, let cents = displayedQuote?.priceCents {
            Button {
                showConfirm = true
            } label: {
                Text(String(format: "uin_shop.buy.cta".localized, priceDisplay(cents: cents)))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(Theme.Color.accent)
                    .clipShape(Capsule())
            }
            .buttonStyle(SubtlePressStyle())
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if let error {
            Text(error)
                .font(.caption.weight(.medium))
                .foregroundColor(.red.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 18)
        }
    }

    // MARK: - Orchestration

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
                "GET", "/uin/suggestions", query: ["count": "5"]
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

private struct SubtlePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
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

import SwiftUI

/// UIN marketplace. Fullscreen, keyboard-up immediately. A single
/// plate card with the typed digits is the hero. Status + a small
/// live-price preview sit underneath; when the server confirms the
/// UIN is free, the price re-emerges as the headline number in the
/// accent colour. One capsule CTA at the bottom. No carousel, no
/// extra chrome — the page exists to take a number and a tap.
struct UINShopView: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var fieldFocused: Bool

    @State private var typed: String = ""
    @State private var quote: QuoteResponse?
    @State private var checking = false
    @State private var buying = false
    @State private var showConfirm = false
    @State private var error: String?
    @State private var quoteTask: Task<Void, Never>?
    @State private var revealedCents: Int = 0

    private var ownUIN: Int? { AuthService.shared.ownUIN }
    private var typedLength: Int { typed.count }
    private var isValidLength: Bool { (3...9).contains(typedLength) }

    /// Local mirror of the server's `_PRICES_CENTS`. The /quote call
    /// is still authoritative for *availability*, but the price tier
    /// depends only on length — we can preview it immediately while
    /// the network round-trip lands.
    private static let priceCentsByLength: [Int: Int] = [
        9: 99,
        8: 199,
        7: 299,
        6: 499,
        5: 999,
        4: 1999,
        3: 99900,
    ]

    private var displayedQuote: QuoteResponse? {
        guard let q = quote, q.uin == Int(typed) else { return nil }
        return q
    }

    private var isAvailable: Bool { displayedQuote?.available ?? false }
    private var canBuy: Bool { isValidLength && isAvailable && !buying }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.Color.bgPrimary.ignoresSafeArea()

            VStack(spacing: 20) {
                Spacer().frame(height: 36)
                plateCard
                statusLine
                priceBlock
                Spacer(minLength: 8)
                footerHint
                Spacer().frame(height: 120)
            }
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            closeButton
                .padding(.leading, 12)
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack {
                Spacer()
                bottomCTA
                    .padding(.horizontal, 22)
                    .padding(.bottom, 18)
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
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
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

    // MARK: - Close

    private var closeButton: some View {
        Button(action: { dismiss() }) {
            Image(systemName: "chevron.down")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.Color.textSecondary)
                .frame(width: 40, height: 40)
                .background(Theme.Color.bgSecondary)
                .clipShape(Circle())
        }
    }

    // MARK: - Plate

    private var plateCard: some View {
        Button(action: { fieldFocused = true }) {
            VStack(spacing: 12) {
                Text(displayedNumber)
                    .font(.system(size: 56, weight: .heavy, design: .monospaced))
                    .foregroundColor(typedLength == 0 ? Theme.Color.textSecondary.opacity(0.32) : Theme.Color.textPrimary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .contentTransition(.numericText())
                    .animation(.spring(response: 0.32, dampingFraction: 0.78), value: typed)
                Text(plateCaption)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.Color.textSecondary)
                    .animation(.easeInOut(duration: 0.18), value: typedLength)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 36)
            .padding(.horizontal, 20)
            .background(Theme.Color.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(plateAccent, lineWidth: isAvailable ? 1.5 : 0)
                    .animation(.easeInOut(duration: 0.25), value: isAvailable)
            )
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var displayedNumber: String {
        typed.isEmpty ? "—" : typed
    }

    private var plateCaption: String {
        if typed.isEmpty { return "uin_shop.plate.hint".localized }
        return String(format: "uin_shop.plate.digits".localized, typedLength)
    }

    private var plateAccent: Color {
        isAvailable ? Theme.Color.accent : .clear
    }

    // MARK: - Status

    @ViewBuilder
    private var statusLine: some View {
        Group {
            if typed.isEmpty {
                Text("uin_shop.status.idle".localized)
                    .foregroundColor(Theme.Color.textSecondary)
            } else if !isValidLength {
                Text("uin_shop.hint.too_short".localized)
                    .foregroundColor(Theme.Color.textSecondary)
            } else if checking, displayedQuote == nil {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text("uin_shop.status.checking".localized)
                        .foregroundColor(Theme.Color.textSecondary)
                }
            } else if let q = displayedQuote {
                if q.available {
                    HStack(spacing: 6) {
                        Circle().fill(Theme.Color.accent).frame(width: 6, height: 6)
                        Text("uin_shop.status.available".localized)
                            .foregroundColor(Theme.Color.textPrimary)
                    }
                } else {
                    Text(reasonText(q.reason ?? "taken"))
                        .foregroundColor(.red.opacity(0.85))
                }
            } else {
                Text(" ").foregroundColor(.clear)
            }
        }
        .font(.system(size: 14, weight: .semibold))
        .frame(height: 18)
        .transition(.opacity)
    }

    // MARK: - Price

    @ViewBuilder
    private var priceBlock: some View {
        VStack(spacing: 6) {
            Text("uin_shop.price.label".localized)
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.8)
                .foregroundColor(Theme.Color.textSecondary.opacity(0.7))
            Text(priceDisplay(cents: priceToShow))
                .font(.system(size: 56, weight: .heavy, design: .rounded))
                .foregroundColor(priceColor)
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: false))
                .animation(.spring(response: 0.5, dampingFraction: 0.78), value: priceToShow)
                .animation(.easeInOut(duration: 0.25), value: priceColor)
        }
        .opacity(showPriceBlock ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: showPriceBlock)
        .onChange(of: isAvailable) { available in
            if available, let cents = displayedQuote?.priceCents {
                animateReveal(toCents: cents)
            }
        }
    }

    /// We show the price block as soon as the user has typed a valid
    /// length — but in *muted* form (textSecondary). Once /quote
    /// confirms availability, the colour pops to accent and the
    /// number does the count-up reveal. The hint to the user is:
    /// price depends on length, not on which UIN you pick.
    private var showPriceBlock: Bool {
        isValidLength
    }

    private var priceToShow: Int {
        if isAvailable {
            return revealedCents
        }
        return Self.priceCentsByLength[typedLength] ?? 0
    }

    private var priceColor: Color {
        isAvailable ? Theme.Color.accent : Theme.Color.textSecondary
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
        if cents % 100 == 0 {
            return String(format: "$%.0f", dollars)
        }
        return String(format: "$%.2f", dollars)
    }

    // MARK: - Footer hint

    private var footerHint: some View {
        VStack(spacing: 4) {
            Text("uin_shop.footer.line1".localized)
                .font(.caption2)
                .foregroundColor(Theme.Color.textSecondary)
            if let uin = ownUIN {
                Text(String(format: "uin_shop.footer.current".localized, String(uin)))
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(Theme.Color.textSecondary.opacity(0.6))
            }
        }
        .multilineTextAlignment(.center)
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
            .padding(.vertical, 17)
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
                    .padding(.vertical, 17)
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
                .padding(.vertical, 17)
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
            .opacity(configuration.isPressed ? 0.7 : 1)
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

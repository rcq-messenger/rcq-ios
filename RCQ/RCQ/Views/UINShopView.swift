import SwiftUI

/// UIN marketplace surface. The user types a 3-9 digit number, the
/// server confirms availability, the price flips from preview-grey to
/// accent-green, one tap on the bottom capsule starts the migration.
///
/// Below the input we keep a short explainer: what a UIN is and what
/// happens to the account when one is bought. The shop is the only
/// place in the app where a tester encounters the migration semantics
/// for the first time, so it has to explain itself.
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

    private var ownUIN: Int? { AuthService.shared.ownUIN }
    private var typedLength: Int { typed.count }
    private var isValidLength: Bool { (3...9).contains(typedLength) }

    /// Local mirror of `_PRICES_CENTS` on the backend. The /quote call
    /// is the authority for *availability*; the tier price depends
    /// only on length, so we preview it client-side without waiting
    /// for the network. No count-up animation — the value just lands
    /// instantly so it doesn't flicker mid-animation when the user
    /// types fast.
    private static let priceCentsByLength: [Int: Int] = [
        9: 99,
        8: 199,
        7: 499,
        6: 1499,
        5: 4999,
        4: 19900,
        3: 99900,
    ]

    private var displayedQuote: QuoteResponse? {
        guard let q = quote, q.uin == Int(typed) else { return nil }
        return q
    }

    private var isAvailable: Bool { displayedQuote?.available ?? false }
    private var canBuy: Bool { isValidLength && isAvailable && !buying }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Theme.Color.bgPrimary.ignoresSafeArea()

                // Tap-anywhere-blank-area to dismiss the keyboard.
                // Sits behind the content but in front of the bg colour
                // so taps on the plate / info / CTA still hit those
                // first (Button hit-test wins over this transparent
                // layer).
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { fieldFocused = false }
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        Spacer(minLength: 16)
                        plateCard
                        statusLine
                        priceLine
                        Spacer(minLength: 18)
                        infoBlock
                        Spacer(minLength: 24)
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, minHeight: scrollMinHeight)
                }
            }
            // System nav bar, matching the main screen (ContactListView):
            // inline title + visible toolbar material background. Replaces
            // the old free-floating chevron-down circle, which read as an
            // unfinished surface rather than a proper screen.
            .navigationTitle("uin_shop.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Theme.Color.textSecondary)
                    }
                    .accessibilityLabel("common.close".localized)
                }
            }
            // CTA pinned to the bottom safe area — reserves its own space
            // so the scroll content never hides behind it, no manual
            // bottom-padding guesswork.
            .safeAreaInset(edge: .bottom) {
                bottomCTA
                    .padding(.horizontal, 22)
                    .padding(.top, 8)
                    .padding(.bottom, 14)
                    .background(Theme.Color.bgPrimary)
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
    }

    /// Vertical breathing space — when the keyboard is dismissed we
    /// want the content centred-ish on screen, not glued to the top.
    /// `UIScreen.main.bounds` is fine here; we don't need precise
    /// safe-area math because the inner Spacers do the centring as
    /// long as the container is tall enough.
    private var scrollMinHeight: CGFloat {
        UIScreen.main.bounds.height - 120
    }

    // MARK: - Plate

    private var plateCard: some View {
        Button(action: { fieldFocused = true }) {
            VStack(spacing: 10) {
                Text(displayedNumber)
                    .font(.system(size: 48, weight: .semibold, design: .monospaced))
                    .foregroundColor(typedLength == 0 ? Theme.Color.textSecondary.opacity(0.32) : Theme.Color.textPrimary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .animation(.spring(response: 0.32, dampingFraction: 0.78), value: typed)
                Text(plateCaption)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(Theme.Color.textSecondary)
                    .animation(.easeInOut(duration: 0.18), value: typedLength)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
            .padding(.horizontal, 20)
            .background(Theme.Color.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
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
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text("uin_shop.status.checking".localized)
                        .foregroundColor(Theme.Color.textSecondary)
                }
            } else if let q = displayedQuote {
                if q.available {
                    Text("uin_shop.status.available".localized)
                        .foregroundColor(Theme.Color.accent)
                } else {
                    Text(reasonText(q.reason ?? "taken"))
                        .foregroundColor(.red.opacity(0.85))
                }
            } else {
                Text(" ").foregroundColor(.clear)
            }
        }
        .font(.system(size: 14, weight: .medium))
        .frame(height: 18)
    }

    // MARK: - Price

    @ViewBuilder
    private var priceLine: some View {
        if isValidLength, let cents = Self.priceCentsByLength[typedLength] {
            Text(priceDisplay(cents: cents))
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundColor(isAvailable ? Theme.Color.accent : Theme.Color.textPrimary)
                .monospacedDigit()
                .animation(.easeInOut(duration: 0.22), value: isAvailable)
        } else {
            Color.clear.frame(height: 48)
        }
    }

    private func priceDisplay(cents: Int) -> String {
        let dollars = Double(cents) / 100.0
        if cents % 100 == 0 {
            return String(format: "$%.0f", dollars)
        }
        return String(format: "$%.2f", dollars)
    }

    // MARK: - Info

    private var infoBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            infoRow(
                title: "uin_shop.info.what.title",
                body: "uin_shop.info.what.body"
            )
            infoRow(
                title: "uin_shop.info.migrate.title",
                body: "uin_shop.info.migrate.body"
            )
            if let uin = ownUIN {
                Text(String(format: "uin_shop.info.current".localized, String(uin)))
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(Theme.Color.textSecondary.opacity(0.7))
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func infoRow(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.localized)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.Color.textPrimary)
            Text(body.localized)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(Theme.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
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
            .transition(.opacity)
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
                withAnimation(.easeInOut(duration: 0.22)) {
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
            .opacity(configuration.isPressed ? 0.75 : 1)
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

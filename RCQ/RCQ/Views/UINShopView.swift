import SwiftUI

/// UIN marketplace surface. The user picks any 3-9 digit number; the
/// server quotes availability + price; a mock-IAP confirmation completes
/// the purchase by atomically migrating the account onto that UIN.
///
/// Pricing forms client-side from the digit count (mirror of the
/// server's `_PRICES_CENTS` table) so the live preview updates the
/// instant a digit is typed, without waiting for a /quote round-trip.
/// The /quote call is the authority for *availability*; the price tier
/// table is invariant and safe to inline.
struct UINShopView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var input: String = ""
    @State private var quote: Quote?
    @State private var checking = false
    @State private var buying = false
    @State private var error: String?
    @State private var showConfirm = false
    @State private var quoteTask: Task<Void, Never>?

    private let priceByLength: [Int: Int] = [
        9: 99,
        8: 199,
        7: 399,
        6: 799,
        5: 1499,
        4: 2999,
        3: 9999,
    ]

    private var ownUIN: Int? { AuthService.shared.ownUIN }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Image(systemName: "number.circle.fill")
                            .foregroundColor(Theme.Color.accent)
                        Text("uin_shop.current".localized)
                            .foregroundColor(Theme.Color.textPrimary)
                        Spacer()
                        Text(ownUIN.map(String.init) ?? "—")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(Theme.Color.textSecondary)
                    }
                }
                .listRowBackground(Theme.Color.bgSecondary)

                Section {
                    TextField("uin_shop.input.placeholder".localized, text: $input)
                        .keyboardType(.numberPad)
                        .font(.system(.title3, design: .monospaced))
                        .foregroundColor(Theme.Color.textPrimary)
                        .onChange(of: input) { newValue in
                            let filtered = String(newValue.filter(\.isNumber).prefix(9))
                            if filtered != newValue { input = filtered }
                            scheduleQuote()
                        }
                    quoteRow
                } header: {
                    Text("uin_shop.input.header".localized)
                } footer: {
                    Text("uin_shop.input.footer".localized)
                }
                .listRowBackground(Theme.Color.bgSecondary)

                Section {
                    buyButton
                    if let error {
                        Text(error)
                            .font(.caption2)
                            .foregroundColor(.red)
                    }
                }
                .listRowBackground(Theme.Color.bgSecondary)

                Section {
                    ForEach(Array(priceByLength.keys.sorted(by: >)), id: \.self) { len in
                        HStack {
                            Text(String(format: "uin_shop.tier.digits".localized, len))
                                .foregroundColor(Theme.Color.textPrimary)
                            Spacer()
                            Text(priceDisplay(cents: priceByLength[len] ?? 0))
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(Theme.Color.textSecondary)
                        }
                    }
                } header: {
                    Text("uin_shop.tiers.header".localized)
                } footer: {
                    Text("uin_shop.tiers.footer".localized)
                }
                .listRowBackground(Theme.Color.bgSecondary)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Color.bgPrimary.ignoresSafeArea())
            .navigationTitle("uin_shop.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".localized) { dismiss() }
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
                Button("common.cancel".localized, role: .cancel) { }
            } message: {
                Text("uin_shop.confirm.body".localized)
            }
        }
    }

    // MARK: - Quote row

    @ViewBuilder
    private var quoteRow: some View {
        if input.isEmpty {
            EmptyView()
        } else if let parsed = Int(input), let len = lengthOf(input) {
            if let q = quote, q.uin == parsed {
                HStack {
                    Image(systemName: q.available ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(q.available ? .green : Theme.Color.textSecondary)
                    Text(q.available
                         ? "uin_shop.status.available".localized
                         : reasonText(q.reason ?? "taken"))
                        .foregroundColor(Theme.Color.textPrimary)
                    Spacer()
                    Text(priceDisplay(cents: priceByLength[len] ?? 0))
                        .font(.system(.callout, design: .monospaced).bold())
                        .foregroundColor(q.available ? Theme.Color.accent : Theme.Color.textSecondary)
                }
            } else if checking {
                HStack {
                    ProgressView().scaleEffect(0.75)
                    Text("uin_shop.status.checking".localized)
                        .foregroundColor(Theme.Color.textSecondary)
                    Spacer()
                    Text(priceDisplay(cents: priceByLength[len] ?? 0))
                        .font(.system(.callout, design: .monospaced).bold())
                        .foregroundColor(Theme.Color.textSecondary)
                }
            } else {
                HStack {
                    Image(systemName: "ellipsis.circle")
                        .foregroundColor(Theme.Color.textSecondary)
                    Text(localizedLengthHint(len))
                        .foregroundColor(Theme.Color.textSecondary)
                    Spacer()
                    Text(priceDisplay(cents: priceByLength[len] ?? 0))
                        .font(.system(.callout, design: .monospaced))
                        .foregroundColor(Theme.Color.textSecondary)
                }
            }
        }
    }

    // MARK: - Buy button

    @ViewBuilder
    private var buyButton: some View {
        Button {
            showConfirm = true
        } label: {
            HStack {
                Image(systemName: "creditcard.fill")
                    .foregroundColor(.white)
                Text(buyButtonLabel)
                    .foregroundColor(.white)
                Spacer()
                if buying {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        .buttonStyle(.borderedProminent)
        .tint(Theme.Color.accent)
        .disabled(!canBuy || buying)
    }

    private var canBuy: Bool {
        guard let q = quote, q.available else { return false }
        guard let len = lengthOf(input), priceByLength[len] != nil else { return false }
        return true
    }

    private var buyButtonLabel: String {
        guard let q = quote, q.available else {
            return "uin_shop.buy.placeholder".localized
        }
        return String(format: "uin_shop.buy.cta".localized, priceDisplay(cents: q.priceCents ?? 0))
    }

    private var confirmTitle: String {
        guard let q = quote, q.available, let cents = q.priceCents else {
            return "uin_shop.confirm.title".localized
        }
        return String(format: "uin_shop.confirm.title_priced".localized, String(q.uin), priceDisplay(cents: cents))
    }

    private var confirmCTA: String {
        guard let q = quote, q.available, let cents = q.priceCents else {
            return "uin_shop.confirm.cta".localized
        }
        return String(format: "uin_shop.confirm.cta_priced".localized, priceDisplay(cents: cents))
    }

    // MARK: - Quote orchestration

    private func scheduleQuote() {
        quote = nil
        error = nil
        quoteTask?.cancel()
        guard let parsed = Int(input), parsed > 0, let _ = lengthOf(input) else {
            return
        }
        quoteTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 280_000_000)
            if Task.isCancelled { return }
            await fetchQuote(parsed)
        }
    }

    private func fetchQuote(_ uin: Int) async {
        checking = true
        defer { checking = false }
        struct Body: Encodable { let uin: Int }
        do {
            let resp: Quote = try await APIClient.shared.request(
                "POST", "/uin/quote",
                body: Body(uin: uin)
            )
            if !Task.isCancelled, Int(input) == uin {
                quote = resp
            }
        } catch {
            // Soft-fail: the user will retry by typing. The price tier
            // table is still visible so the screen never goes empty.
            self.error = nil
        }
    }

    private func runPurchase() async {
        guard let parsed = Int(input) else { return }
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

    // MARK: - Helpers

    private func lengthOf(_ s: String) -> Int? {
        let n = s.count
        guard (3...9).contains(n) else { return nil }
        return n
    }

    private func priceDisplay(cents: Int) -> String {
        let dollars = Double(cents) / 100.0
        return String(format: "$%.2f", dollars)
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

    private func localizedLengthHint(_ len: Int) -> String {
        switch len {
        case 0..<3: return "uin_shop.hint.too_short".localized
        default: return "uin_shop.hint.tap_to_check".localized
        }
    }
}

private struct Quote: Decodable {
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

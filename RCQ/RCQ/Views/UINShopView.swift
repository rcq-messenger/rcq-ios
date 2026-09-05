import SwiftUI

/// UIN marketplace surface. The user types a 3-9 digit number, the
/// server confirms availability, the price flips from preview-grey to
/// accent-green, one tap on the bottom capsule takes it.
///
/// Taking it no longer makes you it. The number lands in the account's
/// collection (POST /uin/purchase with switch=false) and answering as
/// it is a second, deliberate step — offered right here for whoever
/// wants it now, and on My numbers for everyone else. Buying and
/// changing the identity everybody knows you by used to be the same
/// tap, which is a bad thing to have one button away from browsing.
///
/// Below the input we keep a short explainer: what a UIN is and what
/// taking one does. The shop is the only place in the app where a
/// tester meets these semantics for the first time, so it has to
/// explain itself.
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
    /// Set once the number is in the collection: the "it is yours, move onto
    /// it now or later?" step.
    @State private var held: Int?
    @State private var showMyUINs = false
    /// Read once for the collection cap and how much of it is used. The server
    /// refuses the eleventh number with 409 `too_many_uins`, and finding that
    /// out at the refusal is finding it out too late.
    @State private var collection: AppState.MyUINs?

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

    /// What people are selling right now. Shown, not sold: the buying happens
    /// on the web or the desktop, where the till can take crypto.
    @State private var listings: [AppState.UINListing] = []
    @State private var loadingListings = false

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
                    VStack(spacing: 16) {
                        // Status + price sit ABOVE the input plate as a
                        // compact header; the explainer sits right below
                        // the plate. Content is top-aligned under the nav
                        // bar (no centring Spacers) so the page hugs the
                        // header instead of floating mid-screen.
                        statusLine
                        priceLine
                        plateCard
                        fromPeopleSection
                        // The collection is a screen away, and this is where
                        // somebody who just took a number goes looking for it.
                        Button("my_uins.title".localized) { showMyUINs = true }
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(Theme.Color.accent)
                            .padding(.vertical, 2)
                        infoBlock
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 16)
                    .frame(maxWidth: .infinity)
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
                    // Clear tint kills the blinking caret. The visible
                    // input is the plate Button; this field is an
                    // off-display capture target, so its cursor was
                    // showing up as a stray square pinned to the top of
                    // the keyboard when focused.
                    .tint(.clear)
                    .opacity(0)
                    .frame(width: 1, height: 1)
                    .onChange(of: typed) { newValue in
                        var filtered = String(newValue.filter(\.isNumber).prefix(9))
                        // Leading zeros are meaningless for a UIN — it's
                        // an integer. "001" IS the 1-digit UIN 1 (the
                        // server quotes it as 1 → "too short"), and "000"
                        // is 0, which Int("000") parses to 0 and the
                        // quote guard (`parsed > 0`) silently drops, so
                        // nothing shows. Stripping leading zeros makes the
                        // plate show the real number the server will quote
                        // and removes both confusions.
                        filtered = String(filtered.drop(while: { $0 == "0" }))
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
            // It is yours — the offer to move onto it now. "Later" leaves the
            // account exactly as it was and the number safely held.
            .confirmationDialog(
                held.map { String(format: "uin_shop.held.title".localized, String($0)) } ?? "",
                isPresented: Binding(
                    get: { held != nil },
                    set: { if !$0 { held = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("uin_shop.held.now".localized) {
                    if let target = held {
                        held = nil
                        Task { await moveOnto(target) }
                    }
                }
                Button("uin_shop.held.later".localized, role: .cancel) {
                    held = nil
                    typed = ""
                }
            } message: {
                Text(String(format: "uin_shop.held.body".localized, String(ownUIN ?? 0)))
            }
            .sheet(isPresented: $showMyUINs) { MyUINsView() }
            // Re-read on the way back from My numbers: a release there changes
            // the count this screen prints.
            .onChange(of: showMyUINs) { open in
                if !open { Task { collection = await AppState.shared.myUINs() } }
            }
            .task {
                collection = await AppState.shared.myUINs()
                listings = await AppState.shared.uinListings()
            }
        }
    }

    // MARK: - From people

    /// Numbers people are selling to each other. iOS shows them and stops
    /// there: the checkout is crypto and lives outside the app, so tapping a
    /// row fills the field and the screen says where the purchase happens.
    @ViewBuilder
    private var fromPeopleSection: some View {
        if !listings.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("uin_shop.people.title".localized)
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.6)
                        .foregroundColor(Theme.Color.textSecondary)
                    Spacer()
                    Button {
                        guard !loadingListings else { return }
                        loadingListings = true
                        Task {
                            listings = await AppState.shared.uinListings()
                            loadingListings = false
                        }
                    } label: {
                        if loadingListings {
                            ProgressView().scaleEffect(0.6)
                        } else {
                            Text("uin_shop.people.more".localized)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(Theme.Color.accent)
                        }
                    }
                    .buttonStyle(.plain)
                }
                VStack(spacing: 6) {
                    ForEach(listings) { listing in
                        Button {
                            // Filling the field is the whole interaction: the
                            // onChange behind it asks the island and the lines
                            // above say who is selling and for how much.
                            typed = String(listing.uin)
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(String(listing.uin))
                                        .font(.system(size: 17, weight: .medium))
                                        .foregroundColor(Theme.Color.textPrimary)
                                    Text(String(format: "uin_shop.resale.seller".localized, String(listing.sellerUin)))
                                        .font(.system(size: 11))
                                        .foregroundColor(Theme.Color.textSecondary)
                                }
                                Spacer()
                                // A listing somebody is paying for says so
                                // rather than vanishing: a row that disappears
                                // reads as "the number is gone", and it is not.
                                Text(listing.held ? "uin_shop.being_paid".localized : listing.priceDisplay)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(listing.held ? Theme.Color.textSecondary : Theme.Color.accent)
                            }
                            .padding(.vertical, 13)
                            .padding(.horizontal, 16)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Theme.Color.bgSecondary)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(listing.held)
                    }
                }
                Text("uin_shop.people.elsewhere".localized)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
                if q.acquire == "resale", let seller = q.sellerUin {
                    // Not a refusal. Somebody is selling this number, and iOS
                    // cannot take the payment (the checkout is crypto, which
                    // an App Store build may not carry), so the screen says
                    // whose it is and where the till is.
                    Text(String(format: "uin_shop.resale.seller".localized, String(seller)))
                        .foregroundColor(Theme.Color.accent)
                } else if q.available {
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
        // ⚠⚠ THE SELLER NAMES THE PRICE. `priceCentsByLength` is this island's
        // ladder by length and has nothing to do with what a person is asking
        // for their own number: printing it over a resale quoted "$49.99" for
        // a number somebody wants $300 for.
        if let q = displayedQuote, q.acquire == "resale", let shown = q.priceDisplay {
            Text(shown)
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundColor(Theme.Color.accent)
                .monospacedDigit()
        } else if isValidLength, let cents = Self.priceCentsByLength[typedLength] {
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
            // The cap and the one irreversible thing in the whole flow. Both
            // are server rules the app used to keep to itself: the cap only
            // showed up as a refusal on the eleventh number, and nothing
            // anywhere said that giving a number back is final.
            infoRow(
                title: "uin_shop.info.cap.title".localized,
                bodyText: String(
                    format: "uin_shop.info.cap.body".localized,
                    collection?.maxOwned ?? 10,
                    (collection?.owned ?? []).count
                )
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
        infoRow(title: title.localized, bodyText: body.localized)
    }

    /// Same row for copy that is already formatted (a count folded into the
    /// sentence), so the caller localises and the row only lays out.
    private func infoRow(title: String, bodyText: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.Color.textPrimary)
            Text(bodyText)
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

    /// Take the number into the collection. It does NOT change who the
    /// account answers as — that is `moveOnto`, offered right after.
    private func runPurchase() async {
        guard let parsed = Int(typed) else { return }
        buying = true
        defer { buying = false }
        let result = await AppState.shared.holdUIN(parsed)
        switch result {
        case .success:
            held = parsed
            collection = await AppState.shared.myUINs()
        case .taken:
            error = "uin_shop.error.taken".localized
            quote = nil
        case .cooldown:
            error = "uin_shop.error.cooldown".localized
        case .other(let msg):
            // The cap and a suspended account both arrive here as a JSON
            // body; uinRefusalText turns them into sentences and leaves a
            // transport failure's own wording alone.
            error = AppState.uinRefusalText(msg)
        }
    }

    /// Answer as a number just taken. This IS a migration: AppState swaps the
    /// keychain uin+token and re-boots, so the shop closes behind it.
    private func moveOnto(_ target: Int) async {
        buying = true
        defer { buying = false }
        switch await AppState.shared.activateUIN(target) {
        case .success:
            dismiss()
        case .cooldown:
            error = "uin_shop.error.cooldown".localized
        case .taken:
            error = "uin_shop.error.taken".localized
        case .other(let msg):
            error = AppState.uinRefusalText(msg)
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
    /// How this number can be had: "free", "purchase", "resale" or "closed".
    ///
    /// ⚠⚠ THE ONLY WAY TO RECOGNISE A RESALE. The island deliberately answers
    /// `available: false` for one (a client too old to know the word would
    /// otherwise draw "take it" over somebody else's property and walk into a
    /// 403), so on availability alone a number a person is selling is
    /// indistinguishable from one that is simply taken.
    let acquire: String?
    /// Who is selling it, when somebody is.
    let sellerUin: Int?

    enum CodingKeys: String, CodingKey {
        case uin, length, available, reason, acquire
        case priceCents = "price_cents"
        case priceDisplay = "price_display"
        case sellerUin = "seller_uin"
    }
}

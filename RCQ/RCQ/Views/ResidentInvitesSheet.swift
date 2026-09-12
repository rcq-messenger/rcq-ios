import SwiftUI
import UIKit

/// What the island answers about the invites a RESIDENT may hand out.
///
/// ⚠ The island does the arithmetic and this struct only carries it. Granted,
/// used, remaining and the date of the next one are all computed on read from
/// `resident_since` (`backend/app/routers/invites.py`), so a client that did
/// its own sum would disagree with the island the moment an operator changed
/// the accrual period. Nothing here recomputes anything.
struct ResidentInvites: Decodable {
    /// False when the island has the feature switched off entirely.
    let enabled: Bool
    /// False for everybody who did not pay. `resident_since` is set by exactly
    /// one path — redeeming a paid entry voucher at registration — so an
    /// invite, however generous, never makes anybody eligible.
    let eligible: Bool
    let total: Int
    let granted: Int
    let used: Int
    let remaining: Int
    /// When the next one accrues; nil when they already hold the lot.
    let nextAt: Date?
    /// Where the allowance comes from: `resident` for somebody who paid,
    /// `free` for an account that was here before residency existed and gets
    /// a smaller drip (founder item 5, 12.09). Empty from an island older
    /// than the field. The counter draws the same either way; the only thing
    /// keyed on it is one line of copy under the count.
    let kind: String

    /// Draw nothing at all unless all three hold. ⚠ The third is not
    /// decoration: a counter reading 0/0 on the screen of somebody who never
    /// paid asks a question ("why have I none") that a Settings row is the
    /// wrong place to answer, and it reads as something taken away. The web
    /// component makes exactly the same call.
    var isVisible: Bool { enabled && eligible && total > 0 }

    private enum CodingKeys: String, CodingKey {
        case enabled, eligible, total, granted, used, remaining, kind
        case nextAt = "next_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        eligible = try c.decodeIfPresent(Bool.self, forKey: .eligible) ?? false
        total = try c.decodeIfPresent(Int.self, forKey: .total) ?? 0
        granted = try c.decodeIfPresent(Int.self, forKey: .granted) ?? 0
        used = try c.decodeIfPresent(Int.self, forKey: .used) ?? 0
        remaining = try c.decodeIfPresent(Int.self, forKey: .remaining) ?? 0
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        // ⚠ Read as text and parsed here rather than trusting a decoding
        // strategy: the flagship stamps an offset and an island on SQLite can
        // send a naive stamp, and a date this screen only uses for one line of
        // copy must never fail the whole decode. Same reasoning, same shapes,
        // as `MyReportsView.instant`.
        nextAt = Self.instant(try c.decodeIfPresent(String.self, forKey: .nextAt))
    }

    /// Internal, not private: the residency row in Settings reads
    /// `resident_since` off the profile with the same tolerance.
    static func instant(_ iso: String?) -> Date? {
        guard let iso, !iso.isEmpty else { return nil }
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = withFrac.date(from: iso) ?? plain.date(from: iso) { return date }
        let naive = DateFormatter()
        naive.locale = Locale(identifier: "en_US_POSIX")
        naive.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss"] {
            naive.dateFormat = format
            if let date = naive.date(from: iso) { return date }
        }
        return nil
    }
}

/// One freshly minted invite. ⚠ The raw code comes back ONCE: the island keeps
/// only its sha256, so a caller that drops this response has spent one of a
/// finite allowance on nothing.
struct MintedInvite: Decodable {
    let code: String
    let link: String
}

/// ⚠ Main-actor isolated because `mine()` consults `PanicPINService`, which is,
/// and a duress check that could be skipped by calling from another thread is
/// not a check.
@MainActor
enum ResidentInvitesAPI {
    /// Nil on any refusal, including the 404 an island older than the feature
    /// answers with. A miss draws nothing, which is the same as not being
    /// eligible, and that is the right outcome for both.
    static func mine() async -> ResidentInvites? {
        // A decoy session has no server account; the DuressGate refuses the
        // request anyway, and asking would put a real-island call on a screen
        // that is supposed to look ordinary.
        guard !PanicPINService.shared.isDecoy else { return nil }
        let out: ResidentInvites? = try? await APIClient.shared.request("GET", "/invites")
        return out
    }

    static func mint() async throws -> MintedInvite {
        let out: MintedInvite = try await APIClient.shared.request("POST", "/invites")
        return out
    }

    /// Spend an entry voucher on the account that is already here (founder
    /// item 5, 12.09). Until then the voucher was accepted by registration
    /// alone, so somebody here for free had no way in short of a second
    /// account. The voucher is bound to the host, not to an account, which is
    /// what makes this one round trip.
    ///
    /// Refusals are `APIError.http` with a code in the body: `already_resident`
    /// and `voucher_spent` (409), `suspended`, `voucher_other_island`,
    /// `voucher_expired`, `bad_signature` (403), `sales_disabled` (404).
    static func redeemResidency(voucher: String) async throws -> ResidencyRedeemed {
        struct Body: Encodable { let voucher: String }
        let out: ResidencyRedeemed = try await APIClient.shared.request(
            "POST", "/residency/redeem", body: Body(voucher: voucher)
        )
        return out
    }
}

/// What the island answers once the voucher is spent on this account. The
/// mark is granted server-side; `invites` is the same shape `GET /invites`
/// returns, so the counter redraws off this without a second call.
struct ResidencyRedeemed: Decodable {
    let residentSince: String?
    let badge: String?
    let badgesEarned: [String]?
    let invites: ResidentInvites?

    private enum CodingKeys: String, CodingKey {
        case badge, invites
        case residentSince = "resident_since"
        case badgesEarned = "badges_earned"
    }
}

/// The invites a paying resident may hand out, on this island.
///
/// The web draws the same three things (`web-chat/src/components/
/// ResidentInvites.tsx`): how many are left of how many, when the next one
/// lands, and a one-time link with a copy button. iOS had none of it, which is
/// what the founder went looking for and did not find (06.09, point 7).
struct ResidentInvitesSheet: View {
    /// What Settings already read, so the sheet opens on numbers instead of a
    /// spinner. Refreshed here anyway.
    let initial: ResidentInvites?
    /// Called when the count changes, so the row that opened this can redraw.
    var onChanged: (ResidentInvites) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var state: ResidentInvites?
    @State private var minted: String?
    @State private var busy = false
    @State private var copied = false
    @State private var error: String?

    init(initial: ResidentInvites?, onChanged: @escaping (ResidentInvites) -> Void = { _ in }) {
        self.initial = initial
        self.onChanged = onChanged
        _state = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let state, state.isVisible {
                            counterCard(state)
                            Text("invites.body".localized)
                                .font(.footnote)
                                .foregroundColor(Theme.Color.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if state.remaining > 0 { mintButton }
                            if let minted { mintedBlock(minted) }
                            if let error {
                                Text(error)
                                    .font(.caption)
                                    .foregroundColor(.red.opacity(0.85))
                            }
                        } else {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("invites.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".localized) { dismiss() }
                }
            }
            .task { await refresh() }
        }
    }

    // MARK: - sections

    private func counterCard(_ state: ResidentInvites) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "envelope.open.fill")
                .font(.system(size: 18))
                .foregroundColor(Theme.Color.accent)
                .frame(width: 40, height: 40)
                .background(Theme.Color.accent.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 1) {
                Text("\(state.remaining)/\(state.total)")
                    .font(.system(.title2, weight: .bold).monospacedDigit())
                    .foregroundColor(Theme.Color.textPrimary)
                Text(nextLine(state))
                    .font(.caption)
                    .foregroundColor(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Color.bgSecondary)
        .cornerRadius(10)
    }

    private var mintButton: some View {
        Button {
            Task { await mint() }
        } label: {
            Group {
                if busy { ProgressView().tint(.white) }
                else { Text("invites.mint".localized).fontWeight(.semibold) }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Capsule().fill(Theme.Color.accent))
            .foregroundColor(.white)
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    /// ⚠ Shown ONCE, and the copy button is the point of this block rather
    /// than decoration: the island keeps only the hash, so somebody who closes
    /// this without copying has spent an invite on nothing.
    private func mintedBlock(_ link: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(link)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(Theme.Color.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Theme.Color.bgSecondary)
                .cornerRadius(8)
            Button {
                UIPasteboard.general.string = link
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                copied = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    Text((copied ? "invites.copied" : "invites.copy").localized)
                }
                .font(.callout.weight(.medium))
                .foregroundColor(Theme.Color.accent)
            }
            .buttonStyle(.plain)
            Text("invites.once".localized)
                .font(.caption)
                .foregroundColor(Theme.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The device's own date format, the way the web uses `toLocaleDateString`:
    /// this is a calendar date a person reads, not a stamp anything sorts on.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private func nextLine(_ state: ResidentInvites) -> String {
        let next: String
        if let at = state.nextAt {
            next = String(format: "invites.next".localized, Self.dayFormatter.string(from: at))
        } else {
            next = "invites.all".localized
        }
        // An account that was here before residency existed gets a smaller
        // drip (founder item 5, 12.09). The counter is the same; this one
        // line is what says why it is there.
        guard state.kind == "free" else { return next }
        return next + "\n" + "invites.free".localized
    }

    // MARK: - actions

    private func refresh() async {
        guard let fresh = await ResidentInvitesAPI.mine() else { return }
        state = fresh
        onChanged(fresh)
    }

    private func mint() async {
        busy = true
        error = nil
        copied = false
        do {
            minted = try await ResidentInvitesAPI.mint().link
        } catch {
            // The island already refused for a stated reason (none left, the
            // account is suspended); the button re-enables and the person can
            // read the count above, which the refresh below corrects.
            self.error = "invites.error".localized
        }
        busy = false
        await refresh()
    }
}

/// Buying residency on an account that already exists (founder item 5,
/// 12.09): one field, the code from the till, and the island does the rest.
///
/// ⚠⚠ NO LINK, AND A PRICE ONLY ON THE FLAGSHIP. The rule is
/// `AddAccountSheet.label(for:)`: an app that names the price of something it
/// sells is fine, one that points at a checkout Apple does not handle is not,
/// and entry to somebody else's island is bought on their site. This is the
/// sheet that will later take a StoreKit receipt instead of a pasted code; the
/// shape is deliberately the same either way, so nothing moves on that day.
struct ResidencySheet: View {
    let host: String
    let priceCents: Int
    /// Called with the island's answer. The row that opened this takes the
    /// counter straight off it and re-reads the profile for the mark.
    var onRedeemed: (ResidencyRedeemed) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?

    private var trimmedCode: String { code.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var priceLine: String? {
        guard RcqFederation.isFlagship(host), priceCents > 0 else { return nil }
        // Whole dollars lose the ".00", as in AddAccountSheet.usd.
        let usd = priceCents % 100 == 0 ? "$\(priceCents / 100)" : String(format: "$%.2f", Double(priceCents) / 100)
        return String(format: "island.entry.price".localized, usd)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let priceLine {
                            Text(priceLine)
                                .font(.title3.weight(.semibold))
                                .foregroundColor(Theme.Color.textPrimary)
                        }
                        Text("residency.body".localized)
                            .font(.footnote)
                            .foregroundColor(Theme.Color.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("residency.have_code".localized)
                            .font(.callout.weight(.medium))
                            .foregroundColor(Theme.Color.textPrimary)
                            .padding(.top, 4)
                        // The same field the join sheet draws for the same
                        // credential. The voucher is a signed blob, not a
                        // word, hence monospaced and no autocorrect.
                        TextField("reg.invite.label".localized, text: $code)
                            .autocorrectionDisabled(true)
                            .textInputAutocapitalization(.never)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundColor(Theme.Color.textPrimary)
                            .padding(12)
                            .background(Theme.Color.bgSecondary)
                            .cornerRadius(10)
                        if let error {
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red.opacity(0.85))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        redeemButton
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("residency.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".localized) { dismiss() }
                }
            }
        }
    }

    private var redeemButton: some View {
        Button {
            Task { await redeem() }
        } label: {
            Group {
                if busy { ProgressView().tint(.white) }
                else { Text("residency.redeem".localized).fontWeight(.semibold) }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Capsule().fill(Theme.Color.accent))
            .foregroundColor(.white)
        }
        .buttonStyle(.plain)
        .disabled(busy || trimmedCode.isEmpty)
        .opacity(trimmedCode.isEmpty ? 0.5 : 1)
    }

    private func redeem() async {
        busy = true
        error = nil
        do {
            let out = try await ResidentInvitesAPI.redeemResidency(voucher: trimmedCode)
            busy = false
            onRedeemed(out)
            dismiss()
        } catch {
            busy = false
            self.error = Self.sentence(for: error)
        }
    }

    /// The island's code, as the sentence for it. Matched by substring the way
    /// `ServerJoinSheet` reads a refused registration: the body is
    /// `{"detail": {"code": ...}}`, and the code is the only part worth reading.
    private static func sentence(for error: Error) -> String {
        guard let api = error as? APIError,
              case .http(let status, let body) = api,
              (400..<500).contains(status) else {
            return "residency.error".localized
        }
        let raw = body ?? ""
        // Refused BEFORE the voucher is touched, so the code is still good;
        // the row that opened this re-reads the profile on dismiss.
        if raw.contains("already_resident") { return "residency.already".localized }
        if raw.contains("voucher_spent") { return "residency.code_spent".localized }
        if raw.contains("sales_disabled") { return "residency.not_sold".localized }
        if raw.contains("suspended") { return "residency.error".localized }
        // Every VoucherError the island names, and any it adds later: wrong
        // island, expired, a signature that does not check out.
        return "reg.invite.invalid".localized
    }
}

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

    /// Draw nothing at all unless all three hold. ⚠ The third is not
    /// decoration: a counter reading 0/0 on the screen of somebody who never
    /// paid asks a question ("why have I none") that a Settings row is the
    /// wrong place to answer, and it reads as something taken away. The web
    /// component makes exactly the same call.
    var isVisible: Bool { enabled && eligible && total > 0 }

    private enum CodingKeys: String, CodingKey {
        case enabled, eligible, total, granted, used, remaining
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
        // ⚠ Read as text and parsed here rather than trusting a decoding
        // strategy: the flagship stamps an offset and an island on SQLite can
        // send a naive stamp, and a date this screen only uses for one line of
        // copy must never fail the whole decode. Same reasoning, same shapes,
        // as `MyReportsView.instant`.
        nextAt = Self.instant(try c.decodeIfPresent(String.self, forKey: .nextAt))
    }

    private static func instant(_ iso: String?) -> Date? {
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
        guard let next = state.nextAt else { return "invites.all".localized }
        return String(format: "invites.next".localized, Self.dayFormatter.string(from: next))
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

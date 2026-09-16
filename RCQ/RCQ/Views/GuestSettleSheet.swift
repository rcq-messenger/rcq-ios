import SwiftUI

/// Becoming a resident of the island a copy is a guest on (spec 2026-09-15,
/// 9.1; decision D7).
///
/// The same row, the same number, the same rooms: a settle rewrites what the
/// island calls the row and nothing else, which is why there is no sign-in, no
/// second account and no migration anywhere in here.
///
/// ⚠⚠ NO PRICE AND NO LINK on iOS (spec 12.1, Apple; the rule is written out in
/// `AddAccountSheet.label(for:)`). A code may be typed in. Entry itself is sold
/// on the island's own site, and this sheet must never point at a checkout.
struct GuestSettleSheet: View {
    /// Which copy is settling: the app's own session, or the copy we hold on
    /// the island a room lives on.
    enum Target: Equatable {
        case primary
        case visited(host: String)

        var host: String {
            switch self {
            case .primary: return Multihome.ownHost()
            case .visited(let h): return h
            }
        }
    }

    let target: Target
    /// Runs once the island has converted the row, before the sheet closes.
    var onSettled: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?
    @State private var done = false

    private var host: String { target.host }
    private var trimmedCode: String { code.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(String(format: "guest.copy.banner".localized, host))
                            .font(.callout)
                            .foregroundColor(Theme.Color.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("residency.body".localized)
                            .font(.footnote)
                            .foregroundColor(Theme.Color.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("residency.have_code".localized)
                            .font(.callout.weight(.medium))
                            .foregroundColor(Theme.Color.textPrimary)
                            .padding(.top, 4)
                        // The same field the join sheet and the residency sheet
                        // draw for the same credential: a voucher is a signed
                        // blob and an invite is a code, neither is a word.
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
                                .foregroundColor(Theme.Color.statusBusy)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if done {
                            Text(String(format: "guest.settle.done".localized, host))
                                .font(.callout)
                                .foregroundColor(Theme.Color.accent)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        settleButton
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle(String(format: "guest.settle.action".localized, host))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".localized) { dismiss() }
                }
            }
        }
    }

    /// ⚠ Enabled with an empty field on purpose: an island whose door is open
    /// settles for nothing (spec 9.1, step 3), and a button greyed out until a
    /// code is typed would hide that from everybody it applies to.
    private var settleButton: some View {
        Button {
            Task { await settle() }
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
        .disabled(busy || done)
        .opacity(done ? 0.5 : 1)
    }

    private func settle() async {
        busy = true
        error = nil
        do {
            switch target {
            case .primary:
                try await GuestSession.shared.settle(code: trimmedCode.isEmpty ? nil : trimmedCode)
            case .visited(let h):
                try await CrossIslandGroups.settleGuest(host: h, code: trimmedCode.isEmpty ? nil : trimmedCode)
                await GroupService.shared.refresh()
            }
            busy = false
            finish()
        } catch {
            // ⚠ `not_a_guest` is a settle that already happened, not a failure
            // (decision E2, 16.09): the row lives on that island already,
            // because another device settled it or the operator did. Android
            // and the web both run their success path for it. This used to
            // paint it red, leave the local guest flag set and never call
            // `onSettled`, so every guest surface stayed wrong until something
            // else re-read the island.
            if let refusal = Self.refusal(for: error), GuestSentence.settleAlreadyDone(refusal) {
                await settledElsewhere()
                busy = false
                finish()
                return
            }
            busy = false
            self.error = Self.sentence(for: error, host: host)
        }
    }

    /// The end of a settle, whichever answer got us here: the sheet says so and
    /// closes, and whoever opened it re-reads what the island now allows.
    private func finish() {
        done = true
        onSettled()
        dismiss()
    }

    /// The local half of a settle whose network half is already done: the flag
    /// this client keeps, and a re-read of the island's own surfaces. The same
    /// two writes the success path makes, because the outcome is the same one.
    private func settledElsewhere() async {
        switch target {
        case .primary:
            GuestSession.shared.clear()
            await AppState.shared.refreshServerInfo()
            await GroupService.shared.refresh()
        case .visited(let h):
            VisitedIslandsStore.shared.markSettled(host: h)
            await GroupService.shared.refresh()
        }
    }

    /// The island's own answer, or nil when nothing was refused: offline, a
    /// burn, or a transport error that never reached a door.
    private static func refusal(for error: Error) -> IslandRefusal? {
        switch error {
        case let api as APIError:
            guard case .http(let status, let body) = api else { return nil }
            return IslandRefusal.parse(status: status, body: Data((body ?? "").utf8))
        case CrossIslandGroups.CIGError.refused(let status, let code):
            return IslandRefusal(status: status, code: code)
        default:
            return nil
        }
    }

    /// The island's code as the spec's sentence (12.5 plus the door sentences
    /// this client already has), never the island's own text.
    ///
    /// ⚠ Nil is NOTHING AT ALL, not the generic line (F2, 16.09). A retired key
    /// has already opened the account's rotated-elsewhere notice by the time we
    /// are asked: the settle's own re-mint raises it (`refreshGuestOutcome`),
    /// and so does an island that answers the code outright. A sentence beside
    /// that notice tells one refusal twice, and "residency.error" beside it is
    /// worse than that, because it reads as something a retry could fix. The
    /// join sheet stops at the same place (`CrossIslandGroups.joinSentence`),
    /// Android returns null there and the web sets no error at all.
    private static func sentence(for error: Error, host: String) -> String? {
        // Both spellings a retired key arrives in: the typed case the settle
        // throws once its re-mint hit the rotation, and the island's own code.
        if let cig = error as? CrossIslandGroups.CIGError, CrossIslandGroups.isRotated(cig) { return nil }
        guard let refusal = refusal(for: error) else { return GuestSentence.settleGeneric.localized }
        if GuestSentence.noticeOnly(refusal) { return nil }
        let key = GuestSentence.settle(refusal) ?? GuestSentence.settleGeneric
        return String(format: key.localized, host)
    }
}

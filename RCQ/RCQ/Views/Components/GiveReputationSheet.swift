import SwiftUI

/// "Give reputation" sheet — burns N jettons (min 5) from the donor
/// to bump the target's `reputation` counter by N. The jettons are
/// burned outright on the server (full sink), so this is a
/// donation, not a transfer.
struct GiveReputationSheet: View {
    let targetUIN: Int
    let targetNickname: String
    /// Called with the server's authoritative new total so the
    /// presenter can splice the value into its on-screen profile
    /// without a refetch.
    let onSuccess: (_ newTotal: Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var items = ItemsService.shared

    @State private var amountText: String = "10"
    @State private var anonymous: Bool = false
    @State private var sending: Bool = false
    @State private var errorMessage: String?

    private var amount: Int { Int(amountText) ?? 0 }
    private var canSend: Bool {
        amount >= GiveReputationSheet.minAmount &&
        amount <= GiveReputationSheet.maxAmount &&
        amount <= items.wallet.tokens &&
        !sending
    }

    static let minAmount: Int = 5
    static let maxAmount: Int = 10_000

    var body: some View {
        // ZStack with the bg colour as a full-bleed base layer so the
        // whole sheet (drag-indicator strip + safe-area gaps included)
        // is one colour — the prior `.background` on the content VStack
        // only covered the VStack's hugged height, leaving the sheet's
        // default grey showing top + bottom.
        ZStack {
            Theme.Color.bgPrimary.ignoresSafeArea()
            sheetContent
        }
        .presentationDetents([.height(290)])
        .presentationDragIndicator(.visible)
    }

    private var sheetContent: some View {
        VStack(spacing: 14) {
            Text(String(format: "reputation.give.body".localized, targetNickname))
                .font(.callout)
                .foregroundColor(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
                .padding(.top, 18)

            // GIF butts up against the typed amount — the textfield
            // is auto-sized to its content (no fixed width) so the
            // coin and number stay visually paired regardless of
            // digit count. Suffix sits in its own line below to keep
            // the input row compact.
            HStack(spacing: 6) {
                ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                    .frame(width: 22, height: 22)
                TextField("", text: $amountText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.leading)
                    .font(.system(.title3, design: .monospaced).weight(.bold))
                    .fixedSize()
                Text("reputation.give.amount_suffix".localized)
                    .font(.caption)
                    .foregroundColor(Theme.Color.textSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Theme.Color.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Text(String(format: "reputation.give.balance".localized, items.wallet.tokens))
                .font(.caption)
                .foregroundColor(amount > items.wallet.tokens ? .red : Theme.Color.textSecondary)

            Toggle(isOn: $anonymous) {
                Text("reputation.give.anonymous".localized)
                    .font(.callout)
                    .foregroundColor(Theme.Color.textPrimary)
            }
            .padding(.horizontal, 24)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Button {
                Task { await send() }
            } label: {
                HStack(spacing: 8) {
                    if sending {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                    }
                    Text("reputation.give.send".localized)
                        .font(.body.weight(.semibold))
                        .foregroundColor(.white)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(canSend ? Theme.Color.accent : Theme.Color.accent.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .padding(.horizontal, 24)
            .padding(.top, 4)
            .padding(.bottom, 18)
        }
    }

    private func send() async {
        guard !sending else { return }
        let n = amount
        guard n >= Self.minAmount else {
            errorMessage = String(format: "reputation.give.error_min".localized, Self.minAmount)
            return
        }
        sending = true
        errorMessage = nil
        let result = await APIClient.shared.grantReputation(
            targetUIN: targetUIN,
            amount: n,
            anonymous: anonymous,
        )
        sending = false
        switch result {
        case .success(let out):
            items.setWalletTokens(out.donorBalance)
            onSuccess(out.targetReputation)
            dismiss()
        case .failure(let err):
            errorMessage = err.message
        }
    }
}

import SwiftUI

struct JetonReactSheet: View {
    let groupID: Int
    let messageID: UUID
    let targetUIN: Int
    let targetNickname: String
    let onSuccess: (_ newTotal: Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var items = ItemsService.shared

    @State private var amountText: String = "10"
    @State private var sending: Bool = false
    @State private var errorMessage: String?

    private var amount: Int { Int(amountText) ?? 0 }
    private var canSend: Bool {
        amount >= JetonReactSheet.minAmount &&
        amount <= JetonReactSheet.maxAmount &&
        amount <= items.wallet.tokens &&
        !sending
    }

    static let minAmount: Int = 1
    static let maxAmount: Int = 100_000

    var body: some View {
        ZStack {
            Theme.Color.bgPrimary.ignoresSafeArea()
            sheetContent
        }
        .presentationDetents([.height(250)])
        .presentationDragIndicator(.visible)
    }

    private var sheetContent: some View {
        VStack(spacing: 14) {
            Text(String(format: "jeton.react.body".localized, targetNickname))
                .font(.callout)
                .foregroundColor(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
                .padding(.top, 18)

            HStack(spacing: 6) {
                ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                    .frame(width: 22, height: 22)
                TextField("", text: $amountText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.leading)
                    .font(.system(.title3, design: .monospaced).weight(.bold))
                    .fixedSize()
                Text("jeton.react.amount_suffix".localized)
                    .font(.caption)
                    .foregroundColor(Theme.Color.textSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Theme.Color.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Text(String(format: "jeton.react.balance".localized, items.wallet.tokens))
                .font(.caption)
                .foregroundColor(amount > items.wallet.tokens ? .red : Theme.Color.textSecondary)

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
                    Text("jeton.react.send".localized)
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
            errorMessage = String(format: "jeton.react.error_min".localized, Self.minAmount)
            return
        }
        sending = true
        errorMessage = nil
        let result = await APIClient.shared.jetonReact(
            groupID: groupID,
            messageID: messageID.uuidString.lowercased(),
            targetUIN: targetUIN,
            amount: n
        )
        sending = false
        switch result {
        case .success(let out):
            items.setWalletTokens(out.reactorBalance)
            JetonStore.shared.apply(messageID: messageID, total: out.totalJetons)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onSuccess(out.totalJetons)
            dismiss()
        case .failure(let err):
            errorMessage = err.message
        }
    }
}

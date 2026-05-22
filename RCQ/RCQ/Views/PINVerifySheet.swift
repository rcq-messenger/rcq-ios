import SwiftUI

struct PINVerifySheet: View {
    let title: String
    var onVerified: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        ZStack {
            Theme.Color.bgPrimary.ignoresSafeArea()
            VStack(spacing: 20) {
                HStack {
                    Button("common.cancel".localized) { dismiss() }
                        .foregroundColor(Theme.Color.textSecondary)
                    Spacer()
                }
                Spacer()
                Image(systemName: "lock.shield")
                    .font(.system(size: 36))
                    .foregroundColor(Theme.Color.accent)
                Text(title)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(Theme.Color.textPrimary)
                    .multilineTextAlignment(.center)
                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                } else {
                    Text("pin_verify.hint".localized)
                        .font(.caption)
                        .foregroundColor(Theme.Color.textSecondary)
                }
                Spacer()
                PINPad(pin: $pin, busy: busy) {
                    Task { await verify() }
                }
                Spacer()
            }
            .padding(.horizontal, 32)
            .padding(.top, 16)
        }
    }

    private func verify() async {
        busy = true
        let ok = await PanicPINService.shared.verifyRealPIN(pin)
        busy = false
        if ok {
            onVerified()
            dismiss()
        } else {
            error = "pin_verify.wrong".localized
            pin = ""
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}

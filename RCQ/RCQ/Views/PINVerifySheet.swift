import SwiftUI

struct PINVerifySheet: View {
    /// Which PIN this sheet accepts.
    enum Check {
        /// The real PIN only, as every caller asked before #1045. For anything
        /// that hands over the REAL account (the recovery phrase, a backup).
        case real
        /// The PIN that opened this session: the real one in a real session,
        /// the decoy one in a decoy session. For the gates that guard the chat
        /// lock itself (#1045). A person made to open the app with the decoy
        /// PIN is then asked for "the PIN" again, and the only PIN they have
        /// given failing in front of whoever is watching is exactly the tell a
        /// decoy exists to avoid (report #237, same rule as PINSettingsView).
        case session
    }

    let title: String
    var check: Check = .real
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
        let ok: Bool
        switch check {
        case .real: ok = await PanicPINService.shared.verifyRealPIN(pin)
        case .session: ok = await PanicPINService.shared.verifySessionPIN(pin)
        }
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

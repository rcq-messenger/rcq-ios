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
    /// Drawn in place as a screen's own content (the locked chat) rather than
    /// presented. Cancel still leaves (`dismiss` pops the screen); a right PIN
    /// leaves the screen standing, since it is the thing being opened.
    var inline: Bool = false
    var onVerified: () -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var panicPIN = PanicPINService.shared
    @State private var pin = ""
    @State private var busy = false
    @State private var error: String?
    @State private var now = Date()

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// The lock screen's lockout, which a wrong PIN here earns as well.
    private var lockedOut: Bool { (panicPIN.lockoutUntil ?? .distantPast) > now }

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
                if lockedOut, let until = panicPIN.lockoutUntil {
                    // Same two lines the lock screen shows for the same state.
                    VStack(spacing: 4) {
                        Text("panic_pin.lock.locked_out".localized)
                            .font(.caption)
                            .foregroundColor(.red)
                        Text(countdown(to: until))
                            .font(.system(.body, design: .monospaced).weight(.semibold))
                            .foregroundColor(Theme.Color.textPrimary)
                    }
                } else if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                } else {
                    Text("pin_verify.hint".localized)
                        .font(.caption)
                        .foregroundColor(Theme.Color.textSecondary)
                }
                Spacer()
                PINPad(pin: $pin, busy: busy, disabled: lockedOut) {
                    Task { await verify() }
                }
                Spacer()
            }
            .padding(.horizontal, 32)
            .padding(.top, 16)
        }
        .onReceive(ticker) { now = $0 }
    }

    private func countdown(to deadline: Date) -> String {
        let secs = max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
        return String(format: "%d:%02d", secs / 60, secs % 60)
    }

    private func verify() async {
        busy = true
        let result = await PanicPINService.shared.verifyThrottled(pin, session: check == .session)
        busy = false
        now = Date()
        switch result {
        case .ok:
            onVerified()
            if !inline { dismiss() }
        case .wrong, .lockedOut:
            error = "pin_verify.wrong".localized
            pin = ""
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}

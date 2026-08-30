import SwiftUI

struct PINPad: View {
    @Binding var pin: String
    var busy: Bool = false
    var disabled: Bool = false
    var maxLength: Int = 12
    var onSubmit: () -> Void

    private var ready: Bool { pin.count >= PanicPINService.minPINLength }
    private var inactive: Bool { busy || disabled }

    var body: some View {
        VStack(spacing: 26) {
            dots
            keypad
                .disabled(inactive)
                .opacity(inactive ? 0.4 : 1)
            if busy {
                ProgressView()
            } else {
                Color.clear.frame(height: 20)
            }
        }
    }

    private var dots: some View {
        HStack(spacing: 14) {
            ForEach(0..<max(pin.count, PanicPINService.minPINLength), id: \.self) { i in
                Circle()
                    .fill(i < pin.count ? Theme.Color.accent : Theme.Color.textSecondary.opacity(0.25))
                    .frame(width: 12, height: 12)
            }
        }
        .frame(height: 14)
        .animation(.easeOut(duration: 0.12), value: pin.count)
    }

    private var keypad: some View {
        VStack(spacing: 16) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 24) {
                    ForEach(1...3, id: \.self) { col in
                        digitButton(String(row * 3 + col))
                    }
                }
            }
            HStack(spacing: 24) {
                backspaceButton
                digitButton("0")
                submitButton
            }
        }
    }

    private func digitButton(_ digit: String) -> some View {
        Button {
            guard pin.count < maxLength else { return }
            pin.append(digit)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            Text(digit)
                .font(.system(size: 30, weight: .regular, design: .rounded))
                .foregroundColor(Theme.Color.textPrimary)
                .frame(width: 76, height: 76)
                .background(Circle().fill(Theme.Color.textSecondary.opacity(0.12)))
        }
    }

    private var backspaceButton: some View {
        Button {
            if !pin.isEmpty { pin.removeLast() }
        } label: {
            Image(systemName: "delete.left")
                .font(.system(size: 24))
                .foregroundColor(Theme.Color.textSecondary)
                .frame(width: 76, height: 76)
        }
        .opacity(pin.isEmpty ? 0.3 : 1)
        .disabled(pin.isEmpty)
    }

    private var submitButton: some View {
        Button {
            onSubmit()
        } label: {
            Image(systemName: "arrow.right")
                .font(.system(size: 26, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 76, height: 76)
                .background(Circle().fill(ready ? Theme.Color.accent : Theme.Color.textSecondary.opacity(0.2)))
        }
        .disabled(!ready || inactive)
    }
}

struct PINLockView: View {
    @StateObject private var panicPIN = PanicPINService.shared
    @State private var pin: String = ""
    @State private var verifying: Bool = false
    @State private var triedBiometric: Bool = false
    @State private var now = Date()

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var biometricOn: Bool { panicPIN.biometricEnabled }
    private var lockedOut: Bool { (panicPIN.lockoutUntil ?? .distantPast) > now }

    var body: some View {
        ZStack {
            Theme.Color.bgPrimary.ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()
                Image(systemName: "lock.fill")
                    .font(.system(size: 34))
                    .foregroundColor(Theme.Color.accent)
                Text("panic_pin.lock.title".localized)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundColor(Theme.Color.textPrimary)
                if lockedOut, let until = panicPIN.lockoutUntil {
                    VStack(spacing: 4) {
                        Text("panic_pin.lock.locked_out".localized)
                            .font(.subheadline)
                            .foregroundColor(.red)
                        Text(countdown(to: until))
                            .font(.system(.title3, design: .monospaced).weight(.semibold))
                            .foregroundColor(Theme.Color.textPrimary)
                    }
                }
                Spacer()
                PINPad(pin: $pin, busy: verifying, disabled: lockedOut) {
                    Task { await submit() }
                }
                if biometricOn {
                    Button {
                        Task { await tryBiometric() }
                    } label: {
                        Label("panic_pin.lock.use_biometric".localized, systemImage: "faceid")
                            .font(.subheadline)
                            .foregroundColor(Theme.Color.accent)
                    }
                    .disabled(verifying)
                }
                Spacer()
            }
            .padding(.horizontal, 40)
        }
        .onReceive(ticker) { now = $0 }
        .task {
            guard biometricOn, !triedBiometric else { return }
            triedBiometric = true
            await tryBiometric()
        }
        // While the person types, the history container opens on a background
        // thread, so the unlock tap finds it ready instead of freezing the
        // filled dots on a synchronous SQLite open (see MessageDB.prewarm).
        .task { await MessageDB.prewarm() }
    }

    private func countdown(to deadline: Date) -> String {
        let secs = max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
        return String(format: "%d:%02d", secs / 60, secs % 60)
    }

    private func tryBiometric() async {
        verifying = true
        let ok = await PanicPINService.shared.unlockWithBiometrics()
        if !ok { verifying = false }
    }

    private func submit() async {
        verifying = true
        let result = await PanicPINService.shared.submit(pin: pin)
        switch result {
        case .unlockedReal, .unlockedDecoy:
            return
        case .wipe(let deleteServerAccount):
            await AppState.shared.performPanicWipe(deleteServerAccount: deleteServerAccount)
            return
        case .wrong, .lockedOut:
            verifying = false
            pin = ""
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}

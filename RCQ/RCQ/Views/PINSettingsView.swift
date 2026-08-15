import SwiftUI

enum PINEntryPurpose: Identifiable {
    case setReal
    case changeReal
    case setDecoy
    case setWipe

    var id: Int { hashValue }
}

struct PINSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var panicPIN = PanicPINService.shared

    @State private var entry: PINEntryPurpose?
    @State private var showSeedPicker = false
    /// Set when the decoy entry sheet is opened on a vault that has NO decoy
    /// yet, so its dismissal can offer the seed picker exactly once.
    @State private var pendingSeedPrompt = false
    @State private var confirmRemoveAll = false
    @State private var confirmRemoveWipe = false
    @State private var confirmRemoveDecoy = false
    @State private var busy = false
    @State private var errorMsg: String?

    @State private var reauthDone = false
    @State private var reauthPIN = ""
    @State private var reauthBusy = false
    @State private var reauthError: String?

    private var needsReauth: Bool { panicPIN.isConfigured && !reauthDone }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                if needsReauth {
                    reauthView
                } else {
                    Form {
                        if panicPIN.isConfigured {
                            configuredSections
                        } else {
                            setupSection
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("panic_pin.settings.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.done".localized) { dismiss() }
                }
            }
            .sheet(item: $entry, onDismiss: {
                // A decoy that was just created is empty, and an empty decoy is
                // the one thing this feature exists to avoid — so go straight
                // to picking what fills it. Only on FIRST creation; changing an
                // existing decoy PIN leaves its seed alone.
                let shouldPrompt = pendingSeedPrompt && panicPIN.hasDecoyPIN
                pendingSeedPrompt = false
                guard shouldPrompt else { return }
                // One runloop hop: presenting a sheet from inside another
                // sheet's onDismiss can be swallowed while the first is still
                // animating out.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    showSeedPicker = true
                }
            }) { purpose in
                PINEntrySheet(purpose: purpose)
            }
            .sheet(isPresented: $showSeedPicker) {
                DecoySeedPickerView()
            }
            .alert("panic_pin.remove_all.confirm.title".localized, isPresented: $confirmRemoveAll) {
                Button("common.cancel".localized, role: .cancel) {}
                Button("panic_pin.remove_all.confirm.action".localized, role: .destructive) {
                    Task { await removeAll() }
                }
            } message: {
                Text("panic_pin.remove_all.confirm.body".localized)
            }
            .alert("panic_pin.wipe.remove.confirm.title".localized, isPresented: $confirmRemoveWipe) {
                Button("common.cancel".localized, role: .cancel) {}
                Button("panic_pin.wipe.remove.confirm.action".localized, role: .destructive) {
                    try? panicPIN.removeWipePIN()
                }
            }
            .alert("panic_pin.decoy.remove.confirm.title".localized, isPresented: $confirmRemoveDecoy) {
                Button("common.cancel".localized, role: .cancel) {}
                Button("panic_pin.decoy.remove.confirm.action".localized, role: .destructive) {
                    try? panicPIN.removeDecoyPIN()
                }
            }
            .alert("panic_pin.error.title".localized,
                   isPresented: Binding(get: { errorMsg != nil }, set: { if !$0 { errorMsg = nil } })) {
                Button("common.ok".localized, role: .cancel) {}
            } message: {
                Text(errorMsg ?? "")
            }
        }
    }

    // MARK: - re-auth gate

    private var reauthView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "lock.shield")
                .font(.system(size: 38))
                .foregroundColor(Theme.Color.accent)
            Text("panic_pin.reauth.title".localized)
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundColor(Theme.Color.textPrimary)
            if let reauthError {
                Text(reauthError)
                    .font(.caption)
                    .foregroundColor(.red)
            } else {
                Text("panic_pin.reauth.hint".localized)
                    .font(.caption)
                    .foregroundColor(Theme.Color.textSecondary)
            }
            Spacer()
            PINPad(pin: $reauthPIN, busy: reauthBusy) {
                Task { await verifyReauth() }
            }
            Spacer()
        }
        .padding(.horizontal, 32)
    }

    private func verifyReauth() async {
        reauthBusy = true
        // Session-aware: the decoy pin re-auths in a decoy session, so a
        // coercer's pin doesn't fail here and betray a second pin (report #237).
        let ok = await panicPIN.verifySessionPIN(reauthPIN)
        reauthBusy = false
        if ok {
            reauthError = nil
            reauthDone = true
        } else {
            reauthError = "panic_pin.reauth.wrong".localized
            reauthPIN = ""
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    // MARK: - sections

    private var setupSection: some View {
        Section {
            Button {
                entry = .setReal
            } label: {
                Label("panic_pin.setup.action".localized, systemImage: "lock.shield")
                    .foregroundColor(Theme.Color.accent)
            }
        } header: {
            Text("panic_pin.settings.section".localized)
        } footer: {
            Text("panic_pin.setup.footer".localized)
        }
        .listRowBackground(Theme.Color.bgSecondary)
    }

    @ViewBuilder
    private var configuredSections: some View {
        Section {
            Button {
                entry = .changeReal
            } label: {
                Label("panic_pin.change.action".localized, systemImage: "lock.rotation")
                    .foregroundColor(Theme.Color.textPrimary)
            }
        } header: {
            Text("panic_pin.settings.section".localized)
        } footer: {
            Text("panic_pin.settings.footer".localized)
        }
        .listRowBackground(Theme.Color.bgSecondary)

        // Report #237 (deniability): in a decoy session the screen must not
        // reveal that a decoy/wipe pin — or a hidden real identity — exists.
        // Show ONLY a plausible Change-PIN (which re-seals the decoy slot) and
        // the benign auto-lock control; hide every duress/biometric/remove row.
        if !panicPIN.isDecoy {
            decoySection
            biometricSection
        }

        autoLockSection

        if !panicPIN.isDecoy {
            wipeSection
            removeAllSection
        }
    }

    @ViewBuilder
    private var decoySection: some View {
        Section {
            if panicPIN.hasDecoyPIN {
                Button {
                    entry = .setDecoy
                } label: {
                    Label("panic_pin.decoy.change".localized, systemImage: "rectangle.on.rectangle")
                        .foregroundColor(Theme.Color.textPrimary)
                }
                Button {
                    showSeedPicker = true
                } label: {
                    Label("panic_pin.decoy.seed.action".localized, systemImage: "text.badge.plus")
                        .foregroundColor(Theme.Color.textPrimary)
                }
                Button(role: .destructive) {
                    confirmRemoveDecoy = true
                } label: {
                    Text("panic_pin.decoy.remove".localized)
                }
            } else {
                Button {
                    pendingSeedPrompt = true
                    entry = .setDecoy
                } label: {
                    Label("panic_pin.decoy.action".localized, systemImage: "rectangle.on.rectangle")
                        .foregroundColor(panicPIN.biometricEnabled ? Theme.Color.textSecondary : Theme.Color.accent)
                }
                .disabled(panicPIN.biometricEnabled)
            }
        } header: {
            Text("panic_pin.decoy.section".localized)
        } footer: {
            Text(panicPIN.biometricEnabled
                 ? "panic_pin.decoy.footer.biometric".localized
                 : "panic_pin.decoy.footer".localized)
        }
        .listRowBackground(Theme.Color.bgSecondary)
    }

    @ViewBuilder
    private var biometricSection: some View {
        if panicPIN.biometricAvailable {
            Section {
                Toggle(isOn: Binding(
                    get: { panicPIN.biometricEnabled },
                    set: { on in
                        if on {
                            do { try panicPIN.enableBiometric() }
                            catch { errorMsg = error.localizedDescription }
                        } else {
                            panicPIN.disableBiometric()
                        }
                    }
                )) {
                    Label("panic_pin.biometric.toggle".localized, systemImage: "faceid")
                        .foregroundColor(Theme.Color.textPrimary)
                }
                .tint(Theme.Color.accent)
                .disabled(panicPIN.hasWipePIN || panicPIN.hasDecoyPIN)
            } header: {
                Text("panic_pin.biometric.section".localized)
            } footer: {
                Text((panicPIN.hasWipePIN || panicPIN.hasDecoyPIN)
                     ? "panic_pin.biometric.footer.conflict".localized
                     : "panic_pin.biometric.footer".localized)
            }
            .listRowBackground(Theme.Color.bgSecondary)
        }
    }

    // Auto-lock grace (#10): how long backgrounded before the PIN is asked
    // again. 0 = immediately. Replaces the old hardcoded 30s.
    private var autoLockSection: some View {
        Section {
            Picker("panic_pin.autolock".localized, selection: Binding(
                get: { panicPIN.lockTimeout },
                set: { panicPIN.lockTimeout = $0 }
            )) {
                Text("panic_pin.autolock.immediate".localized).tag(0)
                Text("panic_pin.autolock.30s".localized).tag(30)
                Text("panic_pin.autolock.1m".localized).tag(60)
                Text("panic_pin.autolock.5m".localized).tag(300)
                Text("panic_pin.autolock.15m".localized).tag(900)
            }
            .tint(Theme.Color.textSecondary)
        } header: {
            Text("panic_pin.autolock.section".localized)
        } footer: {
            Text("panic_pin.autolock.footer".localized)
        }
        .listRowBackground(Theme.Color.bgSecondary)
    }

    @ViewBuilder
    private var wipeSection: some View {
        Section {
            if panicPIN.hasWipePIN {
                Button {
                    entry = .setWipe
                } label: {
                    Label("panic_pin.wipe.change".localized, systemImage: "trash")
                        .foregroundColor(Theme.Color.textPrimary)
                }
                Button(role: .destructive) {
                    confirmRemoveWipe = true
                } label: {
                    Text("panic_pin.wipe.remove".localized)
                }
            } else {
                Button {
                    entry = .setWipe
                } label: {
                    Label("panic_pin.wipe.action".localized, systemImage: "trash")
                        .foregroundColor(panicPIN.biometricEnabled ? Theme.Color.textSecondary : .red)
                }
                .disabled(panicPIN.biometricEnabled)
            }
        } header: {
            Text("panic_pin.wipe.section".localized)
        } footer: {
            Text(wipeFooter)
        }
        .listRowBackground(Theme.Color.bgSecondary)
    }

    /// The server-erase choice cannot be read back (it lives in the wipe slot,
    /// which only the wipe PIN opens — see PanicPINService), so the footer says
    /// where the choice is made rather than pretending to report its value.
    private var wipeFooter: String {
        if panicPIN.biometricEnabled { return "panic_pin.wipe.footer.biometric".localized }
        let base = "panic_pin.wipe.footer".localized
        guard panicPIN.hasWipePIN else { return base }
        return base + "\n\n" + "panic_pin.wipe.footer.server_where".localized
    }

    private var removeAllSection: some View {
        Section {
            Button(role: .destructive) {
                confirmRemoveAll = true
            } label: {
                if busy {
                    ProgressView()
                } else {
                    Text("panic_pin.remove_all.action".localized)
                }
            }
            .disabled(busy)
        }
        .listRowBackground(Theme.Color.bgSecondary)
    }

    // MARK: - actions

    private func removeAll() async {
        busy = true
        do {
            try await panicPIN.removeAllPINs()
        } catch {
            errorMsg = error.localizedDescription
        }
        busy = false
    }
}

struct PINEntrySheet: View {
    let purpose: PINEntryPurpose

    @Environment(\.dismiss) private var dismiss

    private enum Phase { case warning, enter, confirm }

    @State private var phase: Phase
    @State private var firstPIN: String = ""
    @State private var pin: String = ""
    @State private var busy: Bool = false
    @State private var error: String?
    /// Wipe PIN only, and DEFAULT OFF every time this sheet opens. Off is what
    /// every locale's wipe copy has always promised ("on this device"), and the
    /// previous value cannot be read back — it is sealed in the wipe slot,
    /// which only the wipe PIN opens. Failing to off is the right failure: a
    /// user who wanted the server erase re-checks a box, a user who did not
    /// never loses an account they meant to keep.
    @State private var wipeDeleteServer = false

    init(purpose: PINEntryPurpose) {
        self.purpose = purpose
        _phase = State(initialValue: purpose == .setWipe ? .warning : .enter)
    }

    var body: some View {
        ZStack {
            Theme.Color.bgPrimary.ignoresSafeArea()
            switch phase {
            case .warning: warningView
            case .enter, .confirm: entryView
            }
        }
    }

    // MARK: - warning (wipe only)

    /// Scrolls, and the buttons are pinned outside it. The warning text plus the
    /// server-erase toggle and its explanation is more than fits between two
    /// Spacers on a 4.7" screen, and the one control that must never be pushed
    /// off the bottom is Continue.
    private var warningView: some View {
        VStack(spacing: 20) {
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 44))
                        .foregroundColor(.red)
                    Text("panic_pin.wipe.warning.title".localized)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundColor(Theme.Color.textPrimary)
                    Text("panic_pin.wipe.warning.body".localized)
                        .font(.callout)
                        .foregroundColor(Theme.Color.textSecondary)
                        .multilineTextAlignment(.center)
                    serverEraseToggle
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            }
            Button {
                phase = .enter
            } label: {
                Text("panic_pin.wipe.warning.continue".localized)
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.red))
            }
            Button("common.cancel".localized) { dismiss() }
                .foregroundColor(Theme.Color.textSecondary)
            Spacer().frame(height: 12)
        }
        .padding(.horizontal, 28)
    }

    /// Opt-in server erase. The value is written into the WIPE SLOT payload by
    /// `setWipePIN`, so flipping it needs the real PIN and reading it back at
    /// wipe time needs the wipe PIN — unlike a pref, which anyone holding an
    /// unlocked phone could switch off.
    private var serverEraseToggle: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $wipeDeleteServer) {
                Text("panic_pin.wipe.server.toggle".localized)
                    .font(.callout)
                    .foregroundColor(Theme.Color.textPrimary)
            }
            .tint(.red)
            Text("panic_pin.wipe.server.footer".localized)
                .font(.caption)
                .foregroundColor(Theme.Color.textSecondary)
        }
        .padding(.bottom, 8)
    }

    // MARK: - PIN entry

    private var entryView: some View {
        VStack(spacing: 20) {
            HStack {
                Button("common.cancel".localized) { dismiss() }
                    .foregroundColor(Theme.Color.textSecondary)
                Spacer()
            }
            Spacer()
            Text(title)
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundColor(Theme.Color.textPrimary)
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            } else {
                Text("panic_pin.entry.hint".localized)
                    .font(.caption)
                    .foregroundColor(Theme.Color.textSecondary)
            }
            Spacer()
            PINPad(pin: $pin, busy: busy) { advance() }
            Spacer()
        }
        .padding(.horizontal, 32)
        .padding(.top, 16)
    }

    private var title: String {
        switch (purpose, phase) {
        case (.setReal, .enter), (.changeReal, .enter):
            return "panic_pin.entry.title.new".localized
        case (.setDecoy, .enter):
            return "panic_pin.entry.title.decoy".localized
        case (.setWipe, .enter):
            return "panic_pin.entry.title.wipe".localized
        case (_, .confirm):
            return "panic_pin.entry.title.confirm".localized
        default:
            return "panic_pin.entry.title.new".localized
        }
    }

    // MARK: - flow

    private func advance() {
        error = nil
        if phase == .enter {
            firstPIN = pin
            pin = ""
            phase = .confirm
            return
        }
        guard pin == firstPIN else {
            error = "panic_pin.entry.mismatch".localized
            pin = ""
            firstPIN = ""
            phase = .enter
            return
        }
        Task { await commit() }
    }

    private func commit() async {
        busy = true
        do {
            switch purpose {
            case .setReal, .changeReal:
                // In a decoy session "change PIN" re-seals the DECOY slot only,
                // never the real one (report #237). setRealPIN is real-only.
                if PanicPINService.shared.isDecoy {
                    try await PanicPINService.shared.changeDecoyPIN(pin)
                } else {
                    try await PanicPINService.shared.setRealPIN(pin)
                }
            case .setDecoy:
                try await PanicPINService.shared.setDecoyPIN(pin)
            case .setWipe:
                try await PanicPINService.shared.setWipePIN(
                    pin, deleteServerAccount: wipeDeleteServer
                )
            }
            busy = false
            dismiss()
        } catch {
            busy = false
            self.error = error.localizedDescription
            pin = ""
            firstPIN = ""
            phase = .enter
        }
    }
}

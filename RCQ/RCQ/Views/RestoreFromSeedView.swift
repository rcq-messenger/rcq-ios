import SwiftUI

/// "Restore from phrase": paste a 24-word BIP39 recovery phrase to bring an
/// existing identity back on a fresh device (Android `ui/RestoreScreen`
/// parity). Reachable from onboarding (the new-phone case) and from
/// Settings → Add account. Derivation + the `/auth/recover` proof are handled
/// by `AppState.recoverAccount`; this view is just the form + status.
struct RestoreFromSeedView: View {
    /// Called once the account is recovered, activated and booted. Onboarding
    /// passes a closure that marks onboarding complete; the add-account flow
    /// just dismisses.
    var onCompleted: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    @State private var input: String = ""
    @State private var server: String
    @State private var showServer = false
    @State private var restoring = false
    @State private var error: String?

    init(onCompleted: @escaping () -> Void = {}) {
        self.onCompleted = onCompleted
        // Prefill with the server picked during onboarding (rcq.baseURL), else
        // the public default. The user can override under "Advanced".
        let stored = UserDefaults.standard.string(forKey: "rcq.baseURL")
        _server = State(initialValue: (stored?.isEmpty == false ? stored! : "https://api.rcq.app"))
    }

    private var words: [String] { RecoveryPhrase.parse(input) }
    private var wordCount: Int { words.count }
    // 24 words = a normal seed phrase; 48 = a legacy account's raw-key export.
    private var canRestore: Bool { (wordCount == 24 || wordCount == 48) && !restoring && serverURL != nil }

    /// Normalized https URL, or nil when the field is malformed.
    private var serverURL: String? {
        let t = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "https://api.rcq.app" }
        let withScheme = (t.hasPrefix("http://") || t.hasPrefix("https://")) ? t : "https://\(t)"
        guard let url = URL(string: withScheme), url.host?.isEmpty == false else { return nil }
        return withScheme
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                if restoring {
                    loadingState
                } else {
                    form
                }
            }
            .navigationTitle("recovery.restore.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel".localized) { dismiss() }
                        .disabled(restoring)
                }
            }
        }
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("recovery.restore.subtitle".localized)
                    .font(.callout)
                    .foregroundColor(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                ZStack(alignment: .topLeading) {
                    if input.isEmpty {
                        Text("recovery.restore.placeholder".localized)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundColor(Theme.Color.textSecondary.opacity(0.5))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 14)
                    }
                    TextEditor(text: $input)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundColor(Theme.Color.textPrimary)
                        .scrollContentBackground(.hidden)
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                        .frame(minHeight: 120)
                        .padding(8)
                }
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.Color.bgSecondary))

                HStack {
                    Text(String(format: "recovery.restore.word_count".localized, wordCount))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(wordCount == 24 ? Theme.Color.accent : Theme.Color.textSecondary)
                    Spacer()
                    Button {
                        withAnimation { showServer.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text("recovery.restore.advanced".localized)
                            Image(systemName: showServer ? "chevron.up" : "chevron.down")
                                .font(.caption2)
                        }
                        .font(.caption.weight(.medium))
                        .foregroundColor(Theme.Color.textSecondary)
                    }
                    .buttonStyle(.plain)
                }

                if showServer {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("recovery.restore.server.label".localized)
                            .font(.caption2)
                            .tracking(1.0)
                            .foregroundColor(Theme.Color.textSecondary)
                        TextField("https://api.rcq.app", text: $server)
                            .keyboardType(.URL)
                            .autocorrectionDisabled(true)
                            .textInputAutocapitalization(.never)
                            .font(.system(.callout, design: .monospaced))
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.Color.bgSecondary))
                    }
                }

                if let error {
                    Text(error)
                        .font(.footnote)
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    Task { await restore() }
                } label: {
                    Text("recovery.restore.cta".localized)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(canRestore ? Theme.Color.accent : Theme.Color.bgSecondary)
                        .foregroundColor(canRestore ? .white : Theme.Color.textSecondary)
                        .clipShape(Capsule())
                }
                .disabled(!canRestore)
            }
            .padding(20)
        }
    }

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView().scaleEffect(1.2)
            Text("recovery.restore.working".localized)
                .font(.callout)
                .foregroundColor(Theme.Color.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func restore() async {
        guard let url = serverURL else {
            error = "recovery.restore.error.server".localized
            return
        }
        restoring = true
        error = nil
        let result = await AppState.shared.recoverAccount(phrase: words, serverURL: url)
        restoring = false
        if let result {
            error = result
            return
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onCompleted()
        dismiss()
    }
}

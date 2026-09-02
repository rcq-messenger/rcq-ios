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
    /// Masquerade token for a PRIVATE island (Caddy X-RCQ-Auth gate) — same as
    /// the new-account flow. Empty for public backends.
    @State private var serverToken: String = ""
    @State private var showServer = false
    @State private var restoring = false
    @State private var error: String?
    /// The typed address disagrees with what this device holds for that
    /// island (design §3): the banner under the form, nothing dialled.
    @State private var trustChange: IslandTrust.Change?

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

    /// Normalized https URL, or nil when the field is malformed. The
    /// `#fingerprint` comes off first (design §3) and is checked, not dropped:
    /// a fragment that is not one makes the whole address invalid, so nothing
    /// is dialled under a pin the person believes they set.
    private var serverURL: String? {
        let split = IslandTrust.splitAddress(server)
        if split.badFragment { return nil }
        let t = split.address
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
            .navigationTitle("recovery.restore.title.short".localized)
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
                        // Access token for a PRIVATE island (parity with the
                        // new-account form) — recovering there needs it too.
                        TextField("add_account.custom.token".localized, text: $serverToken)
                            .autocorrectionDisabled(true)
                            .textInputAutocapitalization(.never)
                            .font(.system(.caption, design: .monospaced))
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.Color.bgSecondary))
                    }
                }

                if let trustChange {
                    IslandTrustChangedBanner(change: trustChange) {
                        server = trustChange.rewriting(server)
                        self.trustChange = nil
                        Task { await restore() }
                    }
                    .cornerRadius(10)
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
            error = (IslandTrust.splitAddress(server).badFragment
                ? "island.trust.not_fingerprint" : "recovery.restore.error.server").localized
            return
        }
        // The trust door (design §3), on the raw field so the fragment reaches
        // it: pinned as typed before the recover probes, or refused here.
        trustChange = nil
        switch IslandTrust.shared.admit(typed: server) {
        case .admitted:
            break
        case .notAFingerprint:
            error = "island.trust.not_fingerprint".localized
            return
        case .caOnlyHost:
            error = "island.trust.ca_only".localized
            return
        case .changed(let change):
            trustChange = change
            return
        }
        restoring = true
        error = nil
        let token = serverToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = await AppState.shared.recoverAccount(
            phrase: words, serverURL: url, serverToken: token.isEmpty ? nil : token)
        restoring = false
        if let result {
            // Refused by this device, not by the island: the banner with both
            // fingerprints says so where "unreachable" would mislead.
            if let change = IslandTrust.shared.change(forAddress: url) {
                trustChange = change
            } else {
                error = result
            }
            return
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onCompleted()
        dismiss()
    }
}

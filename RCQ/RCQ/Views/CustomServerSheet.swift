import SwiftUI

/// Point the iOS client at a different backend than `api.rcq.app`.
///
/// Sets `rcq.baseURL` in UserDefaults, which `APIClient.defaultBaseURL`
/// reads on every call. Changing the server is destructive — your
/// current UIN / token / contacts only exist on `api.rcq.app`, the
/// new server has its own user table — so we require explicit
/// confirmation and an account burn before the switch lands. After
/// the switch the boot pipeline mints a fresh identity on the new
/// server.
///
/// Compatible with Stealth Mode: `rcq.proxyURL` and the auto-engage
/// path still wrap around whichever base URL is active. If you point
/// at your own self-host that's already reachable, you can also
/// turn off auto-stealth from the Stealth sheet to skip the embedded
/// sing-box hop.
struct CustomServerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("rcq.baseURL") private var customServer: String = ""

    @State private var draft: String = ""
    @State private var showConfirmSwitch = false
    @State private var showConfirmReset = false
    @State private var switching = false
    @State private var validationError: String?
    /// The typed address disagrees with what this device holds for that
    /// island (design §3): the banner under the field, nothing dialled.
    @State private var trustChange: IslandTrust.Change?

    private static let defaultServer = "https://api.rcq.app"

    private var trimmed: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The address with its `#fingerprint` taken off first (design §3); a
    /// fragment that is not a fingerprint makes the whole address invalid
    /// rather than being dropped on the way to `URL`.
    private var split: IslandTrust.Split { IslandTrust.splitAddress(trimmed) }

    private var isValidURL: Bool {
        guard !split.badFragment,
              let url = URL(string: split.address),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host?.isEmpty == false
        else { return false }
        return true
    }

    private var isDirty: Bool {
        trimmed != customServer
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        intro
                        currentServerCard
                        inputBlock
                        warningBlock
                        if customServer.isEmpty == false {
                            resetButton
                        }
                        Spacer(minLength: 24)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                }
            }
            .navigationTitle("settings.network.custom_server".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".localized) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save".localized) {
                        guard isValidURL, isDirty else { return }
                        showConfirmSwitch = true
                    }
                    .disabled(!isValidURL || !isDirty || switching)
                }
            }
            .onAppear {
                draft = customServer
            }
            .confirmationDialog(
                "settings.network.custom_server.confirm.title".localized,
                isPresented: $showConfirmSwitch,
                titleVisibility: .visible
            ) {
                Button("settings.network.custom_server.confirm.cta".localized) {
                    Task { await applySwitch() }
                }
                Button("common.cancel".localized, role: .cancel) {}
            } message: {
                Text("settings.network.custom_server.confirm.body".localized)
            }
            .confirmationDialog(
                "settings.network.custom_server.reset.title".localized,
                isPresented: $showConfirmReset,
                titleVisibility: .visible
            ) {
                Button("settings.network.custom_server.reset.cta".localized) {
                    Task { await applyReset() }
                }
                Button("common.cancel".localized, role: .cancel) {}
            } message: {
                Text("settings.network.custom_server.reset.body".localized)
            }
        }
    }

    // MARK: - Sections

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("settings.network.custom_server.intro.title".localized)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.Color.textPrimary)
            Text("settings.network.custom_server.intro.body".localized)
                .font(.callout)
                .foregroundColor(Theme.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var currentServerCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("settings.network.custom_server.current.label".localized)
                .font(.caption2)
                .tracking(1.2)
                .foregroundColor(Theme.Color.textSecondary)
            Text(customServer.isEmpty ? Self.defaultServer : customServer)
                .font(.system(.callout, design: .monospaced))
                .foregroundColor(Theme.Color.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Color.bgSecondary)
        .cornerRadius(12)
    }

    private var inputBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("settings.network.custom_server.input.label".localized)
                .font(.caption2)
                .tracking(1.2)
                .foregroundColor(Theme.Color.textSecondary)
            TextField("https://your-domain.example", text: $draft)
                .keyboardType(.URL)
                .textContentType(.URL)
                .autocorrectionDisabled(true)
                .textInputAutocapitalization(.never)
                .font(.system(.callout, design: .monospaced))
                .padding(12)
                .background(Theme.Color.bgSecondary)
                .cornerRadius(10)
            if !trimmed.isEmpty && !isValidURL {
                Text((split.badFragment ? "island.trust.not_fingerprint" : "settings.network.custom_server.invalid").localized)
                    .font(.caption2)
                    .foregroundColor(.red.opacity(0.85))
            }
            if let trustChange {
                IslandTrustChangedBanner(change: trustChange) {
                    draft = trustChange.rewriting(trimmed)
                    self.trustChange = nil
                    Task { await applySwitch() }
                }
                .cornerRadius(10)
            }
            if let error = validationError {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.red.opacity(0.85))
            }
        }
    }

    private var warningBlock: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundColor(Theme.Color.accent)
            Text("settings.network.custom_server.warning".localized)
                .font(.caption)
                .foregroundColor(Theme.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Color.bgSecondary)
        .cornerRadius(10)
    }

    private var resetButton: some View {
        Button {
            showConfirmReset = true
        } label: {
            HStack {
                Image(systemName: "arrow.uturn.backward")
                Text("settings.network.custom_server.reset.cta".localized)
            }
            .font(.callout.weight(.semibold))
            .foregroundColor(.red.opacity(0.85))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(Theme.Color.bgSecondary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Apply

    private func applySwitch() async {
        guard isValidURL else { return }
        switching = true
        defer { switching = false }
        validationError = nil
        trustChange = nil
        if AccountManager.shared.isAtAccountLimit {
            validationError = String(format: "add_account.limit".localized, AccountManager.maxAccounts)
            return
        }
        // The trust door (design §3): a fingerprint is on file as typed before
        // the register, a disagreeing one is the banner and nothing is dialled.
        let address: String
        switch IslandTrust.shared.admit(typed: trimmed) {
        case .admitted(let a):
            address = a
        case .notAFingerprint:
            validationError = "island.trust.not_fingerprint".localized
            return
        case .caOnlyHost:
            validationError = "island.trust.ca_only".localized
            return
        case .changed(let change):
            trustChange = change
            return
        }
        // Non-destructive: ADD a new account on the chosen server instead of
        // burning the current one. The previous account (UIN, contacts,
        // history, favorites) stays on this device and is switchable from the
        // account switcher. Mirrors AddAccountSheet's proven add path, which
        // also sets the new account active and rebuilds the UI against it.
        let ok = await AppState.shared.addAccount(serverURL: address)
        if !ok || AppState.shared.bootError != nil {
            // Roll back a dangling account so we land back on the previous one.
            if let danglingID = AccountManager.shared.activeAccountID,
               AccountManager.shared.accounts.last?.id == danglingID {
                AccountManager.shared.remove(danglingID)
            }
            // Refused by this device, not unreachable: the banner says so.
            if let change = IslandTrust.shared.change(forAddress: address) {
                trustChange = change
                return
            }
            validationError = "add_account.error".localized
            return
        }
        dismiss()
    }

    private func applyReset() async {
        switching = true
        defer { switching = false }
        validationError = nil
        // Same non-destructive add, targeting the default public server.
        let ok = await AppState.shared.addAccount(serverURL: Self.defaultServer)
        if !ok || AppState.shared.bootError != nil {
            if let danglingID = AccountManager.shared.activeAccountID,
               AccountManager.shared.accounts.last?.id == danglingID {
                AccountManager.shared.remove(danglingID)
            }
            validationError = "add_account.error".localized
            return
        }
        dismiss()
    }
}

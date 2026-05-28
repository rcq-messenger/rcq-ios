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

    private static let defaultServer = "https://api.rcq.app"

    private var trimmed: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValidURL: Bool {
        guard let url = URL(string: trimmed),
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
                Button("settings.network.custom_server.confirm.cta".localized,
                       role: .destructive) {
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
                Button("settings.network.custom_server.reset.cta".localized,
                       role: .destructive) {
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
                Text("settings.network.custom_server.invalid".localized)
                    .font(.caption2)
                    .foregroundColor(.red.opacity(0.85))
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
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
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
        customServer = trimmed
        // Keep AccountManager in sync with the new server URL on the
        // active account. AccountManager is authoritative under
        // multi-identity (S1+); without this the rcq.baseURL
        // UserDefaults set above would drift from Account[0].serverURL
        // and any UI reading the account roster would show the old
        // host. mirrorActiveToLegacy will harmonise both sides.
        if let activeID = AccountManager.shared.activeAccountID {
            AccountManager.shared.update(activeID, serverURL: trimmed)
        }
        // Burn the local account: the new server's user table has no
        // record of our UIN, so the next boot has to mint fresh
        // identity. burnAccount() wipes every local store + reruns
        // boot(), which reads APIClient.shared.baseURL fresh.
        await AppState.shared.burnAccount()
        dismiss()
    }

    private func applyReset() async {
        switching = true
        defer { switching = false }
        customServer = ""
        // Also reset Account[0].serverURL to the default. Mirror
        // takes care of clearing rcq.baseURL UserDefaults to match.
        if let activeID = AccountManager.shared.activeAccountID {
            AccountManager.shared.update(activeID, serverURL: "https://api.rcq.app")
        }
        await AppState.shared.burnAccount()
        dismiss()
    }
}

import SwiftUI

/// Local-only management surface for the account roster. Lets the
/// user delete accounts they no longer want on the device. The active
/// account can't be deleted from here — the user has to switch to a
/// different account first via the toolbar pill, then come back. This
/// keeps the data flow simple: every delete operates on a non-active
/// account whose stores aren't currently mounted by any singleton.
///
/// Server-side account stays alive. Deleting locally just wipes the
/// device's per-account Keychain entries, MessageDB SQLite file, and
/// libsignal stores; the server still knows the UIN exists and will
/// keep queueing offline messages for it (until they age out via the
/// queue TTL sweep on the backend). Users who want a full server-side
/// burn should switch to the account and use the existing destructive
/// flow in Privacy & Network.
struct ManageAccountsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var accountManager = AccountManager.shared

    @State private var pendingDelete: Account?
    @State private var showRestore = false

    private var sortedAccounts: [Account] {
        accountManager.accounts.sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                if sortedAccounts.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        VStack(spacing: 10) {
                            intro
                            if !accountManager.isAtAccountLimit {
                                addByPhraseButton
                            }
                            ForEach(sortedAccounts) { account in
                                row(for: account)
                            }
                            Spacer(minLength: 24)
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 8)
                    }
                }
            }
            .navigationTitle("manage_accounts.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".localized) { dismiss() }
                }
            }
            .confirmationDialog(
                deleteConfirmTitle,
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { account in
                Button(
                    "manage_accounts.delete.confirm.cta".localized,
                    role: .destructive
                ) {
                    Task { await performDelete(account) }
                }
                Button("common.cancel".localized, role: .cancel) {
                    pendingDelete = nil
                }
            } message: { _ in
                Text("manage_accounts.delete.confirm.body".localized)
            }
            .sheet(isPresented: $showRestore) {
                RestoreFromSeedView(onCompleted: { dismiss() })
            }
        }
    }

    /// Add an EXISTING account (one you already own elsewhere) to this device
    /// by typing its recovery phrase — registers it as a further local account
    /// and switches to it. Mirrors the Android "Add account by recovery phrase"
    /// entry; also reachable from the Add-account sheet.
    private var addByPhraseButton: some View {
        Button {
            showRestore = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "key.fill")
                    .foregroundColor(Theme.Color.accent)
                Text("manage_accounts.add_by_phrase".localized)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.Color.textPrimary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundColor(Theme.Color.textSecondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12).fill(Theme.Color.bgSecondary)
            )
        }
        .buttonStyle(.plain)
    }

    private var deleteConfirmTitle: String {
        guard let pendingDelete else { return "" }
        let label = displayLabel(for: pendingDelete)
        return String(
            format: "manage_accounts.delete.confirm.title".localized,
            label
        )
    }

    // MARK: - sections

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("manage_accounts.intro.title".localized)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.Color.textPrimary)
            Text("manage_accounts.intro.body".localized)
                .font(.callout)
                .foregroundColor(Theme.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 6)
    }

    private func row(for account: Account) -> some View {
        let isActive = account.id == accountManager.activeAccountID
        let uin = KeychainStore.string(KeychainStore.Keys.uin, forAccount: account.id)
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(displayLabel(for: account))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Theme.Color.textPrimary)
                    if isActive {
                        Text("manage_accounts.active_badge".localized)
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.8)
                            .foregroundColor(Theme.Color.accent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(Theme.Color.accent.opacity(0.15))
                            )
                    }
                }
                Text(account.displayHost)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(Theme.Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let uin {
                    Text(verbatim: "#\(uin)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(Theme.Color.textSecondary.opacity(0.7))
                }
            }
            Spacer(minLength: 8)
            if isActive {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(Theme.Color.accent)
            } else {
                Button {
                    pendingDelete = account
                } label: {
                    Text("manage_accounts.delete".localized)
                        .font(.system(.footnote, weight: .semibold))
                        .foregroundColor(.red.opacity(0.85))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            Capsule().fill(Color.red.opacity(0.10))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12).fill(Theme.Color.bgSecondary)
        )
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 32, weight: .light))
                .foregroundColor(Theme.Color.textSecondary.opacity(0.5))
            Text("manage_accounts.empty".localized)
                .font(.callout)
                .foregroundColor(Theme.Color.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - actions

    /// Best-effort human label for an account row. Falls back through
    /// the same three layers the switcher pill uses: explicit
    /// displayLabel → matching catalogue entry name → bare host.
    private func displayLabel(for account: Account) -> String {
        if let label = account.displayLabel, !label.isEmpty {
            return label
        }
        if let entry = ServerDirectoryService.shared.servers.first(where: { $0.url == account.serverURL }) {
            return entry.name
        }
        return account.displayHost
    }

    /// Wipe every per-account storage layer that holds this account's
    /// data on the device, then drop the account from the roster.
    /// Server-side identity (UIN, prekeys, queued offline messages)
    /// stays alive — the user can do a full server-side delete by
    /// switching to the account and using Burn account in Privacy &
    /// Network.
    private func performDelete(_ account: Account) async {
        defer { pendingDelete = nil }
        // Refuse to delete the active account — by precondition the
        // UI doesn't surface a delete button on that row, but
        // double-checking here keeps the contract honest if a future
        // caller bypasses the UI.
        guard account.id != accountManager.activeAccountID else { return }

        KeychainStore.wipeAccount(account.id)
        MessageDB.wipe(accountID: account.id)
        SignalProtocolDB.wipeFiles(accountID: account.id)
        accountManager.remove(account.id)
    }
}

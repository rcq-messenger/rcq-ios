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
    /// Bumped when a card is refilled below, so the rows redraw. The cards live
    /// in UserDefaults rather than in an observable object, and a row reads its
    /// own on every pass.
    @State private var cardRevision = 0

    /// ⚠⚠ Empty under duress, and this is the second lock, not the first: the
    /// row that opens this sheet is already hidden in a decoy session. A screen
    /// that hands out the real accounts — their numbers read straight from the
    /// Keychain, and a tap away from being switched to — is exactly what the
    /// decoy exists to make unreachable, so it refuses on its own account
    /// rather than trusting that nothing will ever present it again.
    private var sortedAccounts: [Account] {
        if PanicPINService.shared.isDecoy { return [] }
        return accountManager.accounts.sorted { $0.createdAt < $1.createdAt }
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
            .task { await fillMissingIslandCards() }
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

    /// Ask each island whose row has no logo version for its `/server/info`.
    ///
    /// A card is written while its account is ACTIVE, so a row for an island
    /// the person has not opened since the logo landed there draws the lettered
    /// tile forever, which is what "the logo does not come through in the
    /// account switcher" was. One small GET per such host fixes it without
    /// switching accounts. An island with no logo at all answers an empty
    /// version and is asked again next time this sheet opens, which is cheap
    /// and rare enough to leave as it is.
    ///
    /// ⚠ `IslandHTTP`, never `URLSession.shared`. The hosts here are islands
    /// the user holds an account on, and the shared session carries no proxy
    /// configuration: on a censored network this would be the one request that
    /// steps outside the tunnel the user deliberately engaged, handing that
    /// island a real IP.
    @MainActor
    private func fillMissingIslandCards() async {
        guard !PanicPINService.shared.isDecoy else { return }
        for account in sortedAccounts {
            let card = AccountCardCache.card(for: account.id)
            guard (card?.islandLogoVersion ?? "").isEmpty else { continue }
            let host = account.displayHost
            guard !host.isEmpty, let url = URL(string: "https://\(host)/server/info") else { continue }
            var req = URLRequest(url: url, timeoutInterval: 8)
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            guard let (data, resp) = try? await IslandHTTP.data(for: req),
                  let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let name = (obj["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let version = obj["logo_version"] as? String ?? ""
            guard !name.isEmpty || !version.isEmpty else { continue }
            // ⚠ The avatar rides along untouched. This card is complete enough
            // to take the `record` fast path, which OVERWRITES, and the face
            // was written by a different moment than this one.
            AccountCardCache.record(
                AccountCard(
                    islandName: name.isEmpty ? (card?.islandName ?? "") : name,
                    islandLogoVersion: version,
                    avatarMediaID: card?.avatarMediaID ?? "",
                    avatarMediaKey: card?.avatarMediaKey ?? "",
                    host: host,
                    uin: card?.uin,
                    nickname: card?.nickname ?? ""
                ),
                for: account.id
            )
            cardRevision += 1
        }
    }

    private func row(for account: Account) -> some View {
        let isActive = account.id == accountManager.activeAccountID
        // Read so the rows redraw when a card is refilled above.
        _ = cardRevision
        let card = AccountCardCache.card(for: account.id)
        // The card's UIN is a cache; the Keychain is the record. Prefer the
        // record and let the card answer only when the Keychain slot is empty
        // (an account whose per-account migration has not run).
        let uin = KeychainStore.string(KeychainStore.Keys.uin, forAccount: account.id)
            ?? card?.uin.map(String.init)
        let label = displayLabel(for: account)
        return HStack(alignment: .top, spacing: 12) {
            // The island's own face: its operator's logo when it set one, and
            // the tile generated from its name and host when it did not. This
            // screen listed accounts as three lines of grey text, and which
            // island a row belongs to is the thing it is FOR. The version comes
            // off that account's OWN card, never the active one's: a row for an
            // account on another island keeps that island's picture.
            // The account's own face, with the island it lives on as a badge
            // on the corner. This is a list of ACCOUNTS: the island was the
            // whole picture here, so two accounts on the same island were two
            // identical tiles, and the person had to read the number under
            // them to tell their own apart.
            ZStack(alignment: .bottomTrailing) {
                PersonAvatarView(
                    mediaID: (card?.avatarMediaID).flatMap { $0.isEmpty ? nil : $0 },
                    keyBase64: (card?.avatarMediaKey).flatMap { $0.isEmpty ? nil : $0 },
                    status: .offline,
                    host: account.displayHost,
                    size: 36,
                    showStatus: false,
                )
                IslandAvatarView(
                    name: label,
                    host: account.displayHost,
                    logoVersion: card?.islandLogoVersion ?? "",
                    size: 16
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16 * 0.28, style: .continuous)
                        .stroke(Theme.Color.bgPrimary, lineWidth: 1.5)
                )
                .offset(x: 3, y: 3)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(label)
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
                HStack(spacing: 6) {
                    if let uin {
                        Text(verbatim: "#\(uin)")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(Theme.Color.textSecondary.opacity(0.7))
                    }
                    // The name this account goes by on that island, off its own
                    // cached card. Nothing is fetched to draw it, which is the
                    // point: every row but the active one belongs to an island
                    // this process is not talking to.
                    if let nickname = card?.nickname, !nickname.isEmpty {
                        Text(nickname)
                            .font(.caption2)
                            .foregroundColor(Theme.Color.textSecondary.opacity(0.7))
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)
            // No checkmark on the active row: it sat in the slot where every
            // other row keeps an ACTION, so it read as a control that does
            // nothing, and it repeated the ACTIVE badge two lines above (#409).
            if !isActive {
                Button {
                    // Switching lived only in the account pill on the home
                    // screen, and the copy on this very sheet sent people there
                    // — from the screen called "manage accounts". The sheet is
                    // dismissed first because switching reboots the app around
                    // the new account.
                    let id = account.id
                    dismiss()
                    Task { await AppState.shared.switchToAccount(id) }
                } label: {
                    Text("manage_accounts.switch".localized)
                        .font(.system(.footnote, weight: .semibold))
                        .foregroundColor(Theme.Color.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Theme.Color.accent.opacity(0.12)))
                }
                .buttonStyle(.plain)
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

    /// Best-effort human label for an account row. Falls back through the same
    /// four layers the switcher pill uses: the island's own cached name (what
    /// its operator typed, served by `/server/info`) → explicit displayLabel →
    /// matching catalogue entry name → bare host.
    private func displayLabel(for account: Account) -> String {
        if let cached = AccountCardCache.card(for: account.id)?.islandName, !cached.isEmpty {
            return cached
        }
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
        // The switcher's cached card for this account goes with the rest of its
        // local state; leaving it behind would keep an island name and a
        // nickname on the device for an account that no longer exists.
        AccountCardCache.forget(account.id)
        accountManager.remove(account.id)
    }
}

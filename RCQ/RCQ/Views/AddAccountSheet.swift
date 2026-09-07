import SwiftUI

/// Add a new account on a different RCQ server alongside any
/// existing accounts. Non-destructive: leaves every existing account
/// (Keychain entries, MessageDB file, contact list, history) intact.
/// After successful add, the new account becomes active and the
/// main UI rebuilds against its data.
///
/// Distinct from `CustomServerSheet` (which is the destructive
/// burn-and-switch path for users who don't want the previous
/// account anymore) and from `ServerPickerSheet` (which runs at
/// onboarding before any account exists and writes
/// `rcq.baseURL` UserDefaults directly).
struct AddAccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @StateObject private var directory = ServerDirectoryService.shared

    @StateObject private var accountManager = AccountManager.shared
    @State private var query: String = ""
    /// Which card is up; the Use button acts on it.
    @State private var page: Int = 0
    /// The typed-address door. A sheet rather than a section, so this screen
    /// asks one question at a time.
    @State private var showManual = false
    @State private var customURL: String = ""
    @State private var customToken: String = ""
    /// The DOOR code for a closed island, not the network token above. See the
    /// note beside its field.
    @State private var customInvite: String = ""
    /// The typed address disagrees with what this device holds for that
    /// island (design §3): drawn as the banner under the field, nothing dialled.
    @State private var trustChange: IslandTrust.Change?
    @State private var adding: Bool = false
    @State private var error: String?
    @State private var showRestore: Bool = false

    private var filtered: [ServerEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return directory.servers }
        return directory.servers.filter { entry in
            entry.name.lowercased().contains(q)
                || entry.description.lowercased().contains(q)
                || entry.region.lowercased().contains(q)
                || entry.displayHost.lowercased().contains(q)
        }
    }

    private var customURLTrimmed: String {
        customURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var customTokenTrimmed: String {
        customToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The address with its `#fingerprint` taken off first (design §3):
    /// `URL.host` would drop the fragment without a word, and a fingerprint
    /// dropped silently is a pin the person believes they set and never did.
    private var customSplit: IslandTrust.Split { IslandTrust.splitAddress(customURLTrimmed) }

    /// The address this sheet would dial, with the scheme put back when there
    /// is none: `is2.rcq.app:8443#ab12…` is the form `install.sh` prints and
    /// the Settings row copies (design §3), and demanding `https://` refused
    /// the exact string we hand people. `IslandTrust.dialAddress` is the same
    /// parse the trust door uses, so the two cannot disagree.
    private var customDialAddress: String? {
        guard !customSplit.badFragment, let a = IslandTrust.dialAddress(customURLTrimmed),
              URL(string: a)?.scheme?.lowercased() == "https"
        else { return nil }
        return a
    }

    private var customURLValid: Bool { customDialAddress != nil }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                VStack(spacing: 0) {
                    headerBlock
                    if !adding {
                        // The same deck of islands the onboarding picker draws
                        // (`IslandCardView`). This sheet is the same question
                        // asked a second time -- which island -- and it was
                        // answering it with a different screen, a search field
                        // over grey rows, which is what the founder walked into
                        // on 24.08 expecting the cards.
                        if !directory.servers.isEmpty {
                            TabView(selection: $page) {
                                ForEach(Array(directory.servers.enumerated()), id: \.element.id) { index, entry in
                                    IslandCardView(entry: entry).tag(index)
                                }
                            }
                            .tabViewStyle(.page(indexDisplayMode: .always))
                            .indexViewStyle(.page(backgroundDisplayMode: .always))
                            .frame(maxHeight: .infinity)
                            // The dots sat right on the button. They belong with the deck
                            // they describe, not with the thing you press next.
                            .padding(.bottom, 10)
                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                let entry = directory.servers[min(page, directory.servers.count - 1)]
                                Task { await performAdd(serverURL: entry.url) }
                            } label: {
                                Text("island.use".localized)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .background(Capsule().fill(Theme.Color.accent))
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 18)
                        }
                        if directory.servers.isEmpty { emptyState }
                        // ⚠ ONE secondary under the primary, not a pair of
                        // squares beside each other. The two-button row plus
                        // the deck plus the dots left nothing any room: the
                        // island's own description ran under the page dots and
                        // the buttons sat on the home indicator (founder,
                        // 24.08). Signing in with a phrase is a different
                        // errand entirely, so it moves to the bar as a glyph,
                        // and what stays down here is the other half of the
                        // same question: this island, or one you type.
                        secondaryAction(
                            icon: "keyboard",
                            title: "island.manual_entry".localized,
                        ) { showManual = true }
                        .padding(.horizontal, 18)
                        .padding(.top, 10)
                        .padding(.bottom, 12)
                    } else {
                        loadingState
                    }
                }
            }
            .navigationTitle("add_account.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".localized) { dismiss() }
                        .disabled(adding)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { showRestore = true } label: { Image(systemName: "key.fill") }
                        .disabled(adding)
                        .accessibilityLabel("add_account.enter_phrase".localized)
                }
            }
            .task {
                await directory.refresh()
            }
            .sheet(isPresented: $showRestore) {
                RestoreFromSeedView(onCompleted: { dismiss() })
            }
            .sheet(isPresented: $showManual) {
                NavigationStack {
                    ZStack {
                        Theme.Color.bgPrimary.ignoresSafeArea()
                        ScrollView {
                            customURLBlock
                                .padding(.horizontal, 18)
                                .padding(.top, 8)
                        }
                    }
                    .navigationTitle("island.manual_entry".localized)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button { showManual = false } label: { Image(systemName: "xmark") }
                                .accessibilityLabel("common.cancel".localized)
                        }
                    }
                }
            }
        }
    }

    // MARK: - sections

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("add_account.intro.title".localized)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.Color.textPrimary)
            Text("add_account.intro.body".localized)
                .font(.callout)
                .foregroundColor(Theme.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(Theme.Color.textSecondary)
                .font(.system(size: 13, weight: .semibold))
            TextField("add_account.search".localized, text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(Theme.Color.textSecondary.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.Color.bgSecondary)
        .cornerRadius(10)
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }

    private func row(for entry: ServerEntry) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            Task { await performAdd(serverURL: entry.url) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Theme.Color.textPrimary)
                    Spacer(minLength: 8)
                    if !entry.region.isEmpty && entry.region != "—" {
                        Text(entry.region)
                            .font(.system(size: 10, weight: .bold))
                            .tracking(0.8)
                            .foregroundColor(Theme.Color.textSecondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Theme.Color.bgPrimary))
                    }
                }
                if !entry.description.isEmpty {
                    Text(entry.description)
                        .font(.caption)
                        .foregroundColor(Theme.Color.textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(entry.displayHost)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(Theme.Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                IslandEntryLine(host: entry.displayHost)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12).fill(Theme.Color.bgSecondary)
            )
        }
        .buttonStyle(.plain)
    }

    /// Optional manual URL entry below the catalogue. Useful when
    /// the user is adding a server that hasn't been listed in
    /// `rcq-messenger/rcq-servers` yet (e.g. a freshly self-hosted
    /// box, or a friend's private instance).
    private var customURLBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("add_account.custom.label".localized)
                .font(.caption2)
                .tracking(1.2)
                .foregroundColor(Theme.Color.textSecondary)
                .padding(.top, 8)
            HStack(spacing: 8) {
                TextField("add_account.custom.placeholder".localized, text: $customURL)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)
                    .font(.system(.callout, design: .monospaced))
                    .padding(12)
                    .background(Theme.Color.bgSecondary)
                    .cornerRadius(10)
                Button {
                    Task { await addCustom() }
                } label: {
                    Text("add_account.custom.cta".localized)
                        .font(.callout.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(
                            customURLValid ? Theme.Color.accent : Theme.Color.bgSecondary
                        )
                        .cornerRadius(10)
                }
                .disabled(!customURLValid)
            }
            // Optional masquerade token for self-host backends gated
            // behind a Caddy `X-RCQ-Auth` header. Empty for default
            // public backends. Operator distributes the token out of
            // band; we don't validate it here, the request just 404s
            // (decoy) if the token is wrong.
            TextField("add_account.custom.token".localized, text: $customToken)
                .autocorrectionDisabled(true)
                .textInputAutocapitalization(.never)
                .font(.system(.caption, design: .monospaced))
                .padding(10)
                .background(Theme.Color.bgSecondary)
                .cornerRadius(8)
            // ⚠⚠ A DIFFERENT CREDENTIAL FROM THE ONE ABOVE, and the two are
            // easy to confuse because both are pasted strings. The token above
            // is the NETWORK gate: it gets the request past a masquerading
            // Caddy, and without it the island serves a decoy page. This one is
            // the DOOR: a closed island refuses registration without it, and
            // the island is perfectly reachable either way.
            //
            // It is also the only way onto a closed island that is not ours
            // from an iPhone: Apple does not allow this app to sell entry to a
            // server we do not run, so the person buys on the operator's site
            // and brings the code here.
            TextField("add_account.custom.invite".localized, text: $customInvite)
                .autocorrectionDisabled(true)
                .textInputAutocapitalization(.never)
                .font(.system(.caption, design: .monospaced))
                .padding(10)
                .background(Theme.Color.bgSecondary)
                .cornerRadius(8)
            if !customURLTrimmed.isEmpty && !customURLValid {
                Text((customSplit.badFragment ? "island.trust.not_fingerprint" : "add_account.custom.invalid").localized)
                    .font(.caption2)
                    .foregroundColor(.red.opacity(0.85))
            }
            if let trustChange {
                IslandTrustChangedBanner(change: trustChange) {
                    // Chosen: the accepted value is on file now, the field is
                    // rewritten to agree with it, and the add the person asked
                    // for goes ahead against it.
                    customURL = trustChange.rewriting(customURLTrimmed)
                    self.trustChange = nil
                    Task { await addCustom() }
                }
                .cornerRadius(10)
            }
            if let error {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.red.opacity(0.85))
            }
        }
    }

    /// The manual address goes through the trust door (design §3) before
    /// anything is dialled: a fingerprint is pinned as typed, a bad one is an
    /// address error, one that disagrees with the record on file is the banner.
    private func addCustom() async {
        error = nil
        trustChange = nil
        switch IslandTrust.shared.admit(typed: customURLTrimmed) {
        case .notAFingerprint:
            error = "island.trust.not_fingerprint".localized
        case .caOnlyHost:
            error = "island.trust.ca_only".localized
        case .changed(let change):
            trustChange = change
        case .admitted(let address):
            await performAdd(
                serverURL: address,
                serverToken: customTokenTrimmed.isEmpty ? nil : customTokenTrimmed
            )
        }
    }

    /// One of the two doors under the deck: a glyph over a word, both halves
    /// the same size so neither reads as the main one.
    private func secondaryAction(
        icon: String,
        title: String,
        action: @escaping () -> Void,
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundColor(Theme.Color.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.Color.bgSecondary))
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .light))
                .foregroundColor(Theme.Color.textSecondary.opacity(0.5))
            Text("add_account.empty".localized)
                .font(.callout)
                .foregroundColor(Theme.Color.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView()
                .scaleEffect(1.2)
            Text("add_account.adding".localized)
                .font(.callout)
                .foregroundColor(Theme.Color.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - actions

    private func performAdd(serverURL: String, serverToken: String? = nil) async {
        // UI defence: AccountManager also refuses but we'd rather
        // not flash the loading state for a guaranteed-fail add.
        if accountManager.isAtAccountLimit {
            error = String(
                format: "add_account.limit".localized,
                AccountManager.maxAccounts
            )
            return
        }
        adding = true
        error = nil
        let ok = await appState.addAccount(
            serverURL: serverURL,
            serverToken: serverToken,
            invite: customInvite.trimmingCharacters(in: .whitespacesAndNewlines),
        )
        adding = false
        if !ok {
            error = String(
                format: "add_account.limit".localized,
                AccountManager.maxAccounts
            )
            return
        }
        if appState.bootError != nil {
            // Boot pipeline failed (network unreachable, server
            // refused registration, etc). Roll back: remove the
            // dangling account from the roster so the user lands
            // back on the previous active account untouched.
            if let danglingID = AccountManager.shared.activeAccountID,
               AccountManager.shared.accounts.last?.id == danglingID {
                AccountManager.shared.remove(danglingID)
            }
            // The island answered and this device refused its certificate:
            // that is the banner with both fingerprints, not "check your
            // network".
            if let change = IslandTrust.shared.change(forAddress: serverURL) {
                trustChange = change
                return
            }
            error = "add_account.error".localized
            return
        }
        dismiss()
    }
}


/// What an island charges to get in, under its address in the list.
///
/// ⚠ Asked of the ISLAND, not of the directory file. servers.json is edited by
/// hand and would be stale the day after an operator changed a price — and a
/// wrong price is worse than no price.
///
/// ⚠ NO LINK AND NO BUTTON, on purpose and permanently on this platform.
/// Apple's rules do not allow an app to point somebody at a purchase it does
/// not handle, and a price with a way to pay beside it is exactly the shape
/// that gets an app pulled. The price alone is a fact about an island, the
/// same as its region.
///
/// Nothing is drawn for an open island: a list full of "free" labels teaches
/// nobody anything.
private struct IslandEntryLine: View {
    let host: String
    @State private var line: String?

    var body: some View {
        Group {
            if let line {
                Text(line)
                    .font(.caption2)
                    .foregroundColor(Theme.Color.accent)
            }
        }
        .task(id: host) {
            guard let caps = await ServerInfoService.fetch(host: host)?.capabilities,
                  caps.closedIsland else { return }
            // ⚠⚠ A PRICE ONLY FOR OUR OWN ISLAND, and this is a rule about
            // Apple rather than about taste (founder, 2026-09-07).
            //
            // Entry to the flagship will be an in-app purchase, so naming its
            // price is naming the price of something this app sells. Entry to
            // somebody else's island is bought on their site, and an app that
            // merely DESCRIBES a purchase it does not handle is the shape that
            // froze WordPress's updates in August 2020 until Apple backed
            // down. We do not need to win that argument.
            //
            // "Closed club" still shows for every closed island: it is not a
            // price, it is the fact that tells a person they need a code, and
            // without it the island looks broken rather than private.
            let isOurs = RcqFederation.isFlagship(host)
            let cents = caps.entryPriceCents
            line = (isOurs && cents > 0)
                ? String(format: "island.entry.price".localized, Self.usd(cents))
                : "island.entry.closed".localized
        }
    }

    /// Whole dollars lose the ".00": a club that costs fifteen dollars should
    /// say fifteen dollars.
    private static func usd(_ cents: Int) -> String {
        cents % 100 == 0 ? "$\(cents / 100)" : String(format: "$%.2f", Double(cents) / 100)
    }
}

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
    /// Asking the island about its door, before anything is dialled. Its own
    /// flag rather than `adding`, because the toolbar's Close stays live
    /// through it: a probe is not a commitment and must not trap anybody.
    @State private var probing: Bool = false
    /// The island whose door turned out to be shut. Non-nil = the code sheet
    /// is up; setting it back to nil is the way out, and there is one.
    @State private var door: DoorRequest?
    @State private var error: String?
    @State private var showRestore: Bool = false

    /// One island waiting on a code, with what it already told us about itself
    /// so the sheet can draw its face without asking twice.
    private struct DoorRequest: Identifiable {
        let entry: ServerEntry
        let status: IslandDoorStatus
        var id: String { entry.url }
    }

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
                    if !adding && !probing {
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
                            // ⚠ The deck had NOWHERE to say why an add failed:
                            // `error` was drawn only inside the typed-address
                            // sheet, so a refusal from a card silently rolled
                            // the account back and left the person looking at
                            // the same deck wondering what had happened
                            // (founder, 06.09). Above the button, where the eye
                            // already is.
                            if let error {
                                Text(error)
                                    .font(.caption)
                                    .foregroundColor(.red.opacity(0.85))
                                    .multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.horizontal, 18)
                                    .padding(.bottom, 8)
                            }
                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                let entry = directory.servers[min(page, directory.servers.count - 1)]
                                Task { await use(entry) }
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
                        // ⚠ Two different waits, and they must not share a
                        // sentence: "registering on the island" over a probe
                        // that has created nothing would be a lie about what
                        // the app has already done on the person's behalf.
                        loadingState(probing ? "island.door.checking" : "add_account.adding")
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
            .sheet(item: $door) { request in
                IslandDoorSheet(entry: request.entry, status: request.status) { code in
                    door = nil
                    Task { await performAdd(serverURL: request.entry.url, invite: code) }
                } onCancel: {
                    // Back to the deck with nothing spent and no account made:
                    // the whole point of asking here rather than after a
                    // refusal that has already replaced the interface.
                    door = nil
                }
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

    private func loadingState(_ titleKey: String) -> some View {
        VStack(spacing: 14) {
            ProgressView()
                .scaleEffect(1.2)
            Text(titleKey.localized)
                .font(.callout)
                .foregroundColor(Theme.Color.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - actions

    /// ⚠⚠ ASK THE ISLAND ABOUT ITS DOOR BEFORE DIALLING IT.
    ///
    /// This button used to register straight away, so joining a closed island
    /// went: register, refused, the whole app replaced by the boot-error wall,
    /// type the code there. That wall belongs to whatever account is active
    /// when it is drawn — which, after the failed add rolled itself back, was
    /// no longer the island being joined — so the code was stashed against the
    /// wrong door, the person landed on an unrelated account, and the join only
    /// worked on a second run that spent the code left over from the first
    /// (founder, 06.09, points 4 and 6).
    ///
    /// `/server/info` is served to anybody with no account, so the question
    /// costs one request and answers itself before anything is created.
    private func use(_ entry: ServerEntry) async {
        error = nil
        probing = true
        let status = await IslandDoor.status(host: entry.displayHost)
        probing = false
        if let status, status.needsCode {
            door = DoorRequest(entry: entry, status: status)
            return
        }
        // An island that did not answer at all is still dialled. It may only
        // be reachable through the transport the add itself raises, and
        // refusing on our own guess would be a worse answer than the island's.
        await performAdd(serverURL: entry.url)
    }

    private func performAdd(serverURL: String, serverToken: String? = nil, invite: String? = nil) async {
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
        // ⚠ Read BEFORE the add, because `AccountManager.add` makes the new
        // account active on the spot. This is the id the rollback below puts
        // the person back on, and reading it afterwards would name the
        // dangling account instead.
        let previousActiveID = AccountManager.shared.activeAccountID
        let ok = await appState.addAccount(
            serverURL: serverURL,
            serverToken: serverToken,
            invite: invite ?? customInvite.trimmingCharacters(in: .whitespacesAndNewlines),
        )
        adding = false
        if !ok {
            error = String(
                format: "add_account.limit".localized,
                AccountManager.maxAccounts
            )
            return
        }
        if let failure = appState.bootError {
            // Boot pipeline failed (network unreachable, server refused
            // registration, etc). Undo the whole thing: the dangling account
            // goes, the account the person was on comes back and boots, and
            // the reason stays here on this sheet where they can read it.
            await appState.rollbackFailedAdd(previousActiveID: previousActiveID)
            // The island answered and this device refused its certificate:
            // that is the banner with both fingerprints, not "check your
            // network".
            if let change = IslandTrust.shared.change(forAddress: serverURL) {
                trustChange = change
                return
            }
            // The island's own refusal, read off the register error it threw
            // (`{"code": "invite_invalid"}` and friends). "Check the URL and
            // your network" is the wrong sentence to show somebody whose code
            // was simply the wrong one, and it was the only one we had.
            if failure.contains("invite_invalid") {
                error = "reg.invite.invalid".localized
            } else if failure.contains("invite_required") || failure.contains("entry_required") {
                error = "reg.invite.required".localized
            } else {
                error = "add_account.error".localized
            }
            return
        }
        dismiss()
    }
}


/// The three facts a join needs about an island before it registers anything.
///
/// Deliberately NOT nested inside `IslandDoor` below: that enum is main-actor
/// isolated because it owns a cache, and a view's `init` reads one of these
/// while it is still nonisolated.
struct IslandDoorStatus {
    /// Registration here will be refused without a code.
    let needsCode: Bool
    /// US cents; 0 when the island does not sell entry.
    let entryPriceCents: Int
    /// The island's own name, or "" when its operator never set one.
    let name: String
    let logoVersion: String
}

/// What an island says about its own DOOR, remembered for the life of the
/// process.
///
/// ⚠ Asked ONCE per island and shared by the two places that need the answer:
/// the badge under a card, and the Use button, which must know before it dials
/// whether to ask for a code. Without the shared answer the button would repeat
/// the round trip the card in front of it has already made, and the person
/// would wait for the same question twice.
///
/// ⚠ A miss is NOT remembered. An island that did not answer may be behind a
/// network this app has not raised its transport for yet, and caching "no" for
/// the life of the process would make it permanently unaskable.
@MainActor
enum IslandDoor {
    private static var cache: [String: IslandDoorStatus] = [:]

    static func cached(host: String) -> IslandDoorStatus? { cache[host.lowercased()] }

    static func status(host: String) async -> IslandDoorStatus? {
        if let hit = cache[host.lowercased()] { return hit }
        guard let info = await ServerInfoService.fetch(host: host) else { return nil }
        let status = IslandDoorStatus(
            needsCode: info.capabilities.needsAccessCode,
            entryPriceCents: info.capabilities.entryPriceCents,
            name: info.name,
            logoVersion: info.logoVersion ?? ""
        )
        cache[host.lowercased()] = status
        return status
    }
}

/// Whether an island is open or shut, and what it charges, under its name on
/// the card.
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
/// ⚠ THE OPEN ISLANDS SAY SO TOO NOW. This used to draw nothing for them, on
/// the reasoning that a column of "free" labels teaches nobody anything — true
/// of a list of rows, false of the deck, where a card carries one island and
/// silence there reads as "not loaded yet" rather than "open". The founder
/// asked for it in as many words (06.09, point 3): the carousel has to say
/// which islands you can simply walk into.
///
/// ⚠⚠ THIS PUTS ONE REQUEST ON EVERY ISLAND IN THE CATALOGUE the moment the
/// deck opens, including the ones somebody swipes past and never joins, which
/// is the exact cost `ServerEntry.logo` refuses to pay for a picture (it is
/// mirrored on rcq.app instead). The trade is accepted here and cannot be made
/// the same way: whether a door is open is a live fact about the island, and
/// mirroring it in a hand-edited catalogue file would be wrong the day after an
/// operator locked their door — and a card that says "open" about a shut island
/// is worse than a card that says nothing. `IslandDoor` makes it one request
/// per island per launch, not one per swipe.
struct IslandEntryLine: View {
    let host: String
    @State private var status: IslandDoorStatus?

    init(host: String) {
        self.host = host
        _status = State(initialValue: IslandDoor.cached(host: host))
    }

    var body: some View {
        Group {
            if let status {
                Text(label(for: status))
                    .font(.caption2)
                    .foregroundColor(status.needsCode ? Theme.Color.accent : Theme.Color.textSecondary)
            }
        }
        .task(id: host) {
            status = await IslandDoor.status(host: host)
        }
    }

    private func label(for status: IslandDoorStatus) -> String {
        guard status.needsCode else { return "island.entry.open".localized }
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
        let cents = status.entryPriceCents
        return (isOurs && cents > 0)
            ? String(format: "island.entry.price".localized, Self.usd(cents))
            : "island.entry.closed".localized
    }

    /// Whole dollars lose the ".00": a club that costs fifteen dollars should
    /// say fifteen dollars.
    private static func usd(_ cents: Int) -> String {
        cents % 100 == 0 ? "$\(cents / 100)" : String(format: "$%.2f", Double(cents) / 100)
    }
}

/// The door of a closed island, asked before anything is registered.
///
/// Shaped after `ServerJoinSheet`, which is this same moment reached from a
/// link: the island's own logo, its name, its host, one field, one button. It
/// used to be the boot-error wall in `RCQApp`, wearing a `.roundedBorder` field
/// and a `.borderedProminent` button — the only two system defaults left in the
/// app — with no cancel and no back on it at all (founder, 06.09, points 1 and
/// 2).
///
/// ⚠ A NavigationStack sheet rather than a `.medium` detent, and that is about
/// the keyboard: this screen has a text field, a detented sheet gives it no
/// room to scroll out from under the keyboard, and #867 is what that looks
/// like. The typed-address sheet in this same file is built the same way for
/// the same reason.
private struct IslandDoorSheet: View {
    let entry: ServerEntry
    let status: IslandDoorStatus
    /// The trimmed, non-empty code.
    let onJoin: (String) -> Void
    let onCancel: () -> Void

    @State private var code: String = ""

    private var trimmed: String { code.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 14) {
                        IslandAvatarView(
                            name: status.name.isEmpty ? entry.name : status.name,
                            host: entry.displayHost,
                            logoVersion: status.logoVersion,
                            size: 56
                        )
                        .padding(.top, 8)

                        Text(status.name.isEmpty ? entry.name : status.name)
                            .font(.title3.weight(.semibold))
                            .foregroundColor(Theme.Color.textPrimary)
                            .multilineTextAlignment(.center)

                        Text(entry.displayHost)
                            .font(.callout.weight(.medium))
                            .foregroundColor(Theme.Color.accent)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        IslandEntryLine(host: entry.displayHost)

                        Text("island.door.body".localized)
                            .font(.footnote)
                            .foregroundColor(Theme.Color.textSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 8)

                        TextField("reg.invite.label".localized, text: $code)
                            .autocorrectionDisabled(true)
                            .textInputAutocapitalization(.never)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundColor(Theme.Color.textPrimary)
                            .padding(12)
                            .background(Theme.Color.bgSecondary)
                            .cornerRadius(10)
                            .submitLabel(.join)
                            .onSubmit { if !trimmed.isEmpty { onJoin(trimmed) } }

                        Button {
                            onJoin(trimmed)
                        } label: {
                            Text("serverjoin.join".localized)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(
                                    Capsule().fill(
                                        trimmed.isEmpty ? Theme.Color.bgSecondary : Theme.Color.accent
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(trimmed.isEmpty)

                        // The second way out, next to the one in the bar: this
                        // is the screen the founder could not leave, so it says
                        // so twice.
                        Button("common.cancel".localized) { onCancel() }
                            .font(.callout)
                            .foregroundColor(Theme.Color.textSecondary)
                            .padding(.top, 2)
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("island.door.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel".localized) { onCancel() }
                }
            }
        }
    }
}

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Privacy pickers split out of `SettingsView` once the list grew
/// past four entries. All five tri-state policies (last-seen /
/// gender / group invites / trade offers / calls) load from
/// `/users/me/info` on appear and write through PUT `/users/me`
/// on change. Local defaults match the server's column defaults so
/// a render before the GET completes doesn't flicker through a
/// wrong-looking value.
struct PrivacySettingsView: View {
    // Two panes from one view: Settings opens it as either Privacy (visibility,
    // security, migration, HoF) or Network (server, proxy, obfuscation,
    // relays). Splitting the surfaces was a user request; keeping one struct
    // avoids duplicating the large shared state. Default .privacy preserves any
    // existing call site.
    enum Pane { case privacy, network }
    var pane: Pane = .privacy
    /// Row the Settings search sent us to (item 28). Scrolled into view and
    /// washed with accent for a moment once the sheet is up.
    var highlight: SettingsRow?

    @Environment(\.dismiss) private var dismiss

    /// The highlight while it is still showing; dropped on a timer so the wash
    /// fades instead of staying on the row for as long as the sheet is open.
    @State private var activeHighlight: SettingsRow?

    @State private var lastSeenVisibility: String = UserDefaults.standard.string(forKey: "rcq.privacy.lastSeen") ?? "everyone"
    @State private var relayCalls: Bool = CallPrivacy.alwaysRelay
    /// Same-island stranger quarantine - device-local like the relay switch:
    /// the mailbox itself stays open (sealed sender), this decides where THIS
    /// install puts a stranger's first message.
    @State private var strangersToRequests: Bool = StrangerQuarantine.shared.enabled
    /// Onion routing opt-in (M3, O5 experimental). Mirrors the per-device pref.
    @State private var onionOptIn: Bool = SingBoxTransport.onionOptIn
    /// Local-proxy transport (route through the user's own Tor/i2p). Exclusive of
    /// relays/onion — while on, the onion toggle is disabled.
    @State private var localProxy: Bool = SingBoxTransport.localProxyMode
    @State private var lpHost: String = SingBoxTransport.lpHost
    @State private var lpPort: String = String(SingBoxTransport.lpPort)
    @State private var lpType: String = SingBoxTransport.lpType
    @State private var lpTesting = false
    @State private var lpTestOk: Bool? = nil
    /// In-chat bridge sharing: relays a contact shared / the user imported.
    @State private var sharedRelays: [ContactRelayStore.Entry] = ContactRelayStore.shared.list()
    @State private var showRelayImport = false
    @State private var relayImportText = ""
    /// Only whether a paid key is present, never the key. The cabinet is where
    /// it can be read; a settings screen that prints it is one screenshot away
    /// from handing it over.
    @State private var hasRelayKey = BrokerRelayStore.shared.tenantKey != nil
    /// Set when a key was accepted: how many endpoints of their own it unlocked.
    /// Outside the import alert on purpose — that alert is gone by the time the
    /// broker answers, and a confirmation inside a dismissed sheet says nothing.
    @State private var relayKeyResult: Int?
    /// Why a key was refused, already localized.
    @State private var relayKeyError: String?
    /// Relay tag pending a delete confirmation (set by the trash button).
    @State private var relayPendingDelete: String? = nil
    @State private var hofOptIn: Bool = UserDefaults.standard.bool(forKey: "rcq.privacy.hofOptIn")
    /// Current HoF avatar as a data-URI (nil = none), plus a decoded preview
    /// image and the picker/busy state.
    @State private var hofAvatar: String? = nil
    @State private var hofPreview: UIImage? = nil
    @State private var showHofPicker: Bool = false
    @State private var hofBusy: Bool = false
    @State private var hofError: String? = nil
    @State private var gender: String = ""
    // Seed visibility pickers from the cached last-known values so they render
    // their real state instantly instead of snapping from the defaults when the
    // server load lands (the "ползунки едут на глазах" report). loadVisibility
    // reconciles + re-caches.
    @State private var genderVisibility: String = UserDefaults.standard.string(forKey: "rcq.privacy.genderVisibility") ?? "nobody"
    @State private var profileVisibility: String = UserDefaults.standard.string(forKey: "rcq.privacy.profileVisibility") ?? "everyone"
    /// Founder item 22: who may OPEN my card, as opposed to what they read
    /// once it is open. Device-local for now (see `ProfileCardPrivacy`), and
    /// written through to the island anyway so it is already there the day the
    /// column exists.
    @State private var profileCardPolicy: String = ProfileCardPrivacy.myPolicy
    @State private var groupInvitePolicy: String = UserDefaults.standard.string(forKey: "rcq.privacy.groupInvitePolicy") ?? "everyone"
    /// Mirrored to `@AppStorage("rcq.privacy.callPolicy")` so
    /// `ChatView` can gate the call-button affordance without
    /// re-fetching `/users/me/info` on every render.
    @State private var callPolicy: String = UserDefaults.standard.string(forKey: "rcq.privacy.callPolicy") ?? "everyone"
    @AppStorage("rcq.privacy.callPolicy") private var callPolicyCache: String = "everyone"
    /// Mirrored to `@AppStorage("rcq.privacy.readReceiptsVisibility")`
    /// so `MessageService.markRead` can suppress outbound receipts
    /// without re-fetching `/users/me/info` per read.
    @State private var readReceiptsVisibility: String = UserDefaults.standard.string(forKey: "rcq.privacy.readReceiptsVisibility") ?? "everyone"
    @State private var showMigrateConfirm = false
    @State private var migrating = false
    @State private var migrateError: String? = nil
    @AppStorage("rcq.privacy.readReceiptsVisibility") private var readReceiptsCache: String = "everyone"
    @State private var showPINSettings = false
    @State private var showProxyURL = false
    @State private var showDiagnostics = false
    @AppStorage("rcq.proxyURL") private var proxyURL: String = ""
    @AppStorage("rcq.autoProxyActive") private var autoProxyActive: Bool = false
    @AppStorage("rcq.singbox.autoDisabled") private var singboxAutoDisabled: Bool = false
    @AppStorage("rcq.baseURL") private var customServer: String = ""
    @State private var showCustomServer = false
    @State private var showManageAccounts = false
    @StateObject private var accountManager = AccountManager.shared
    @ObservedObject private var panicPIN = PanicPINService.shared

    private var pinConfigured: Bool { PanicPINService.shared.isConfigured }

    /// RCQ relays status label for the trailing slot on the
    /// PrivacySettingsView row: "Through relays" or "Direct". Reflects the
    /// actual connection state, not the legacy "always show Авто" placeholder.
    private var stealthStatusLabel: String {
        let trimmed = proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if autoProxyActive { return "settings.network.stealth.auto_on".localized }
        if singboxAutoDisabled { return "settings.network.stealth.off".localized }
        return "settings.network.stealth.direct".localized
    }

    // MARK: - search index
    //
    // ⚠ Both panes, in screen order. A row added below belongs here; the DEBUG
    // check in `SettingsSearchIndex` is what catches one that forgot.
    static let searchEntries: [SettingsSearchEntry] = [
        // Privacy pane
        .init(row: .profileVisibility, titleKey: "settings.privacy.profile",
              sectionKey: "settings.privacy", destination: .privacy),
        .init(row: .profileCard, titleKey: "settings.privacy.profile_card",
              sectionKey: "settings.privacy", destination: .privacy),
        .init(row: .lastSeen, titleKey: "settings.privacy.last_seen",
              sectionKey: "settings.privacy", destination: .privacy),
        .init(row: .relayCalls, titleKey: "settings.privacy.relay_calls",
              sectionKey: "settings.privacy", destination: .privacy),
        .init(row: .strangers, titleKey: "settings.privacy.strangers",
              sectionKey: "settings.privacy", destination: .privacy),
        .init(row: .genderVisibility, titleKey: "settings.privacy.gender_visible",
              sectionKey: "settings.privacy", destination: .privacy),
        .init(row: .groupInvites, titleKey: "settings.privacy.group_invites",
              sectionKey: "settings.privacy", destination: .privacy),
        .init(row: .callPolicy, titleKey: "settings.privacy.calls",
              sectionKey: "settings.privacy", destination: .privacy),
        .init(row: .readReceipts, titleKey: "settings.privacy.read_receipts",
              sectionKey: "settings.privacy", destination: .privacy),
        .init(row: .howItWorks, titleKey: "how.title",
              sectionKey: "settings.privacy", destination: .privacy),
        .init(row: .panicPIN, titleKey: "settings.panic_pin",
              sectionKey: "settings.privacy", destination: .privacy),
        .init(row: .migrate, titleKey: "settings.migrate",
              sectionKey: "settings.privacy", destination: .privacy),
        .init(row: .hallOfFame, titleKey: "settings.privacy.hof_opt_in",
              sectionKey: "settings.privacy", destination: .privacy),
        // Network pane
        .init(row: .accounts, titleKey: "settings.network.accounts",
              sectionKey: "settings.network", destination: .network),
        .init(row: .stealth, titleKey: "settings.network.stealth",
              sectionKey: "settings.network", destination: .network),
        .init(row: .onion, titleKey: "settings.network.onion",
              sectionKey: "settings.network", destination: .network),
        .init(row: .localProxy, titleKey: "settings.network.localproxy",
              sectionKey: "settings.network", destination: .network),
        .init(row: .customServer, titleKey: "settings.network.custom_server",
              sectionKey: "settings.network", destination: .network),
        .init(row: .diagnostics, titleKey: "settings.network.diag",
              sectionKey: "settings.network", destination: .network),
        .init(row: .sharedRelays, titleKey: "relay.shared.section",
              sectionKey: "settings.network", destination: .network),
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                ScrollViewReader { proxy in
                    Form {
                        // One Section per option so its footer (a per-
                        // policy explanation) docks directly under the
                        // picker instead of dumping all five descriptions
                        // in one bottom block. Reads top-down, no need to
                        // hunt for the right paragraph.
                      if pane == .privacy {
                        Section {
                            scopePicker(
                                title: "settings.privacy.profile".localized,
                                selection: $profileVisibility,
                                field: "profile_visibility"
                            )
                            .settingsSearchRow(.profileVisibility, highlight: activeHighlight)
                        } footer: {
                            Text("settings.privacy.profile.desc".localized)
                        }
                        .listRowBackground(Theme.Color.bgSecondary)
                        // Founder item 22, directly under its neighbour because the
                        // two are constantly confused: the row above decides what
                        // is READ once the card is open, this one decides whether
                        // the name is a link at all. The surfaces that hand a
                        // stranger that link are incidental - a reactions sheet, a
                        // sender name over a photo, a member roster - and nobody
                        // chose to appear on any of them.
                        Section {
                            scopePicker(
                                title: "settings.privacy.profile_card".localized,
                                selection: $profileCardPolicy,
                                field: "profile_card_policy"
                            )
                            .onChange(of: profileCardPolicy) { newValue in
                                // Mirror for the surfaces that ask while they draw.
                                ProfileCardPrivacy.myPolicy = newValue
                            }
                            .settingsSearchRow(.profileCard, highlight: activeHighlight)
                        } footer: {
                            // The "not in effect yet" footnote that used to sit
                            // here is gone: the island now keeps the value and
                            // publishes the per-viewer verdict, so the sentence
                            // had turned into the opposite of the truth. The
                            // description above is the whole story again.
                            Text("settings.privacy.profile_card.desc".localized)
                        }
                        .listRowBackground(Theme.Color.bgSecondary)
                        Section {
                            scopePicker(
                                title: "settings.privacy.last_seen".localized,
                                selection: $lastSeenVisibility,
                                field: "last_seen_visibility"
                            )
                            .settingsSearchRow(.lastSeen, highlight: activeHighlight)
                        } footer: {
                            Text("settings.privacy.last_seen.desc".localized)
                        }
                        .listRowBackground(Theme.Color.bgSecondary)
                        // Device-local, not a server policy: it decides what THIS
                        // phone puts in its own ICE candidates. Same switch and the
                        // same words as Android, because it is the same choice.
                        Section {
                            Toggle(isOn: $relayCalls) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("settings.privacy.relay_calls".localized)
                                        .foregroundColor(Theme.Color.textPrimary)
                                    Text("settings.privacy.relay_calls.desc".localized)
                                        .font(.caption2)
                                        .foregroundColor(Theme.Color.textSecondary)
                                }
                            }
                            .tint(Theme.Color.accent)
                            .onChange(of: relayCalls) { newValue in
                                CallPrivacy.alwaysRelay = newValue
                            }
                            .settingsSearchRow(.relayCalls, highlight: activeHighlight)
                        }
                        .listRowBackground(Theme.Color.bgSecondary)
                        // Opt-in stranger quarantine (web parity, founder-approved
                        // wording). Per-account on this device; default OFF.
                        Section {
                            Toggle(isOn: $strangersToRequests) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("settings.privacy.strangers".localized)
                                        .foregroundColor(Theme.Color.textPrimary)
                                    Text("settings.privacy.strangers.desc".localized)
                                        .font(.caption2)
                                        .foregroundColor(Theme.Color.textSecondary)
                                }
                            }
                            .tint(Theme.Color.accent)
                            .onChange(of: strangersToRequests) { newValue in
                                StrangerQuarantine.shared.enabled = newValue
                            }
                            .settingsSearchRow(.strangers, highlight: activeHighlight)
                        }
                        .listRowBackground(Theme.Color.bgSecondary)
                        // ⚠ "Visibility after leaving" (presence_persistent +
                        // presence_ttl_minutes) stood here and was removed on
                        // 2026-08-23. It never worked: this client only ever sent
                        // the flag, never the TTL, so the island read NULL as
                        // "forever"; and the island's window was anchored on
                        // last_seen, which the 25s heartbeat rewrites, so it
                        // restarted instead of burning down. The countdown the
                        // user saw was a purely local clock with nothing behind
                        // it. The columns are gone server-side and both keys are
                        // pinned false/null in every response.
                        Section {
                            scopePicker(
                                title: "settings.privacy.gender_visible".localized,
                                selection: $genderVisibility,
                                field: "gender_visibility"
                            )
                            .disabled(gender.isEmpty)
                            .settingsSearchRow(.genderVisibility, highlight: activeHighlight)
                        } footer: {
                            Text(gender.isEmpty
                                 ? "settings.privacy.gender_visible.desc.empty".localized
                                 : "settings.privacy.gender_visible.desc".localized)
                        }
                        .listRowBackground(Theme.Color.bgSecondary)
                        Section {
                            scopePicker(
                                title: "settings.privacy.group_invites".localized,
                                selection: $groupInvitePolicy,
                                field: "group_invite_policy"
                            )
                            .settingsSearchRow(.groupInvites, highlight: activeHighlight)
                        } footer: {
                            Text("settings.privacy.group_invites.desc".localized)
                        }
                        .listRowBackground(Theme.Color.bgSecondary)
                        Section {
                            scopePicker(
                                title: "settings.privacy.calls".localized,
                                selection: $callPolicy,
                                field: "call_policy"
                            )
                            .onChange(of: callPolicy) { newValue in
                                // Mirror to AppStorage so ChatView can
                                // hide its call buttons immediately,
                                // without waiting for a /users/me/info
                                // round-trip.
                                callPolicyCache = newValue
                            }
                            .settingsSearchRow(.callPolicy, highlight: activeHighlight)
                        } footer: {
                            Text("settings.privacy.calls.desc".localized)
                        }
                        .listRowBackground(Theme.Color.bgSecondary)
                        Section {
                            scopePicker(
                                title: "settings.privacy.read_receipts".localized,
                                selection: $readReceiptsVisibility,
                                field: "read_receipts_visibility"
                            )
                            .onChange(of: readReceiptsVisibility) { newValue in
                                // MessageService reads this on every
                                // markRead - mirror immediately so the
                                // gate flips without a round-trip.
                                readReceiptsCache = newValue
                            }
                            .settingsSearchRow(.readReceipts, highlight: activeHighlight)
                        } footer: {
                            Text("settings.privacy.read_receipts.desc".localized)
                        }
                        .listRowBackground(Theme.Color.bgSecondary)

                        howItWorksSection

                        securitySection
                        migrationSection
                        // Hall of Fame is a flagship-only surface - hidden on
                        // self-hosted islands (gated on the server's hall_of_fame
                        // capability, like the UIN shop).
                        if AppState.shared.serverCapabilities.hallOfFame {
                            hofSection   // #27: Hall of Fame at the very bottom (under migration)
                        }
                      }
                      if pane == .network {
                        networkSection
                        relaySharingSection
                      }
                    }
                    .scrollContentBackground(.hidden)
                    // The sheet has to be on screen before a scroll means
                    // anything, so the jump waits a beat rather than firing
                    // from `onAppear` into a list that has not laid out yet.
                    .onAppear {
                        guard let highlight else { return }
                        activeHighlight = highlight
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            withAnimation { proxy.scrollTo(highlight, anchor: .center) }
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.1) {
                            if activeHighlight == highlight {
                                withAnimation { activeHighlight = nil }
                            }
                        }
                    }
                }
            }
            .navigationTitle((pane == .network ? "settings.network" : "settings.privacy").localized)
            .navigationBarTitleDisplayMode(.inline)
            .alert(
                "relay.key.ok.title".localized,
                isPresented: Binding(
                    get: { relayKeyResult != nil },
                    set: { if !$0 { relayKeyResult = nil } }
                )
            ) {
                Button("common.ok".localized) { relayKeyResult = nil }
            } message: {
                Text(String(format: "relay.key.ok.body".localized, relayKeyResult ?? 0))
            }
            .alert(
                "relay.key.bad.title".localized,
                isPresented: Binding(
                    get: { relayKeyError != nil },
                    set: { if !$0 { relayKeyError = nil } }
                )
            ) {
                Button("common.ok".localized) { relayKeyError = nil }
            } message: {
                Text(relayKeyError ?? "")
            }
            .alert("relay.import.title".localized, isPresented: $showRelayImport) {
                TextField("relay.import.hint".localized, text: $relayImportText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                Button("relay.import.add".localized) {
                    // One field, two things people are handed; the decision
                    // lives in RelayInput so it is testable and identical to
                    // Android's.
                    switch RelayInput.classify(relayImportText) {
                    case .link(let r):
                        ContactRelayStore.shared.add(r, fromUin: 0, fromName: nil)
                        sharedRelays = ContactRelayStore.shared.list()
                    case .accessKey(let key):
                        // Only the broker can say whether the key is good, and
                        // asking it is this refresh — which also makes the
                        // endpoints appear now rather than at the next launch.
                        //
                        // ⚠ And the answer is WAITED FOR. This used to set the
                        // key and report success on the spot, so a string typed
                        // at random was accepted exactly like a real key. The
                        // broker says which it is now.
                        BrokerRelayStore.shared.setTenantKey(key)
                        Task {
                            await BrokerRelayStore.shared.refresh()
                            switch BrokerRelayStore.shared.keyVerdict {
                            case "ok":
                                hasRelayKey = true
                                relayKeyResult = BrokerRelayStore.shared.privateRelays().count
                            case "expired":
                                BrokerRelayStore.shared.setTenantKey(nil)
                                relayKeyError = "relay.key.expired".localized
                            default:
                                // Not ours: drop it rather than leave a dead key
                                // in place quietly failing forever.
                                BrokerRelayStore.shared.setTenantKey(nil)
                                relayKeyError = "relay.key.unknown".localized
                            }
                        }
                    case .unusable:
                        break
                    }
                    relayImportText = ""
                }
                Button("common.cancel".localized, role: .cancel) {}
            } message: {
                Text("relay.import.body".localized)
            }
            .confirmationDialog(
                "relay.shared.delete.title".localized,
                isPresented: Binding(
                    get: { relayPendingDelete != nil },
                    set: { if !$0 { relayPendingDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("relay.shared.delete.confirm".localized, role: .destructive) {
                    if let tag = relayPendingDelete {
                        ContactRelayStore.shared.remove(tag: tag)
                        sharedRelays = ContactRelayStore.shared.list()
                    }
                    relayPendingDelete = nil
                }
                Button("common.cancel".localized, role: .cancel) { relayPendingDelete = nil }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".localized) { dismiss() }
                }
            }
            .sheet(isPresented: $showPINSettings) { PINSettingsView() }
            .sheet(isPresented: $showProxyURL) { ProxyURLSheet() }
            .sheet(isPresented: $showCustomServer) { CustomServerSheet() }
            .sheet(isPresented: $showManageAccounts) { ManageAccountsSheet() }
            .sheet(isPresented: $showDiagnostics) { ConnectionDiagnosticsView() }
            .sheet(isPresented: $showHofPicker) {
                HofImagePicker { data, mime in
                    showHofPicker = false
                    guard let data, let mime else { return }
                    Task { await applyPickedHofImage(data: data, mime: mime) }
                }
            }
            .task { if pane == .privacy { await loadVisibility() } }
        }
    }

    // MARK: - moved sections (PIN / inventory / network / traffic / migration)

    /// Permanent, not an onboarding step. The three questions this answers
    /// arrive on the third day of using the app, by which time a first-run
    /// screen is long gone.
    @ViewBuilder
    private var howItWorksSection: some View {
        Section {
            NavigationLink {
                HowItWorksView()
            } label: {
                HStack {
                    Image(systemName: "questionmark.circle")
                        .foregroundColor(Theme.Color.accent)
                    Text("how.title".localized)
                        .foregroundColor(Theme.Color.textPrimary)
                }
            }
            .settingsSearchRow(.howItWorks, highlight: activeHighlight)
        } footer: {
            Text("how.footer.short".localized)
        }
        .listRowBackground(Theme.Color.bgSecondary)
    }

    @ViewBuilder
    private var securitySection: some View {
        // ⚠⚠ Shown in a decoy session TOO, and that is the whole point.
        //
        // Hiding it was the reasonable-looking move and it was backwards. The
        // person searching a phone is not a stranger to this app: they know it
        // has a panic PIN, they open Settings, and an account with no PIN row
        // at all is not an innocent account — it is an account that is not
        // running the software they are looking at. The absence WAS the tell
        // (founder's report).
        //
        // Nothing is given away by showing it. `isConfigured` reads the vault,
        // so it says "on" — true, and true of the PIN they just watched being
        // typed. The screen behind it was already written for exactly this: in
        // a decoy session `PINSettingsView` offers only a plausible change-PIN
        // (which re-seals the DECOY slot, never the real one) and auto-lock,
        // and hides every duress, biometric and remove row. Report #237 built
        // that; only the door was missing.
        Section {
            Button {
                showPINSettings = true
            } label: {
                HStack {
                    Image(systemName: "lock.shield.fill")
                        .foregroundColor(Theme.Color.accent)
                    Text("settings.panic_pin".localized)
                        .foregroundColor(Theme.Color.textPrimary)
                    Spacer()
                    Text(PanicPINService.shared.isConfigured
                         ? "settings.panic_pin.on".localized
                         : "settings.panic_pin.off".localized)
                        .font(.caption2)
                        .foregroundColor(Theme.Color.textSecondary)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundColor(Theme.Color.textSecondary)
                }
            }
            .settingsSearchRow(.panicPIN, highlight: activeHighlight)
        } footer: {
            Text("settings.panic_pin.footer".localized)
        }
        .listRowBackground(Theme.Color.bgSecondary)
        // No screen-protection row here. It was a pointer saying the setting had
        // moved into each chat (⋯ → Secure mode), which stopped being news a
        // long time ago and just took up a section.
    }

    private var networkSection: some View {
        Section {
            // ⚠⚠ Not under duress. The contact list already refuses to draw the
            // account switcher in a decoy session, for the reason written there:
            // a decoy identity is not in the roster and must not be able to
            // reach it. This row was the same door left open — worse, actually,
            // because the count alone answers the only question a decoy exists
            // to leave unanswered. It read "Accounts 3" beside a session that
            // is supposed to be someone's whole phone, and opened a list of the
            // real numbers, switchable.
            if !panicPIN.isDecoy {
                Button {
                    showManageAccounts = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "person.2.crop.square.stack")
                            .foregroundColor(Theme.Color.accent)
                            .frame(width: 24)
                        Text("settings.network.accounts".localized)
                            .foregroundColor(Theme.Color.textPrimary)
                        Spacer()
                        Text(String(accountManager.accounts.count))
                            .font(.caption2.monospaced())
                            .foregroundColor(Theme.Color.textSecondary)
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundColor(Theme.Color.textSecondary)
                    }
                }
                .settingsSearchRow(.accounts, highlight: activeHighlight)
            }
            Button {
                showProxyURL = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "eye.slash")
                        .foregroundColor(Theme.Color.accent)
                        .frame(width: 24)
                    Text("settings.network.stealth".localized)
                        .foregroundColor(Theme.Color.textPrimary)
                    Spacer()
                    Text(stealthStatusLabel)
                        .font(.caption2.monospaced())
                        .foregroundColor(Theme.Color.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundColor(Theme.Color.textSecondary)
                }
            }
            .settingsSearchRow(.stealth, highlight: activeHighlight)
            // Onion routing (M3, experimental). One switch for the user: turning
            // it on ALSO engages RCQ relays, because onion routes THROUGH them
            // and can't work without them.
            Toggle(isOn: $onionOptIn) {
                HStack(spacing: 12) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .foregroundColor(Theme.Color.accent)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.network.onion".localized)
                            .foregroundColor(Theme.Color.textPrimary)
                        Text("settings.network.onion.desc".localized)
                            .font(.caption2)
                            .foregroundColor(Theme.Color.textSecondary)
                    }
                }
            }
            .onChange(of: onionOptIn) { on in
                SingBoxTransport.setOnionOptIn(on)
                // Onion implies RCQ relays: engage them so this is the only
                // switch the user touches.
                if on, !SingBoxTransport.isEnabled {
                    Task { await SingBoxTransport.shared.setEnabled(true) }
                }
            }
            .disabled(localProxy)
            .settingsSearchRow(.onion, highlight: activeHighlight)
            // Local proxy: route everything through the user's OWN local Tor /
            // i2p SOCKS5/HTTP. Mutually exclusive with relays/onion.
            Toggle(isOn: $localProxy) {
                HStack(spacing: 12) {
                    Image(systemName: "lock.shield")
                        .foregroundColor(Theme.Color.accent)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.network.localproxy".localized)
                            .foregroundColor(Theme.Color.textPrimary)
                        Text("settings.network.localproxy.desc".localized)
                            .font(.caption2)
                            .foregroundColor(Theme.Color.textSecondary)
                    }
                }
            }
            .onChange(of: localProxy) { on in
                let port = Int(lpPort) ?? 9050
                if on, lpHost.trimmingCharacters(in: .whitespaces).isEmpty || !(1...65535).contains(port) {
                    localProxy = false
                    lpTestOk = false
                    return
                }
                if on { onionOptIn = false }
                Task { await SingBoxTransport.shared.setLocalProxyEnabled(on, host: lpHost, port: port, type: lpType) }
            }
            .settingsSearchRow(.localProxy, highlight: activeHighlight)
            if localProxy {
                HStack {
                    Text("settings.network.localproxy.host".localized)
                        .foregroundColor(Theme.Color.textSecondary)
                    Spacer()
                    TextField("127.0.0.1", text: $lpHost)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        // Persist on every edit (not only on the enable toggle), so a
                        // custom host/port survives leaving Settings. setLocalProxy is a
                        // bare UserDefaults write (no transport restart).
                        .onChange(of: lpHost) { v in
                            SingBoxTransport.setLocalProxy(host: v, port: Int(lpPort) ?? 9050, type: lpType)
                        }
                }
                HStack {
                    Text("settings.network.localproxy.port".localized)
                        .foregroundColor(Theme.Color.textSecondary)
                    Spacer()
                    TextField("9050", text: $lpPort)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numberPad)
                        .onChange(of: lpPort) { v in
                            if let p = Int(v), (1...65535).contains(p) {
                                SingBoxTransport.setLocalProxy(host: lpHost, port: p, type: lpType)
                            }
                        }
                }
                Picker("settings.network.localproxy.type".localized, selection: $lpType) {
                    Text("SOCKS5").tag("socks")
                    Text("HTTP").tag("http")
                }
                .onChange(of: lpType) { v in
                    SingBoxTransport.setLocalProxy(host: lpHost, port: Int(lpPort) ?? 9050, type: v)
                }
                Button {
                    let port = Int(lpPort) ?? 9050
                    lpTesting = true
                    lpTestOk = nil
                    Task {
                        let ok = await SingBoxTransport.testLocalProxy(host: lpHost, port: port, type: lpType)
                        await MainActor.run { lpTestOk = ok; lpTesting = false }
                    }
                } label: {
                    HStack {
                        Text("settings.network.localproxy.test".localized)
                            .foregroundColor(Theme.Color.accent)
                        Spacer()
                        if lpTesting {
                            ProgressView()
                        } else if let ok = lpTestOk {
                            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(ok ? Theme.Color.accent : Theme.Color.statusBusy)
                        }
                    }
                }
                .disabled(lpTesting)
                Text("settings.network.localproxy.hint".localized)
                    .font(.caption2)
                    .foregroundColor(Theme.Color.textSecondary)
            }
            Button {
                showCustomServer = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "server.rack")
                        .foregroundColor(Theme.Color.accent)
                        .frame(width: 24)
                    Text("settings.network.custom_server".localized)
                        .foregroundColor(Theme.Color.textPrimary)
                    Spacer()
                    Text(customServer.isEmpty
                         ? "settings.network.custom_server.default".localized
                         : customServer)
                        .font(.caption2.monospaced())
                        .foregroundColor(Theme.Color.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundColor(Theme.Color.textSecondary)
                }
            }
            .settingsSearchRow(.customServer, highlight: activeHighlight)
            Button {
                showDiagnostics = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "stethoscope")
                        .foregroundColor(Theme.Color.accent)
                        .frame(width: 24)
                    Text("settings.network.diag".localized)
                        .foregroundColor(Theme.Color.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundColor(Theme.Color.textSecondary)
                }
            }
            .settingsSearchRow(.diagnostics, highlight: activeHighlight)
        } header: {
            Text("settings.masking".localized)
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("settings.network.proxy.intro".localized)
                    .font(.caption2)
                RelayFAQLink()
            }
        }
        .listRowBackground(Theme.Color.bgSecondary)
    }

    /// Hall of Fame opt-in + avatar — pinned to the very bottom of the screen
    /// (#27), under migration, where it's least in the way.
    private var hofSection: some View {
        Section {
            Toggle(isOn: $hofOptIn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("settings.privacy.hof_opt_in".localized)
                        .foregroundColor(Theme.Color.textPrimary)
                    Text("settings.privacy.hof_opt_in.desc".localized)
                        .font(.caption2)
                        .foregroundColor(Theme.Color.textSecondary)
                }
            }
            .tint(Theme.Color.accent)
            .onChange(of: hofOptIn) { newValue in
                Task { await pushBoolField("hof_opt_in", newValue) }
            }
            .settingsSearchRow(.hallOfFame, highlight: activeHighlight)
            if hofOptIn {
                HStack(spacing: 12) {
                    hofAvatarPreview
                    VStack(alignment: .leading, spacing: 6) {
                        Button(hofAvatar == nil
                               ? "settings.privacy.hof_add_image".localized
                               : "settings.privacy.hof_change_image".localized) {
                            showHofPicker = true
                        }
                        .font(.callout)
                        .foregroundColor(Theme.Color.accent)
                        .disabled(hofBusy)
                        if hofAvatar != nil {
                            Button("settings.privacy.hof_remove_image".localized) {
                                Task { await setHofAvatar("") }
                            }
                            .font(.callout)
                            .foregroundColor(Theme.Color.textSecondary)
                            .disabled(hofBusy)
                        }
                    }
                    Spacer()
                    if hofBusy { ProgressView().scaleEffect(0.8) }
                }
                if let err = hofError {
                    Text(err).font(.caption2).foregroundColor(.red)
                }
            }
        }
        .listRowBackground(Theme.Color.bgSecondary)
    }

    /// In-chat bridge sharing: relays a contact handed you / you imported,
    /// augmenting the transport pool. See RCQ/docs/bridge-sharing-design.md.
    private var relaySharingSection: some View {
        Section {
            if sharedRelays.isEmpty {
                Text("relay.shared.empty".localized)
                    .font(.caption).foregroundColor(Theme.Color.textSecondary)
            } else {
                ForEach(sharedRelays, id: \.relay.tag) { e in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(e.relay.proto.rawValue.uppercased()) · \(e.relay.server):\(e.relay.port)")
                                .foregroundColor(Theme.Color.textPrimary)
                            Text(e.fromUin == 0
                                 ? "relay.shared.imported".localized
                                 : "\("relay.shared.from".localized) #\(e.fromUin)")
                                .font(.caption2).foregroundColor(Theme.Color.textSecondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            relayPendingDelete = e.relay.tag
                        } label: {
                            Image(systemName: "trash").foregroundColor(Theme.Color.statusBusy)
                        }
                        // Without this a Button inside a List row expands its
                        // hit target to the WHOLE row, so tapping anywhere on
                        // the relay deleted it (user report). Borderless keeps
                        // the tap on the trash glyph only.
                        .buttonStyle(.borderless)
                    }
                }
            }
            if hasRelayKey {
                HStack {
                    Text("relay.key.active".localized)
                        .foregroundColor(Theme.Color.textPrimary)
                    Spacer()
                    Button("relay.key.remove".localized) {
                        BrokerRelayStore.shared.setTenantKey(nil)
                        hasRelayKey = false
                        BrokerRelayStore.shared.refreshInBackground()
                    }
                    .font(.caption)
                    .foregroundColor(Theme.Color.accent)
                    // Same reason as the trash glyph above: a Button in a List
                    // row otherwise takes the whole row's hit area.
                    .buttonStyle(.borderless)
                }
            }
            Button {
                relayImportText = ""
                showRelayImport = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "plus.circle").foregroundColor(Theme.Color.accent).frame(width: 24)
                    Text("relay.import.title".localized).foregroundColor(Theme.Color.accent)
                }
            }
            .settingsSearchRow(.sharedRelays, highlight: activeHighlight)
        } header: {
            Text("relay.shared.section".localized)
        }
        .listRowBackground(Theme.Color.bgSecondary)
    }

    private var migrationSection: some View {
        Section {
            Button {
                showMigrateConfirm = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundColor(Theme.Color.accent)
                        .frame(width: 24)
                    Text("settings.migrate".localized)
                        .foregroundColor(Theme.Color.textPrimary)
                    Spacer()
                    if migrating {
                        ProgressView().scaleEffect(0.75)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundColor(Theme.Color.textSecondary)
                    }
                }
            }
            .disabled(migrating)
            .settingsSearchRow(.migrate, highlight: activeHighlight)
            if let migrateError {
                Text(migrateError)
                    .font(.caption2)
                    .foregroundColor(.red)
            }
        } header: {
            Text("settings.migrate.header".localized)
        } footer: {
            Text("settings.migrate.footer".localized)
        }
        .listRowBackground(Theme.Color.bgSecondary)
        .confirmationDialog(
            "settings.migrate.confirm.title".localized,
            isPresented: $showMigrateConfirm,
            titleVisibility: .visible
        ) {
            Button("settings.migrate.confirm.cta".localized, role: .destructive) {
                Task { await runMigrate() }
            }
            Button("common.cancel".localized, role: .cancel) { }
        } message: {
            Text("settings.migrate.confirm.body".localized)
        }
    }

    private func runMigrate() async {
        migrating = true
        migrateError = nil
        let result = await AppState.shared.migrateAccount()
        migrating = false
        switch result {
        case .success:
            dismiss()
        case .cooldown:
            migrateError = "settings.migrate.error.cooldown".localized
        case .taken, .other:
            if case .other(let msg) = result {
                migrateError = msg
            } else {
                migrateError = "settings.migrate.error.cooldown".localized
            }
        }
    }

    @ViewBuilder
    private func scopePicker(
        title: String,
        selection: Binding<String>,
        field: String,
    ) -> some View {
        Picker(selection: selection) {
            Text("settings.privacy.scope.everyone".localized).tag("everyone")
            Text("settings.privacy.scope.contacts".localized).tag("contacts")
            Text("settings.privacy.scope.nobody".localized).tag("nobody")
        } label: {
            Text(title).foregroundColor(Theme.Color.textPrimary)
        }
        .onChange(of: selection.wrappedValue) { newValue in
            Task { await pushField(field, newValue) }
        }
    }

    private func loadVisibility() async {
        // Seed from the per-account mirror first so the picker is right on the
        // first frame, then let the fetch below overwrite it. The mirror is
        // what the drawing surfaces read, so it must never be the stale half.
        if profileCardPolicy != ProfileCardPrivacy.myPolicy {
            profileCardPolicy = ProfileCardPrivacy.myPolicy
        }
        guard let uin = AuthService.shared.ownUIN else { return }
        do {
            let p: UserProfile = try await APIClient.shared.request("GET", "/users/\(uin)/info")
            // Cache each loaded value so the next open seeds the pickers instantly
            // (no flicker); the @State seeds above read these keys.
            let d = UserDefaults.standard
            if let v = p.lastSeenVisibility { lastSeenVisibility = v; d.set(v, forKey: "rcq.privacy.lastSeen") }
            if let v = p.genderVisibility { genderVisibility = v; d.set(v, forKey: "rcq.privacy.genderVisibility") }
            if let v = p.profileVisibility { profileVisibility = v; d.set(v, forKey: "rcq.privacy.profileVisibility") }
            if let v = p.groupInvitePolicy { groupInvitePolicy = v; d.set(v, forKey: "rcq.privacy.groupInvitePolicy") }
            if let v = p.callPolicy {
                callPolicy = v
                callPolicyCache = v
            }
            if let v = p.readReceiptsVisibility {
                readReceiptsVisibility = v
                readReceiptsCache = v
            }
            // Owner-only echo. The island is the source of truth: if this
            // device pushed a value that never landed (offline, or an island
            // too old for the field), the picker must snap back to what is
            // actually being enforced rather than keep showing the wish.
            if let v = p.profileCardPolicy {
                profileCardPolicy = v
                ProfileCardPrivacy.myPolicy = v
            }
            if let v = p.hofOptIn { hofOptIn = v; d.set(v, forKey: "rcq.privacy.hofOptIn") }
            hofAvatar = p.hofAvatar
            hofPreview = p.hofAvatar.flatMap(Self.decodeDataUri)
            gender = p.gender ?? ""
        } catch {
            // Soft-fail — the picker write paths still work, the
            // worst case is the displayed default doesn't match
            // the server until the user picks something.
        }
    }

    /// Boolean variant of `pushField` for toggles like `hof_opt_in`. The
    /// server's PUT /users/me handler treats missing keys as no-op so the
    /// partial payload is safe.
    private func pushBoolField(_ key: String, _ value: Bool) async {
        struct Body: Encodable {
            let key: String
            let value: Bool
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: DynamicKey.self)
                try c.encode(value, forKey: DynamicKey(stringValue: key)!)
            }
        }
        struct DynamicKey: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }
        do {
            let _: UserProfile = try await APIClient.shared.request(
                "PUT", "/users/me",
                body: Body(key: key, value: value)
            )
        } catch {
            // Soft-fail; user can re-toggle.
        }
    }

    private func pushField(_ key: String, _ value: String) async {
        struct Body: Encodable {
            let key: String
            let value: String
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: DynamicKey.self)
                try c.encode(value, forKey: DynamicKey(stringValue: key)!)
            }
        }
        struct DynamicKey: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }
        do {
            let _: UserProfile = try await APIClient.shared.request(
                "PUT", "/users/me",
                body: Body(key: key, value: value)
            )
        } catch {
            // Soft-fail; user can re-pick.
        }
    }

    // MARK: - Hall of Fame avatar

    @ViewBuilder private var hofAvatarPreview: some View {
        ZStack {
            Circle().fill(Theme.Color.accent.opacity(0.12))
            if let gif = hofGifData {
                // Animate a GIF avatar here too (#27) — it animates on the
                // public wall, so the settings preview shouldn't be frozen.
                AnimatedGIFView(data: gif, contentMode: .fill)
            } else if let img = hofPreview {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").foregroundColor(Theme.Color.textSecondary)
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(Circle())
    }

    /// Raw bytes of the HoF avatar when it's a GIF data-URI, else nil (so the
    /// preview can animate instead of showing a frozen first frame).
    private var hofGifData: Data? {
        guard let s = hofAvatar, s.hasPrefix("data:image/gif;base64,"),
              let r = s.range(of: ";base64,") else { return nil }
        return Data(base64Encoded: String(s[r.upperBound...]))
    }

    /// Normalize a picked image into a capped (~256KB) data-URI and upload it.
    /// A small animated GIF is kept raw so it still animates on the wall;
    /// anything else (or an oversized GIF) is downscaled + JPEG-compressed.
    private func applyPickedHofImage(data: Data, mime: String) async {
        hofBusy = true; hofError = nil
        let cap = 256 * 1024
        var finalData = data
        var finalMime = mime
        if !(mime == "image/gif" && data.count <= cap) {
            guard let img = UIImage(data: data) else {
                hofError = "settings.privacy.hof_image_error".localized; hofBusy = false; return
            }
            let scaled = Self.downscale(img, maxSide: 256)
            var jpeg: Data? = nil
            for q in [CGFloat(0.85), 0.7, 0.55, 0.4] {
                if let d = scaled.jpegData(compressionQuality: q), d.count <= cap { jpeg = d; break }
            }
            guard let j = jpeg else {
                hofError = "settings.privacy.hof_image_too_large".localized; hofBusy = false; return
            }
            finalData = j; finalMime = "image/jpeg"
        }
        let dataUri = "data:\(finalMime);base64,\(finalData.base64EncodedString())"
        if await putHofAvatar(dataUri) {
            hofAvatar = dataUri
            hofPreview = UIImage(data: finalData)
        } else {
            hofError = "settings.privacy.hof_image_error".localized
        }
        hofBusy = false
    }

    private func setHofAvatar(_ dataUri: String) async {
        hofBusy = true; hofError = nil
        if await putHofAvatar(dataUri) {
            hofAvatar = dataUri.isEmpty ? nil : dataUri
            hofPreview = dataUri.isEmpty ? nil : Self.decodeDataUri(dataUri)
        } else {
            hofError = "settings.privacy.hof_image_error".localized
        }
        hofBusy = false
    }

    private func putHofAvatar(_ value: String) async -> Bool {
        struct Body: Encodable {
            let v: String
            func encode(to e: Encoder) throws {
                var c = e.container(keyedBy: DynamicKey.self)
                try c.encode(v, forKey: DynamicKey(stringValue: "hof_avatar")!)
            }
        }
        struct DynamicKey: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }
        do {
            let _: UserProfile = try await APIClient.shared.request("PUT", "/users/me", body: Body(v: value))
            return true
        } catch {
            return false
        }
    }

    private static func downscale(_ img: UIImage, maxSide: CGFloat) -> UIImage {
        let longest = max(img.size.width, img.size.height)
        guard longest > maxSide else { return img }
        let f = maxSide / longest
        let size = CGSize(width: img.size.width * f, height: img.size.height * f)
        return UIGraphicsImageRenderer(size: size).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
    }

    static func decodeDataUri(_ s: String) -> UIImage? {
        guard let r = s.range(of: ";base64,") else { return nil }
        guard let data = Data(base64Encoded: String(s[r.upperBound...])) else { return nil }
        return UIImage(data: data)
    }
}

/// Who may OPEN my profile card (founder item 22). Straight port of the web
/// client's `lib/profile-card-privacy.ts` so the two agree key for key: the
/// island field is `profile_card_policy`, the tri-state is the same
/// everyone / contacts / nobody, and the device-local mirror is stored under
/// the same `privacy.profileCard` suffix the web scopes into localStorage.
///
/// The complaint behind it: a card is reachable from surfaces nobody chose to
/// appear on. React to a message in a group and your name lands in the "who
/// reacted" sheet; send a photo and your name sits over it in the viewer; join
/// anything and you are a row in a member list. Every one of those names is a
/// link, so being in a room is enough for a stranger to read your card.
///
/// This is NOT `profile_visibility`, which blanks the optional FIELDS (city,
/// age, about, ...) for outsiders and still lets the card open on an empty
/// card. Item 22 is about the tap itself.
///
/// ⚠⚠ WHERE THE ENFORCEMENT ACTUALLY LIVES. A flag on my phone cannot stop a
/// remote user from opening my card: the stranger tapping my name is running
/// THEIR client, which never reads my `UserDefaults`. So the local mirror is a
/// cache for drawing THIS screen, never the enforcement. Both server halves
/// now exist:
///   1. a `profile_card_policy` column, gating `GET /users/{uin}/info` the way
///      `last_seen_visibility` already gates the timestamp. A card that may not
///      be opened degrades to the identity floor (uin, nickname, keys, avatar)
///      rather than 403, because a 403 would take `identity_key` with it and
///      the setting promises the shut-out person can still write to you; and
///   2. a per-viewer verdict published next to every row that carries a name -
///      `profile_openable`, the twin of the existing `callable` - so this
///      client knows not to draw the link in the first place.
/// `canOpenCard` still fails OPEN on a nil verdict, because a name that
/// silently stops being tappable reads as a broken screen, an island may be
/// older than the field, and the fan-out frames cannot carry a per-viewer
/// answer at all. Failing open costs nothing: the island already withheld the
/// contents, so the worst case is a card opened onto its identity floor.
enum ProfileCardPrivacy {
    /// Same suffix as the web's `scopedKey('privacy.profileCard')`.
    ///
    /// ⚠ Scoped PER ACCOUNT, unlike `rcq.privacy.callPolicy` and
    /// `rcq.privacy.readReceiptsVisibility`, which are flat keys reseeded from
    /// the server on every open. This one is read by surfaces that draw before
    /// any fetch completes, so a flat key would let account A's choice paint
    /// account B's screen for the first frame. It reconciles against
    /// `UserProfile.profileCardPolicy` in `loadVisibility`; the island is the
    /// source of truth and this is only the seed.
    private static let legacyKey = "rcq.privacy.profileCard"

    /// The active account's key. Falls back to the flat one before any account
    /// exists (fresh install, first-run screens).
    static var defaultsKey: String {
        guard let id = AppGroup.readActiveAccountID() else { return legacyKey }
        return "\(legacyKey).\(id.uuidString)"
    }

    /// My own setting. Defaults to "everyone", matching the server default for
    /// the profile gates: a fresh account is not silently unreachable.
    static var myPolicy: String {
        get {
            let d = UserDefaults.standard
            let key = defaultsKey
            // One-time move of a pre-scoping value onto whichever account is
            // open when this first runs. On the ordinary one-account device
            // that is the account that chose it; a device that already had two
            // gets one wrong assignment instead of a silent reset to the
            // permissive default, and either way the flag enforces nothing yet.
            if key != legacyKey, d.string(forKey: key) == nil,
               let inherited = d.string(forKey: legacyKey) {
                d.set(inherited, forKey: key)
                d.removeObject(forKey: legacyKey)
            }
            return coerce(d.string(forKey: key)) ?? "everyone"
        }
        set { UserDefaults.standard.set(coerce(newValue) ?? "everyone", forKey: defaultsKey) }
    }

    private static func coerce(_ raw: String?) -> String? {
        switch raw {
        case "everyone", "contacts", "nobody": return raw
        default: return nil
        }
    }

    /// May this client turn the subject's name into a link to their card?
    ///
    /// Every argument is optional on purpose: these rows come from four
    /// different endpoints and none of them is guaranteed to carry any of it.
    /// - `openable`: the island's verdict for THIS viewer, once it publishes
    ///   one. Wins outright when present.
    /// - `policy`: the raw tri-state. Only ever echoed to the owner, so in
    ///   practice this is set only when the subject is me.
    ///
    /// ⚠ Fails OPEN on anything it does not know.
    static func canOpenCard(
        uin: Int?,
        openable: Bool? = nil,
        policy: String? = nil,
        myUIN: Int? = nil,
        isContact: Bool = false
    ) -> Bool {
        // My own card is always mine to open, whatever I told the island.
        if let uin, let myUIN, uin == myUIN { return true }
        if let openable { return openable }
        switch coerce(policy) {
        case "nobody": return false
        case "contacts": return isContact
        default: return true
        }
    }

    /// The island's verdict for a bare UIN, for the three surfaces that have
    /// nothing else: a reaction row, a sender name over a photo, and an
    /// `rcq://member/<uin>` mention. None of them carries anything but the
    /// number, so the answer has to be looked up in whatever roster this
    /// client already holds.
    ///
    /// Contacts first, then group rosters. Both come from the island computed
    /// FOR THIS VIEWER, so they agree; the contact row is preferred only
    /// because it is the smaller and more frequently refreshed list.
    ///
    /// ⚠ Returns nil when nothing is known, which `canOpenCard` treats as
    /// "open". That is the same fail-open every caller already had, and it is
    /// the honest answer: a group we have not loaded a roster for cannot be
    /// consulted, and guessing "closed" would grey out a name for a person who
    /// never asked for that.
    @MainActor
    static func verdict(for uin: Int) -> Bool? {
        if let c = ContactService.shared.contacts.first(where: { $0.uin == uin }),
           let v = c.profileOpenable {
            return v
        }
        for g in GroupService.shared.groups {
            if let m = g.members.first(where: { $0.uin == uin }), let v = m.profileOpenable {
                return v
            }
        }
        return nil
    }
}

/// One-time scrub of everything "visibility after leaving" left on the device
/// when the feature was removed (2026-08-23).
///
/// Removing the switch is not enough on an install that had it ON. Two things
/// outlive the UI: the seed cache the Privacy screen used to read, and the
/// countdown anchor (`rcq.presenceWindow.<uin>`) that the contact-list header
/// still ticks off for up to 24 hours. Neither has anything behind it any
/// more, so both go on the first launch that reaches Settings.
///
/// ⚠ Deliberately written against the RAW keys instead of calling
/// `PresenceWindow.clear` - the anchor's owner lives in `ContactListView` and
/// is due for deletion with the chip itself, and this scrub must not be what
/// breaks that build.
enum PresenceRemovalCleanup {
    private static let doneKey = "rcq.cleanup.presenceRemoved"
    private static let anchorPrefix = "rcq.presenceWindow."

    static func runOnce() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: doneKey) else { return }
        d.removeObject(forKey: "rcq.privacy.presencePersistent")
        d.removeObject(forKey: "rcq.privacy.presenceTTL")
        // Keyed by UIN, so every account that ever ran on this device has one.
        for key in d.dictionaryRepresentation().keys where key.hasPrefix(anchorPrefix) {
            d.removeObject(forKey: key)
        }
        d.set(true, forKey: doneKey)
    }
}

/// PHPicker that hands back the picked image as RAW data + mime, so an animated
/// GIF survives (loading it as a UIImage would flatten it). The caller caps and
/// normalizes. One image, current representation.
private struct HofImagePicker: UIViewControllerRepresentable {
    let onPick: (Data?, String?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var cfg = PHPickerConfiguration(photoLibrary: .shared())
        cfg.filter = .images
        cfg.selectionLimit = 1
        cfg.preferredAssetRepresentationMode = .current
        let p = PHPickerViewController(configuration: cfg)
        p.delegate = context.coordinator
        return p
    }

    func updateUIViewController(_ vc: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: (Data?, String?) -> Void
        init(onPick: @escaping (Data?, String?) -> Void) { self.onPick = onPick }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let item = results.first?.itemProvider else { onPick(nil, nil); return }
            if item.hasItemConformingToTypeIdentifier(UTType.gif.identifier) {
                item.loadDataRepresentation(forTypeIdentifier: UTType.gif.identifier) { data, _ in
                    DispatchQueue.main.async { self.onPick(data, data == nil ? nil : "image/gif") }
                }
            } else if item.canLoadObject(ofClass: UIImage.self) {
                item.loadObject(ofClass: UIImage.self) { obj, _ in
                    let data = (obj as? UIImage)?.jpegData(compressionQuality: 0.9)
                    DispatchQueue.main.async { self.onPick(data, data == nil ? nil : "image/jpeg") }
                }
            } else {
                DispatchQueue.main.async { self.onPick(nil, nil) }
            }
        }
    }
}

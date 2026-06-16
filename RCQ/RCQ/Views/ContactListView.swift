import SwiftUI

struct ContactListView: View {
    @StateObject private var vm = ContactListViewModel()
    @StateObject private var auth = AuthService.shared
    @StateObject private var presence = PresenceService.shared
    @StateObject private var sound = SoundService.shared
    @StateObject private var groups = GroupService.shared
    @StateObject private var audioRooms = AudioRoomService.shared
    @StateObject private var favorites = FavoritesStore.shared
    @StateObject private var archive = ArchiveStore.shared

    @StateObject private var appState = AppState.shared
    @StateObject private var stories = StoryService.shared
    @StateObject private var news = NewsService.shared
    @StateObject private var accountManager = AccountManager.shared
    // Variant A: held cross-island "message requests" count into the pending
    // banner — without it a cross-island request was invisible (no entry point).
    @ObservedObject private var ciRequests = CrossIslandRequestsStore.shared
    @ObservedObject private var socket = WebSocketService.shared
    // Cross-island contacts render from the store directly: the merged
    // ContactService list drops them when a same-uin LOCAL contact exists.
    @ObservedObject private var ciStore = CrossIslandStore.shared
    @State private var collapsedCrossIsland = false

    @State private var showAddContact = false
    @State private var showAddAccount = false
    @State private var showManageAccounts = false
    @State private var showProfile = false
    @State private var showPending = false
    @State private var showSettings = false
    @State private var showCreateGroup = false
    @State private var showAudioRoomSheet = false
    @State private var collapsedAudioRooms = false
    @State private var rotateKeyConfirmRoom: AudioRoom?
    @State private var showNearby = false
    @State private var showRandom = false
    @State private var showQR = false
    @State private var showSearch = false
    @State private var collapsedGroups = false
    @State private var previewTarget: ChatTarget?
    /// `"peer:<uin>"` / `"group:<id>"` — drives the press-down scale on the active row.
    @State private var pressedRowID: String?
    @State private var showStoryComposer = false
    @State private var showNews = false
    @State private var showOutgoing = false
    @State private var showDiagnostics = false
    @State private var showPresenceInfo = false
    @State private var storyViewerGroupIndex: StoryViewerWrapper?
    @State private var collapsedFavorites = false
    @State private var collapsedArchive = true
    @State private var archiveUnlocked = false
    @State private var showArchivePINGate = false
    @State private var path = NavigationPath()
    @State private var deepLinkAddUIN: Int? = nil
    /// Island host from the contact link's `?h=` (spec §5); nil = same island.
    @State private var deepLinkAddHost: String? = nil
    @State private var deepLinkProfileUIN: DeepLinkUIN? = nil
    @State private var showStealthInfo: Bool = false
    @State private var refreshAttemptedFor: Set<Int> = []
    @State private var reportContact: Contact?
    @AppStorage("rcq.singbox.activePort") private var singboxActivePort: Int = 0

    var body: some View {
        // Preview overlay must sit at the root so it can cover the bottom safeAreaInset bar.
        ZStack {
            navigationStackBody
            if let pt = previewTarget {
                ContactPreviewOverlay(
                    target: pt,
                    actions: previewActions(for: pt),
                    onDismiss: {
                        withAnimation(.easeOut(duration: 0.14)) {
                            previewTarget = nil
                        }
                    }
                )
                .ignoresSafeArea()
                .zIndex(200)
            }
        }
    }

    private var navigationStackBody: some View {
        NavigationStack(path: $path) {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                // Optional home wallpaper (separate from the chat one). Behind
                // the list; no-op on the default. (Android parity.)
                ChatBackgroundView(home: true).ignoresSafeArea()
                list
                if showSearch {
                    SearchOverlay(
                        onClose: {
                            withAnimation(.easeInOut(duration: 0.18)) { showSearch = false }
                        },
                        onSelectContact: { contact in
                            withAnimation(.easeInOut(duration: 0.18)) { showSearch = false }
                            path.append(contact)
                        },
                        onSelectGroup: { group in
                            withAnimation(.easeInOut(duration: 0.18)) { showSearch = false }
                            path.append(group)
                        }
                    )
                    .transition(.opacity)
                    .zIndex(100)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    accountSwitcherPill
                }
                ToolbarItem(placement: .principal) {
                    identityPrincipal
                }
                // One HStack collapses iOS 26's two-pill spacing into a single capsule.
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 8) {
                        // Operator can hide Stories via the admin console (Features).
                        if appState.serverCapabilities.stories {
                            ownStoryButton
                        }
                        contactListMenu
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomBar
            }
            // CallMinimizedBar sits above the topBar inset so it
            // claims the very top row when a minimized call is
            // active. Has to live inside the NavigationStack root
            // (rather than on RCQApp's RootView) because SwiftUI
            // does not pass parent insets through to push'd
            // destinations — see ChatView for the matching call.
            .callMinimizedBarInset()
            .navigationDestination(for: Contact.self) { contact in
                ChatView(target: .peer(contact))
            }
            .navigationDestination(for: RCQGroup.self) { group in
                ChatView(target: .group(group))
            }
            .sheet(isPresented: $showAddContact) {
                AddContactView(onSelectGroup: { group in
                    showAddContact = false
                    path.append(group)
                })
                // Open compact (~half-screen) — typical case is "type
                // a UIN, tap one row, done". Drag indicator + .large
                // detent let the user pull it up if they want a wider
                // search results area.
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .sheet(item: Binding(
                get: { deepLinkAddUIN.map { DeepLinkUIN(uin: $0) } },
                set: { deepLinkAddUIN = $0?.uin }
            )) { wrap in
                AddContactView(prefillUIN: wrap.uin, prefillHost: deepLinkAddHost)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showProfile) { ProfileView() }
            .sheet(isPresented: $showPending) { PendingRequestsView() }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showAddAccount) { AddAccountSheet() }
            .sheet(isPresented: $showManageAccounts) { ManageAccountsSheet() }
            .sheet(isPresented: $showArchivePINGate) {
                PINVerifySheet(title: "pin_verify.title.archive".localized) {
                    archiveUnlocked = true
                    collapsedArchive = false
                }
            }
            // fullScreenCover (vs .sheet) avoids inner PhotoPicker dismiss bubbling up and closing the chat.
            .fullScreenCover(isPresented: $showRandom) { RandomChatView() }
            .background(storiesCoverHost)
            .sheet(isPresented: $showNearby) { NearbyView() }
            .sheet(isPresented: $showQR) { QRSheet() }
            .sheet(isPresented: $showCreateGroup) {
                CreateGroupView { group in
                    showCreateGroup = false
                    path.append(group)
                }
            }
            .sheet(isPresented: $showAudioRoomSheet) {
                CreateOrJoinAudioRoomSheet { room in
                    audioRooms.enter(room: room)
                }
            }
            .alert("audio_room.alert.cant_join.title".localized, isPresented: Binding(
                get: { audioRooms.lastJoinError != nil },
                set: { if !$0 { audioRooms.acknowledgeJoinError() } }
            ), actions: {
                Button("OK") { audioRooms.acknowledgeJoinError() }
            }, message: {
                Text(audioRooms.lastJoinError ?? "")
            })
            .confirmationDialog(
                "audio_room.rotate.confirm.title".localized,
                isPresented: Binding(
                    get: { rotateKeyConfirmRoom != nil },
                    set: { if !$0 { rotateKeyConfirmRoom = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("audio_room.rotate.confirm.do".localized, role: .destructive) {
                    if let room = rotateKeyConfirmRoom {
                        Task { await audioRooms.rotateKey(roomID: room.id) }
                    }
                    rotateKeyConfirmRoom = nil
                }
                Button("common.cancel".localized, role: .cancel) {
                    rotateKeyConfirmRoom = nil
                }
            } message: {
                Text("audio_room.rotate.confirm.body".localized)
            }
            .sheet(item: $reportContact) { contact in
                ReportContactSheet(
                    targetUIN: contact.uin,
                    targetNickname: contact.nickname
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .task {
                await vm.refresh()
                await groups.refresh()
                await audioRooms.refresh()
                await stories.refresh()
                await news.refresh()
                if appState.pendingOpenPending {
                    showPending = true
                    appState.pendingOpenPending = false
                }
                // Cold-launch push-tap navigation: didReceive sets
                // pendingOpenChatUIN before this view mounts, so the
                // initial value never triggers `.onChange`. Manually
                // try once on first appear; the existing onChange
                // handlers cover hot-launch and contact-list updates.
                if appState.pendingOpenChatUIN != nil {
                    tryOpenPendingChat()
                }
                if appState.pendingOpenGroupID != nil {
                    tryOpenPendingGroup()
                }
            }
            .sheet(isPresented: $showNews) {
                NewsSheet()
            }
            .sheet(isPresented: $showOutgoing) {
                OutgoingRequestsView()
            }
            .sheet(isPresented: $showDiagnostics) { ConnectionDiagnosticsView() }
            .alert("presence.info.title".localized, isPresented: $showPresenceInfo) {
                Button("common.ok".localized, role: .cancel) {}
            } message: {
                Text("presence.info.body".localized)
            }
            .sheet(item: Binding(
                get: { appState.pendingJoinGroupID.map(JoinGroupTrigger.init) },
                set: { newValue in appState.pendingJoinGroupID = newValue?.id }
            )) { trigger in
                GroupJoinSheet(
                    groupID: trigger.id,
                    host: appState.pendingJoinGroupHost,
                    onJoined: { joined in
                        // After a successful join, refresh local groups
                        // and route the user straight into the group chat.
                        Task { @MainActor in
                            groups.upsert(joined)
                            appState.pendingJoinGroupHost = nil
                            appState.pendingOpenGroupID = joined.id
                            tryOpenPendingGroup()
                        }
                    },
                    onOpenOwner: { ownerUIN in
                        // Owner tap reuses the global profile-preview
                        // path — same affordance as a nickname tap
                        // anywhere else in the app.
                        appState.pendingJoinGroupID = nil
                        appState.pendingJoinGroupHost = nil
                        deepLinkProfileUIN = DeepLinkUIN(uin: ownerUIN)
                    },
                )
                .presentationDetents([.medium, .large])
            }
            .sheet(item: $appState.pendingServerJoin) { req in
                ServerJoinSheet(request: req, onJoined: { appState.pendingServerJoin = nil })
            }
            .sheet(item: $appState.pendingWebLink) { req in
                WebLinkSheet(request: req, onClose: { appState.pendingWebLink = nil })
            }
            .onChange(of: appState.pendingAddUIN) { newValue in
                if let uin = newValue {
                    deepLinkAddHost = appState.pendingAddHost
                    deepLinkAddUIN = uin
                    appState.pendingAddUIN = nil
                    appState.pendingAddHost = nil
                }
            }
            // Don't clear pendingOpenChatUIN until navigation succeeds — cold-launch push taps land
            // before vm.contacts populates, so the second onChange retries once the list loads.
            .onChange(of: appState.pendingOpenChatUIN) { _ in
                tryOpenPendingChat()
            }
            .onChange(of: vm.contacts) { _ in
                tryOpenPendingChat()
            }
            // Reset the flag so subsequent identical push taps re-fire (same-value assigns are no-ops).
            .onChange(of: appState.pendingOpenPending) { newValue in
                if newValue {
                    showPending = true
                    appState.pendingOpenPending = false
                }
            }
            .onChange(of: appState.pendingOpenGroupID) { _ in
                tryOpenPendingGroup()
            }
            .onChange(of: groups.groups) { _ in
                tryOpenPendingGroup()
            }
            .onChange(of: appState.pendingOpenUserProfile) { newValue in
                guard let uin = newValue else { return }
                appState.pendingOpenUserProfile = nil
                deepLinkProfileUIN = DeepLinkUIN(uin: uin)
            }
            .alert(
                "stealth.tooltip.title".localized,
                isPresented: $showStealthInfo,
            ) {
                Button("common.done".localized, role: .cancel) { showStealthInfo = false }
            } message: {
                Text("stealth.tooltip.body".localized)
            }
            .sheet(item: $deepLinkProfileUIN) { wrap in
                NavigationStack {
                    UserInfoView(uin: wrap.uin, isOwn: wrap.uin == AuthService.shared.ownUIN)
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
    }

    private func tryOpenPendingGroup() {
        guard let id = appState.pendingOpenGroupID else { return }
        guard let group = groups.groups.first(where: { $0.id == id }) else {
            // Group list hasn't loaded yet — leave the flag set; the
            // `onChange(of: groups.groups)` hook retries when it does.
            return
        }
        appState.pendingOpenGroupID = nil
        path.append(group)
    }

    private func tryOpenPendingChat() {
        guard let uin = appState.pendingOpenChatUIN else {
            refreshAttemptedFor.removeAll()
            return
        }
        guard let contact = vm.contacts.first(where: { $0.uin == uin }) else {
            if !refreshAttemptedFor.contains(uin) {
                refreshAttemptedFor.insert(uin)
                Task { await vm.refresh() }
            }
            return
        }
        appState.pendingOpenChatUIN = nil
        refreshAttemptedFor.removeAll()
        path.append(contact)
    }

    @ViewBuilder
    private func contactRowItem(for contact: Contact) -> some View {
        let group = stories.group(forUIN: contact.uin)
        ContactRow(
            contact: contact,
            storyGroup: group,
            onTapStory: group == nil ? nil : { openStoryViewer(forUIN: contact.uin) }
        )
        .contentShape(Rectangle())
        .scaleEffect(pressedRowID == "peer:\(contact.uin)" ? 0.96 : 1.0)
        .animation(.spring(response: 0.18, dampingFraction: 0.86), value: pressedRowID)
        .onTapGesture { path.append(contact) }
        .onLongPressGesture(
            minimumDuration: 0.18,
            pressing: { isPressing in
                if isPressing {
                    pressedRowID = "peer:\(contact.uin)"
                } else if pressedRowID == "peer:\(contact.uin)" {
                    pressedRowID = nil
                }
            },
            perform: { openPreview(.peer(contact)) }
        )
        .transition(.asymmetric(
            insertion: .move(edge: .leading).combined(with: .opacity),
            removal: .opacity
        ))
    }

    private func openStoryViewer(forUIN uin: Int) {
        // Resolve at tap-time — the array shifts as stories arrive.
        if let idx = stories.feed.firstIndex(where: { $0.ownerUIN == uin }) {
            storyViewerGroupIndex = StoryViewerWrapper(index: idx)
        }
    }

    @ViewBuilder
    private var ownStoryButton: some View {
        if let myUIN = AuthService.shared.ownUIN,
           let mineIdx = stories.feed.firstIndex(where: { $0.ownerUIN == myUIN }) {
            Button {
                storyViewerGroupIndex = StoryViewerWrapper(index: mineIdx)
            } label: {
                StoryThumbnailRing(group: stories.feed[mineIdx], size: 26, ringWidth: 1.8)
                    .fixedSize()
            }
            .buttonStyle(.plain)
        }
    }

    private var storiesCoverHost: some View {
        Color.clear
            .fullScreenCover(isPresented: $showStoryComposer) {
                NavigationStack { StoryComposerView() }
            }
            .fullScreenCover(item: $storyViewerGroupIndex) { wrapper in
                StoryViewerView(
                    groups: stories.feed,
                    initialGroupIndex: wrapper.index,
                    myUIN: AuthService.shared.ownUIN ?? 0
                )
            }
    }

    /// Tiny capsule at the top-leading edge of the nav bar showing the
    /// current account's server host. Tap reveals a menu listing every
    /// local account (checkmark on active) plus an "Add another
    /// server" entry that opens `AddAccountSheet`. Hidden entirely
    /// before onboarding has minted Account[0] — the principal nav
    /// area is the user's first-launch focus, no infrastructure noise.
    @ViewBuilder
    private var accountSwitcherPill: some View {
        if accountManager.active != nil {
            Menu {
                ForEach(accountManager.accounts.sorted(by: { $0.createdAt < $1.createdAt })) { account in
                    Button {
                        guard account.id != accountManager.activeAccountID else { return }
                        Task { await appState.switchToAccount(account.id) }
                    } label: {
                        // Three-line label inside the Menu: human-
                        // readable server name on top, host below,
                        // and the account's UIN as the third line —
                        // the UIN is the actually-unique identifier
                        // a user remembers ("I'm UIN 12345 on this
                        // server"), especially when two accounts
                        // happen to live on the same backend.
                        let primary = accountTitle(for: account)
                        // The UIN normally lives in the account's per-account
                        // Keychain slot. The very first (legacy) account may
                        // still carry it in the pre-migration unprefixed slot,
                        // so fall back to that ONLY for account[0].
                        let firstAccountID = accountManager.accounts
                            .sorted(by: { $0.createdAt < $1.createdAt }).first?.id
                        let uin = KeychainStore.string(KeychainStore.Keys.uin, forAccount: account.id)
                            ?? (account.id == firstAccountID ? KeychainStore.string(KeychainStore.Keys.uin) : nil)
                        // A SwiftUI Menu (UIMenu) collapses a multi-line VStack
                        // label down to its FIRST line, which was silently
                        // hiding the UIN. Keep the label to ONE line so
                        // "<name> · #<uin>" always renders — the UIN is the
                        // disambiguator a user remembers, so it leads the
                        // suffix and never truncates off the end.
                        let title = uin.map { "\(primary) · #\($0)" } ?? primary
                        if account.id == accountManager.activeAccountID {
                            Label(title, systemImage: "checkmark")
                        } else {
                            Text(title)
                        }
                    }
                }
                Divider()
                if !accountManager.isAtAccountLimit {
                    Button {
                        showAddAccount = true
                    } label: {
                        Label("contact_list.add_account".localized, systemImage: "plus")
                    }
                }
                // Manage entry is only meaningful once you've got more
                // than one account. With a single account there's
                // nothing to remove from here (the active one can't
                // be deleted via this surface — that's the Burn
                // account flow in Privacy & Network).
                if accountManager.accounts.count > 1 {
                    Button {
                        showManageAccounts = true
                    } label: {
                        Label(
                            "contact_list.manage_accounts".localized,
                            systemImage: "person.2.crop.square.stack"
                        )
                    }
                }
            } label: {
                Image(systemName: "server.rack")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.Color.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle().fill(Theme.Color.bgSecondary.opacity(0.6))
                    )
            }
        } else {
            EmptyView()
        }
    }

    /// Human-readable label for an account row in the switcher
    /// menu. Prefers an explicit `displayLabel` set on the account,
    /// then a catalogue entry name matching the URL, finally falls
    /// back to the bare host.
    private func accountTitle(for account: Account) -> String {
        if let label = account.displayLabel, !label.isEmpty {
            return label
        }
        if let entry = ServerDirectoryService.shared.servers.first(where: { $0.url == account.serverURL }) {
            return entry.name
        }
        return account.displayHost
    }

    private var identityPrincipal: some View {
        // Trailing Color.clear pads against the leading icon to centre nick/UIN in the nav bar.
        HStack(spacing: 8) {
            // Stay-online countdown, left of the status icon: how long until
            // presence drops back to offline after leaving (set in Privacy).
            // Tapping it explains what it is; an invisible copy on the trailing
            // side keeps it from shifting the centred nick/UIN.
            Menu {
                // "Stay visible after you leave" countdown, moved here from the
                // header into the status menu. A native iOS menu can't free-
                // position a chip, so it sits as the top section; tapping it
                // opens the explainer.
                if let expiry = PresenceWindow.expiry(uin: auth.ownUIN), expiry > Date() {
                    Section("presence.info.title".localized) {
                        Button { showPresenceInfo = true } label: {
                            Label(PresenceCountdownChip.label(expiry.timeIntervalSinceNow), systemImage: "clock")
                        }
                    }
                }
                Picker("contact_list.status_picker".localized, selection: statusBinding) {
                    ForEach(UserStatus.allCases) { status in
                        Label(status.label, image: assetName(for: status)).tag(status)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                // #16: persistent connection dot on the identity flower —
                // green = confirmed live link to the server, orange =
                // device offline OR socket down/dialing/unconfirmed. The
                // device-network flag alone isn't enough: with the VPN
                // pulled but Wi-Fi up the path stays "satisfied" while the
                // server is unreachable — `linkUp` (server evidence) is
                // what makes the dot honest there.
                ZStack(alignment: .bottomTrailing) {
                    StatusIcon(status: presence.status, size: 26)
                    Circle()
                        .fill(appState.isOffline || !socket.linkUp ? Color.orange : Color.green)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().stroke(Theme.Color.bgPrimary, lineWidth: 1.5))
                }
            }
            Button { showProfile = true } label: {
                VStack(spacing: 0) {
                    Text(auth.nickname.isEmpty ? "—" : auth.nickname)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundColor(Theme.Color.textPrimary)
                        .lineLimit(1)
                    if appState.isOffline {
                        Text("contact_list.offline_badge".localized)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Color.orange)
                    } else {
                        Text(verbatim: "#\(auth.ownUIN ?? 0)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Theme.Color.textMono)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Group {
                if singboxActivePort > 0 {
                    StealthHeaderBadge {
                        showStealthInfo = true
                    }
                } else {
                    Color.clear
                }
            }
            .frame(width: 22, height: 22)
        }
    }

    @ViewBuilder
    private var contactListMenu: some View {
        Menu {
            Button {
                showAddContact = true
            } label: {
                Label("contact_list.menu.add".localized, systemImage: "person.badge.plus")
            }
            Button {
                showOutgoing = true
            } label: {
                Label("contact_list.menu.outgoing".localized, systemImage: "clock")
            }
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showSearch = true }
            } label: {
                Label("contact_list.menu.search".localized, systemImage: "magnifyingglass")
            }
            Button {
                showStoryComposer = true
            } label: {
                Label("contact_list.menu.post_story".localized, systemImage: "camera.badge.ellipsis")
            }
            Button {
                showNews = true
            } label: {
                // Menu label paints the unread count alongside the
                // News icon — the ellipsis dot tells the user
                // "something's new", and this row tells them how
                // many. SwiftUI Menu doesn't accept overlays on
                // Label/Button content, so we encode the count
                // into the title text itself (matches how iOS Mail
                // formats unread).
                if news.unreadCount > 0 {
                    Label("\("contact_list.menu.news".localized)  •  \(news.unreadCount)",
                          systemImage: "newspaper")
                } else {
                    Label("contact_list.menu.news".localized, systemImage: "newspaper")
                }
            }
            if let ownUIN = auth.ownUIN {
                Button {
                    let saved = Contact.savedMessagesSelf(ownUIN: ownUIN)
                    path.append(saved)
                } label: {
                    Label("contact_list.menu.saved".localized, systemImage: "bookmark.fill")
                }
            }
            // Censorship bypass engages AUTOMATICALLY when a direct connection
            // is blocked, but auto-detect can be wrong ("connected" yet nothing
            // flows), so the manual on/off lives here too (Android home-menu
            // parity). Diagnostics stays here for quick access.
            Section {
                Button {
                    Task { await SingBoxTransport.shared.setEnabled(!SingBoxTransport.isEnabled) }
                } label: {
                    Label(
                        (SingBoxTransport.isEnabled ? "contact_list.menu.bypass_off" : "contact_list.menu.bypass_on").localized,
                        systemImage: "shield.lefthalf.filled"
                    )
                }
                Button {
                    showDiagnostics = true
                } label: {
                    Label("settings.network.diag".localized, systemImage: "stethoscope")
                }
            }
        } label: {
            // Red dot indicator when unread news posts are
            // available. Overlay'd at the top-right so the ellipsis
            // glyph stays clean and the dot reads as a status badge.
            ZStack(alignment: .topTrailing) {
                Image(systemName: "ellipsis")
                    .foregroundColor(Theme.Color.textPrimary)
                if news.hasUnread {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(Theme.Color.bgPrimary, lineWidth: 1.5))
                        .offset(x: 6, y: -4)
                }
            }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: []) {
                if vm.pendingCount + ciRequests.requestCount > 0 {
                    pendingBanner
                }
                // Gate empty-state on a completed first refresh — otherwise the CTA flashes during cold launch.
                if vm.hasLoadedOnce && vm.contacts.isEmpty && groups.groups.isEmpty && vm.pendingCount + ciRequests.requestCount == 0 {
                    emptyState
                }
                favoritesSection
                audioRoomsSection
                groupsSection
                section(
                    title: "contact_list.section.online".localized,
                    count: vm.online.count,
                    collapsed: vm.collapsedOnline,
                    rows: vm.online,
                    toggle: { vm.collapsedOnline.toggle() }
                )
                section(
                    title: "contact_list.section.offline".localized,
                    count: vm.offline.count,
                    collapsed: vm.collapsedOffline,
                    rows: vm.offline,
                    unreadBadge: vm.offlineUnreadContacts,
                    toggle: { vm.collapsedOffline.toggle() }
                )
                crossIslandSection
                archiveSection
                Spacer().frame(height: 8)
            }
        }
        .refreshable {
            async let c: Void = vm.refresh()
            async let g: Void = groups.refresh()
            async let a: Void = audioRooms.refresh()
            _ = await (c, g, a)
        }
    }

    @ViewBuilder
    private var favoritesSection: some View {
        let favGroups = groups.groups.filter { favorites.contains(group: $0.id) }
        // Suppress a self-contact (our own UIN on our own island) from
        // Favorites — an account can momentarily surface itself as a contact,
        // and starring a chat-with-myself row shouldn't be possible.
        let myUIN = AuthService.shared.ownUIN
        let favContacts = vm.contacts.filter {
            favorites.contains(peer: $0.uin)
                && !($0.uin == myUIN && ($0.host == nil || $0.host == Multihome.ownHost()))
        }
            .sorted { $0.nickname.lowercased() < $1.nickname.lowercased() }
        let total = favGroups.count + favContacts.count
        if total > 0 {
            VStack(spacing: 0) {
                Button { collapsedFavorites.toggle() } label: {
                    HStack(spacing: 6) {
                        CollapseChevron(collapsed: collapsedFavorites)
                        Text("contact_list.section.favorites".localized.uppercased())
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(Theme.Color.textSecondary)
                        Text("(\(total))")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.Color.textSecondary)
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Theme.Color.bgSecondary.opacity(0.7))
                }
                if !collapsedFavorites {
                    // `fav-` prefix isolates press cues from the duplicate row in online/offline/groups.
                    ForEach(favGroups) { group in
                        GroupRow(group: group)
                            .contentShape(Rectangle())
                            .onTapGesture { path.append(group) }
                            .scaleEffect(pressedRowID == "fav-group:\(group.id)" ? 0.96 : 1.0)
                            .animation(.spring(response: 0.18, dampingFraction: 0.86), value: pressedRowID)
                            .onLongPressGesture(
                                minimumDuration: 0.18,
                                pressing: { isPressing in
                                    if isPressing {
                                        pressedRowID = "fav-group:\(group.id)"
                                    } else if pressedRowID == "fav-group:\(group.id)" {
                                        pressedRowID = nil
                                    }
                                },
                                perform: { openPreview(.group(group)) }
                            )
                    }
                    ForEach(favContacts) { contact in
                        let group = stories.group(forUIN: contact.uin)
                        ContactRow(
                            contact: contact,
                            storyGroup: group,
                            onTapStory: group == nil ? nil : { openStoryViewer(forUIN: contact.uin) }
                        )
                            .contentShape(Rectangle())
                            .onTapGesture { path.append(contact) }
                            .scaleEffect(pressedRowID == "fav-peer:\(contact.uin)" ? 0.96 : 1.0)
                            .animation(.spring(response: 0.18, dampingFraction: 0.86), value: pressedRowID)
                            .onLongPressGesture(
                                minimumDuration: 0.18,
                                pressing: { isPressing in
                                    if isPressing {
                                        pressedRowID = "fav-peer:\(contact.uin)"
                                    } else if pressedRowID == "fav-peer:\(contact.uin)" {
                                        pressedRowID = nil
                                    }
                                },
                                perform: { openPreview(.peer(contact)) }
                            )
                    }
                }
            }
        }
    }

    private var groupsSection: some View {
        let visibleGroups = groups.groups.filter { !archive.contains(group: $0.id) }
        return VStack(spacing: 0) {
            Button { collapsedGroups.toggle() } label: {
                HStack(spacing: 6) {
                    CollapseChevron(collapsed: collapsedGroups)
                    Text("contact_list.section.groups".localized.uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Theme.Color.textSecondary)
                    Text("(\(visibleGroups.count))")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.Color.textSecondary)
                    Spacer()
                    Button {
                        showCreateGroup = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(Theme.Color.accent)
                            .font(.system(size: 14))
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Theme.Color.bgSecondary.opacity(0.7))
            }
            if !collapsedGroups {
                if visibleGroups.isEmpty {
                    Button { showCreateGroup = true } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(Theme.Color.accent)
                            Text("contact_list.create_first_group".localized)
                                .font(.caption)
                                .foregroundColor(Theme.Color.textPrimary)
                            Spacer()
                        }
                        .padding(.horizontal, Theme.Metrics.rowHPad)
                        .padding(.vertical, 10)
                        .background(Theme.Color.bgPrimary)
                    }
                } else {
                    ForEach(visibleGroups) { group in
                        GroupRow(group: group)
                            .contentShape(Rectangle())
                            .onTapGesture { path.append(group) }
                            .scaleEffect(pressedRowID == "group:\(group.id)" ? 0.96 : 1.0)
                            .animation(.spring(response: 0.18, dampingFraction: 0.86), value: pressedRowID)
                            .onLongPressGesture(
                                minimumDuration: 0.18,
                                pressing: { isPressing in
                                    // No haptic on press-down — fires on every taps/scroll-start.
                                    if isPressing {
                                        pressedRowID = "group:\(group.id)"
                                    } else if pressedRowID == "group:\(group.id)" {
                                        pressedRowID = nil
                                    }
                                },
                                perform: { openPreview(.group(group)) }
                            )
                    }
                }
            }
        }
    }

    private var audioRoomsSection: some View {
        VStack(spacing: 0) {
            Button { collapsedAudioRooms.toggle() } label: {
                HStack(spacing: 6) {
                    CollapseChevron(collapsed: collapsedAudioRooms)
                    Text("audio_room.section.title".localized.uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Theme.Color.textSecondary)
                    Text("(\(audioRooms.rooms.count))")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.Color.textSecondary)
                    Spacer()
                    Button {
                        showAudioRoomSheet = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(Theme.Color.accent)
                            .font(.system(size: 14))
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Theme.Color.bgSecondary.opacity(0.7))
            }
            if !collapsedAudioRooms {
                if audioRooms.rooms.isEmpty {
                    Button { showAudioRoomSheet = true } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(Theme.Color.accent)
                            Text("audio_room.section.create_first".localized)
                                .font(.caption)
                                .foregroundColor(Theme.Color.textPrimary)
                            Spacer()
                        }
                        .padding(.horizontal, Theme.Metrics.rowHPad)
                        .padding(.vertical, 10)
                        .background(Theme.Color.bgPrimary)
                    }
                } else {
                    ForEach(audioRooms.rooms) { room in
                        AudioRoomRow(room: room)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                audioRooms.enter(room: room)
                            }
                            .contextMenu {
                                Button {
                                    UIPasteboard.general.string = room.joinKey
                                } label: {
                                    Label("audio_room.menu.copy_key".localized, systemImage: "doc.on.doc")
                                }
                                if room.ownerUIN == AuthService.shared.ownUIN {
                                    Button {
                                        rotateKeyConfirmRoom = room
                                    } label: {
                                        Label("audio_room.menu.rotate_key".localized, systemImage: "arrow.triangle.2.circlepath")
                                    }
                                    Button(role: .destructive) {
                                        Task { await audioRooms.deleteRoom(roomID: room.id) }
                                    } label: {
                                        Label("audio_room.menu.delete".localized, systemImage: "trash")
                                    }
                                    // contextMenu items inherit app .tint (green) regardless of role: .destructive.
                                    .tint(.red)
                                } else {
                                    Button(role: .destructive) {
                                        Task { await audioRooms.leaveList(roomID: room.id) }
                                    } label: {
                                        Label("audio_room.menu.remove".localized, systemImage: "xmark.circle.fill")
                                    }
                                    .tint(.red)
                                }
                            }
                            // Pure opacity per-row insert — .move offsets desync from layout shifts below.
                            .transition(.opacity)
                    }
                }
            }
        }
        // Gate first reveal on hasLoadedOnce so /audio_rooms doesn't pop-then-restyle.
        .opacity(audioRooms.hasLoadedOnce ? 1 : 0)
        .animation(.easeOut(duration: 0.32), value: audioRooms.hasLoadedOnce)
        .animation(.easeOut(duration: 0.22), value: audioRooms.rooms.count)
    }

    /// Archived contacts + groups, hidden in a collapsed disclosure at
    /// the bottom of the list. Hidden entirely when nothing's archived
    /// so the chrome doesn't take up space.
    private var archiveLocked: Bool {
        PanicPINService.shared.isConfigured && !archiveUnlocked
    }

    @ViewBuilder
    private var archiveSection: some View {
        let archivedGroups = groups.groups.filter { archive.contains(group: $0.id) }
        let archivedContacts = vm.archivedContacts
        let total = archivedGroups.count + archivedContacts.count
        if total > 0 {
            VStack(spacing: 0) {
                Button {
                    if archiveLocked {
                        showArchivePINGate = true
                    } else {
                        collapsedArchive.toggle()
                        if collapsedArchive && PanicPINService.shared.isConfigured {
                            archiveUnlocked = false
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        CollapseChevron(collapsed: collapsedArchive || archiveLocked)
                        Text("contact_list.section.archive".localized.uppercased())
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(Theme.Color.textSecondary)
                        Text("(\(total))")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.Color.textSecondary)
                        Spacer()
                        if archiveLocked {
                            Image(systemName: "key.fill")
                                .foregroundColor(Theme.Color.accent)
                                .font(.system(size: 13))
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Theme.Color.bgSecondary.opacity(0.7))
                }
                if !collapsedArchive && !archiveLocked {
                    ForEach(archivedGroups) { group in
                        GroupRow(group: group)
                            .contentShape(Rectangle())
                            .onTapGesture { path.append(group) }
                            .scaleEffect(pressedRowID == "arch-group:\(group.id)" ? 0.96 : 1.0)
                            .animation(.spring(response: 0.18, dampingFraction: 0.86), value: pressedRowID)
                            .onLongPressGesture(
                                minimumDuration: 0.18,
                                pressing: { isPressing in
                                    if isPressing {
                                        pressedRowID = "arch-group:\(group.id)"
                                    } else if pressedRowID == "arch-group:\(group.id)" {
                                        pressedRowID = nil
                                    }
                                },
                                perform: { openPreview(.group(group)) }
                            )
                    }
                    ForEach(archivedContacts) { contact in
                        ContactRow(contact: contact)
                            .contentShape(Rectangle())
                            .onTapGesture { path.append(contact) }
                            .scaleEffect(pressedRowID == "arch-peer:\(contact.uin)" ? 0.96 : 1.0)
                            .animation(.spring(response: 0.18, dampingFraction: 0.86), value: pressedRowID)
                            .onLongPressGesture(
                                minimumDuration: 0.18,
                                pressing: { isPressing in
                                    if isPressing {
                                        pressedRowID = "arch-peer:\(contact.uin)"
                                    } else if pressedRowID == "arch-peer:\(contact.uin)" {
                                        pressedRowID = nil
                                    }
                                },
                                perform: { openPreview(.peer(contact)) }
                            )
                    }
                }
            }
        }
    }

    /// Big-blank fallback shown to fresh accounts whose contact AND
    /// group lists are both empty. Without it the new user lands on
    /// a screen full of "(0)" section headers and a floating capsule
    /// with no obvious next move. The CTA opens the same Add Contact
    /// sheet the bottom bar's "+" button would.
    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.2.wave.2")
                .font(.system(size: 44, weight: .light))
                .foregroundColor(Theme.Color.divider)
            Text("contact_list.empty.title".localized)
                .font(.system(.headline, weight: .semibold))
                .foregroundColor(Theme.Color.textPrimary)
            Text("contact_list.empty.body".localized)
                .font(.footnote)
                .foregroundColor(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                showAddContact = true
            } label: {
                Text("contact_list.empty.cta".localized)
                    .font(.system(.body, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: 220)
                    .padding(.vertical, 12)
                    .background(Theme.Color.accent)
                    .cornerRadius(8)
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    /// "Other islands" — cross-island contacts, straight from CrossIslandStore
    /// (the merged roster drops them on a uin collision with a local contact).
    /// Rows pass the full Contact (host set) into navigation, so the chat
    /// routes cross-island even when a same-uin local contact exists.
    @ViewBuilder
    private var crossIslandSection: some View {
        let unread = UnreadStore.shared.allPeerCounts
        let rows = ciStore.contactsSnapshot
            .map { c -> Contact in
                var c = c
                c.unread = unread[c.uin] ?? 0
                return c
            }
            .sorted { $0.nickname.lowercased() < $1.nickname.lowercased() }
        if !rows.isEmpty {
            section(
                title: "contact_list.section.cross_island".localized,
                count: rows.count,
                collapsed: collapsedCrossIsland,
                rows: rows,
                unreadBadge: rows.filter { $0.unread > 0 }.count,
                toggle: { collapsedCrossIsland.toggle() }
            )
        }
    }

    private var pendingBanner: some View {
        let total = vm.pendingCount + ciRequests.requestCount
        return Button { showPending = true } label: {
            HStack {
                Image(systemName: "person.crop.circle.badge.plus")
                    .foregroundColor(Theme.Color.accent)
                Text(String(
                    format: (total == 1
                        ? "contact_list.pending_one"
                        : "contact_list.pending_many").localized,
                    total
                ))
                    .font(Theme.Font.statusLabel)
                    .foregroundColor(Theme.Color.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11)).foregroundColor(Theme.Color.textSecondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Theme.Color.bgSecondary)
        }
    }

    private func section(
        title: String, count: Int, collapsed: Bool, rows: [Contact],
        unreadBadge: Int = 0, toggle: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    CollapseChevron(collapsed: collapsed)
                    // Caller already passes a localized string; we
                    // only uppercase here for the section-header
                    // typography.
                    Text(title.uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Theme.Color.textSecondary)
                    Text("(\(count))")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.Color.textSecondary)
                    Spacer()
                    if unreadBadge > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "envelope.badge.fill")
                                .font(.system(size: 9))
                            Text("\(unreadBadge)")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.Color.statusBusy))
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Theme.Color.bgSecondary.opacity(0.7))
            }
            if !collapsed {
                ForEach(rows) { contact in
                    contactRowItem(for: contact)
                }
            }
        }
    }

    /// Action list for a group's long-press preview overlay. Mirrors
    /// `groupContextMenu`'s items but as a `[ContextAction]` array so
    /// the SwiftUI-native `ContactPreviewOverlay` can render it with
    /// our own row component.
    private func groupActions(group: RCQGroup, thread: ThreadID, muted: Bool) -> [ContextAction] {
        var out: [ContextAction] = []
        out.append(ContextAction(
            title: "contact_list.ctx.open_chat".localized,
            systemImage: "bubble.left"
        ) { path.append(group) })
        out.append(ContextAction(
            title: (favorites.contains(group: group.id)
                    ? "contact_list.ctx.remove_favorite"
                    : "contact_list.ctx.add_favorite").localized,
            systemImage: favorites.contains(group: group.id) ? "star.slash" : "star"
        ) { favorites.toggle(group: group.id) })
        out.append(ContextAction(
            title: (muted ? "contact_list.ctx.unmute" : "contact_list.ctx.mute").localized,
            systemImage: muted ? "bell" : "bell.slash"
        ) { sound.toggleMute(thread: thread) })
        out.append(ContextAction(
            title: (archive.contains(group: group.id)
                    ? "contact_list.ctx.unarchive"
                    : "contact_list.ctx.archive").localized,
            systemImage: archive.contains(group: group.id) ? "tray.and.arrow.up" : "archivebox"
        ) { archive.toggle(group: group.id) })
        if PanicPINService.shared.isConfigured {
            out.append(ContextAction(
                title: (LockedChatsStore.shared.contains(group: group.id)
                        ? "contact_list.ctx.unlock"
                        : "contact_list.ctx.lock").localized,
                systemImage: LockedChatsStore.shared.contains(group: group.id) ? "lock.open" : "lock"
            ) { LockedChatsStore.shared.toggle(group: group.id) })
        }
        if group.ownerUIN == AuthService.shared.ownUIN {
            out.append(ContextAction(
                title: "contact_list.ctx.delete_group".localized,
                systemImage: "trash",
                destructive: true
            ) { Task { try? await groups.delete(group.id) } })
        } else {
            out.append(ContextAction(
                title: "contact_list.ctx.leave_group".localized,
                systemImage: "rectangle.portrait.and.arrow.right",
                destructive: true
            ) { Task { try? await groups.leave(group.id) } })
        }
        return out
    }

    /// Action list for a contact row's long-press preview overlay.
    /// Same items as `contactContextMenu`, packaged for the overlay.
    private func contactActions(contact: Contact, thread: ThreadID, muted: Bool) -> [ContextAction] {
        var out: [ContextAction] = []
        out.append(ContextAction(
            title: "contact_list.ctx.send_message".localized,
            systemImage: "bubble.left"
        ) { path.append(contact) })
        out.append(ContextAction(
            title: "contact_list.ctx.view_info".localized,
            systemImage: "info.circle"
        ) { path.append(contact) })
        out.append(ContextAction(
            title: (favorites.contains(peer: contact.uin)
                    ? "contact_list.ctx.remove_favorite"
                    : "contact_list.ctx.add_favorite").localized,
            systemImage: favorites.contains(peer: contact.uin) ? "star.slash" : "star"
        ) { favorites.toggle(peer: contact.uin) })
        out.append(ContextAction(
            title: (muted ? "contact_list.ctx.unmute" : "contact_list.ctx.mute").localized,
            systemImage: muted ? "bell" : "bell.slash"
        ) { sound.toggleMute(thread: thread) })
        out.append(ContextAction(
            title: (archive.contains(peer: contact.uin)
                    ? "contact_list.ctx.unarchive"
                    : "contact_list.ctx.archive").localized,
            systemImage: archive.contains(peer: contact.uin) ? "tray.and.arrow.up" : "archivebox"
        ) { archive.toggle(peer: contact.uin) })
        if PanicPINService.shared.isConfigured {
            out.append(ContextAction(
                title: (LockedChatsStore.shared.contains(peer: contact.uin)
                        ? "contact_list.ctx.unlock"
                        : "contact_list.ctx.lock").localized,
                systemImage: LockedChatsStore.shared.contains(peer: contact.uin) ? "lock.open" : "lock"
            ) { LockedChatsStore.shared.toggle(peer: contact.uin) })
        }
        out.append(ContextAction(
            title: (contact.blocked
                    ? "contact_list.ctx.unblock"
                    : "contact_list.ctx.block").localized,
            systemImage: contact.blocked ? "hand.raised.slash" : "hand.raised",
            destructive: !contact.blocked
        ) { Task { await vm.toggleBlock(contact.uin) } })
        out.append(ContextAction(
            title: "contact_list.ctx.report".localized,
            systemImage: "exclamationmark.shield",
            destructive: true
        ) { reportContact = contact })
        out.append(ContextAction(
            title: "contact_list.ctx.remove".localized,
            systemImage: "person.crop.circle.badge.xmark",
            destructive: true
        ) { Task { await vm.remove(contact.uin) } })
        return out
    }

    /// Resolve the action list for the overlay's currently-open target
    /// from the live model. Re-resolved on each render so toggle state
    /// (favourite / mute / archive) reflects what the user just did
    /// without having to close + reopen the preview.
    private func previewActions(for target: ChatTarget) -> [ContextAction] {
        switch target {
        case .peer(let snapshot):
            let live = vm.contacts.first(where: { $0.uin == snapshot.uin }) ?? snapshot
            let thread = ThreadID.peer(uin: live.uin)
            return contactActions(contact: live, thread: thread, muted: sound.isMuted(thread: thread))
        case .group(let snapshot):
            let live = groups.find(snapshot.id) ?? snapshot
            let thread = ThreadID.group(id: live.id)
            return groupActions(group: live, thread: thread, muted: sound.isMuted(thread: thread))
        case .randomPeer:
            return []
        }
    }

    /// Long-press handler shared by every row. Fires haptic, dismisses
    /// any active keyboard, then sets `previewTarget` so the overlay
    /// lifts in. Tight critically-damped spring (response 0.26s, damping
    /// 0.88) reads as "fluid and immediate" — earlier 0.22s easeOut
    /// felt drawn-out next to the long-press wait, and a softer spring
    /// overshot.
    private func openPreview(_ target: ChatTarget) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
        withAnimation(.spring(response: 0.26, dampingFraction: 0.88)) {
            previewTarget = target
        }
    }

    @ViewBuilder
    private func groupContextMenu(group: RCQGroup, thread: ThreadID, muted: Bool) -> some View {
        Button { path.append(group) } label: {
            Label("contact_list.ctx.open_chat".localized, systemImage: "bubble.left")
        }
        Button {
            favorites.toggle(group: group.id)
        } label: {
            Label((favorites.contains(group: group.id)
                    ? "contact_list.ctx.remove_favorite"
                    : "contact_list.ctx.add_favorite").localized,
                  systemImage: favorites.contains(group: group.id) ? "star.slash" : "star")
        }
        Button {
            sound.toggleMute(thread: thread)
        } label: {
            Label((muted
                    ? "contact_list.ctx.unmute"
                    : "contact_list.ctx.mute").localized,
                  systemImage: muted ? "bell" : "bell.slash")
        }
        Button {
            archive.toggle(group: group.id)
        } label: {
            Label((archive.contains(group: group.id)
                    ? "contact_list.ctx.unarchive"
                    : "contact_list.ctx.archive").localized,
                  systemImage: archive.contains(group: group.id) ? "tray.and.arrow.up" : "archivebox")
        }
        if PanicPINService.shared.isConfigured {
            Button { LockedChatsStore.shared.toggle(group: group.id) } label: {
                Label((LockedChatsStore.shared.contains(group: group.id)
                        ? "contact_list.ctx.unlock"
                        : "contact_list.ctx.lock").localized,
                      systemImage: LockedChatsStore.shared.contains(group: group.id) ? "lock.open" : "lock")
            }
        }
        Divider()
        if group.ownerUIN == AuthService.shared.ownUIN {
            Button(role: .destructive) {
                Task { try? await groups.delete(group.id) }
            } label: {
                Label("contact_list.ctx.delete_group".localized, systemImage: "trash")
            }
            .tint(.red)
        } else {
            Button(role: .destructive) {
                Task { try? await groups.leave(group.id) }
            } label: {
                Label("contact_list.ctx.leave_group".localized,
                      systemImage: "rectangle.portrait.and.arrow.right")
            }
            .tint(.red)
        }
    }

    @ViewBuilder
    private func contactContextMenu(contact: Contact, thread: ThreadID, muted: Bool) -> some View {
        Button { path.append(contact) } label: {
            Label("contact_list.ctx.send_message".localized, systemImage: "bubble.left")
        }
        Button { path.append(contact) } label: {
            Label("contact_list.ctx.view_info".localized, systemImage: "info.circle")
        }
        Button {
            favorites.toggle(peer: contact.uin)
        } label: {
            Label((favorites.contains(peer: contact.uin)
                    ? "contact_list.ctx.remove_favorite"
                    : "contact_list.ctx.add_favorite").localized,
                  systemImage: favorites.contains(peer: contact.uin) ? "star.slash" : "star")
        }
        Button {
            sound.toggleMute(thread: thread)
        } label: {
            Label((muted
                    ? "contact_list.ctx.unmute"
                    : "contact_list.ctx.mute").localized,
                  systemImage: muted ? "bell" : "bell.slash")
        }
        Button {
            archive.toggle(peer: contact.uin)
        } label: {
            Label((archive.contains(peer: contact.uin)
                    ? "contact_list.ctx.unarchive"
                    : "contact_list.ctx.archive").localized,
                  systemImage: archive.contains(peer: contact.uin) ? "tray.and.arrow.up" : "archivebox")
        }
        if PanicPINService.shared.isConfigured {
            Button { LockedChatsStore.shared.toggle(peer: contact.uin) } label: {
                Label((LockedChatsStore.shared.contains(peer: contact.uin)
                        ? "contact_list.ctx.unlock"
                        : "contact_list.ctx.lock").localized,
                      systemImage: LockedChatsStore.shared.contains(peer: contact.uin) ? "lock.open" : "lock")
            }
        }
        Divider()
        Button(role: contact.blocked ? .none : .destructive) {
            Task { await vm.toggleBlock(contact.uin) }
        } label: {
            Label((contact.blocked
                    ? "contact_list.ctx.unblock"
                    : "contact_list.ctx.block").localized,
                  systemImage: contact.blocked ? "hand.raised.slash" : "hand.raised")
        }
        // App-wide green tint overrides `role: .destructive` on
        // context-menu items in iOS 16+. The fix that actually propagates
        // to BOTH the text and the SF Symbol is `.tint(.red)` on the
        // Button itself — `.foregroundStyle` on the Label looks right in
        // Previews but doesn't repaint the system menu icon.
        .tint(contact.blocked ? Theme.Color.accent : .red)
        Button(role: .destructive) {
            Task { await vm.remove(contact.uin) }
        } label: {
            Label("contact_list.ctx.remove".localized,
                  systemImage: "person.crop.circle.badge.xmark")
        }
        .tint(.red)
    }

    /// IX-style floating capsule. Five icons evenly distributed
    /// inside a pill-shape backdrop floating above the screen
    /// bottom — not edge-to-edge. Slight shadow lifts it off the
    /// chat list.
    private var bottomBar: some View {
        HStack(spacing: 0) {
            barButton(icon: "person.badge.plus", label: "contact_list.bar.add".localized) { showAddContact = true }
            barButton(icon: "qrcode.viewfinder", label: "contact_list.bar.qr".localized) { showQR = true }
            // Operator can hide Random / Nearby via the admin console (Features).
            if appState.serverCapabilities.randomChat {
                barButton(icon: "shuffle", label: "contact_list.bar.random".localized) { showRandom = true }
            }
            if appState.serverCapabilities.nearby {
                barButton(icon: "location.viewfinder", label: "contact_list.bar.nearby".localized) { showNearby = true }
            }
            barButton(icon: "gearshape", label: "contact_list.bar.settings".localized) { showSettings = true }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule(style: .continuous)
                .fill(Theme.Color.bgSecondary)
                .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    private func barButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .medium))
                Text(label)
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundColor(Theme.Color.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func assetName(for status: UserStatus) -> String {
        switch status {
        case .online: return "status_online"
        case .away: return "status_away"
        case .dnd: return "status_dnd"
        case .invisible: return "status_invisible"
        case .offline: return "status_offline"
        }
    }

    private var statusBinding: Binding<UserStatus> {
        Binding(
            get: { presence.status },
            set: { newValue in
                Task { await presence.setStatus(newValue, message: presence.statusMessage) }
            }
        )
    }
}

/// Contact row — status icon stands in for the avatar, exactly like ICQ 2002. The
/// unread badge is anchored to the icon. Status message (if any) appears italicized
/// under the UIN, just as it did in the legacy client.
private struct ContactRow: View {
    let contact: Contact
    /// Active story group for this contact (nil if they have no
    /// posted stories live right now). When non-nil, a circular
    /// thumbnail ring renders at the right edge of the row; tapping
    /// it fires `onTapStory` (which the parent wires to the
    /// fullscreen viewer). Tapping anywhere else still opens the
    /// chat as before.
    var storyGroup: StoryGroup? = nil
    var onTapStory: (() -> Void)? = nil
    @ObservedObject private var sound = SoundService.shared
    @ObservedObject private var reactionInbox = ReactionInboxStore.shared
    @ObservedObject private var mentionInbox = MentionInboxStore.shared

    private var isMuted: Bool {
        sound.isMuted(thread: .peer(uin: contact.uin))
    }

    private var hasReaction: Bool {
        reactionInbox.has(.peer(uin: contact.uin))
    }

    // Mentions are group-only, so a 1:1 row never carries one — kept for
    // symmetry with GroupRow (always false in practice, harmless).
    private var hasMention: Bool {
        mentionInbox.has(.peer(uin: contact.uin))
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .topTrailing) {
                statusIcon
                if contact.unread > 0 {
                    Text("\(contact.unread)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Theme.Color.statusBusy))
                        .offset(x: 6, y: -4)
                }
            }
            .frame(width: 36, alignment: .center)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(contact.nickname)
                        .font(Theme.Font.nickname)
                        .foregroundColor(contact.status == .offline ? Theme.Color.textSecondary : Theme.Color.textPrimary)
                    GenderIcon(gender: contact.gender)
                    if contact.blocked {
                        Image(systemName: "nosign").font(.system(size: 10)).foregroundColor(Theme.Color.statusBusy)
                    }
                    if isMuted {
                        Image(systemName: "bell.slash.fill")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.Color.textSecondary)
                    }
                }
                HStack(spacing: 4) {
                    Text(verbatim: "#\(contact.uin)")
                        .font(Theme.Font.monoSmall)
                        .foregroundColor(Theme.Color.textMono)
                    if let h = contact.host {
                        // §5c: a cross-island peer shows its island (presence /
                        // last_seen don't cross islands), then any status.
                        Text(verbatim: "· \(h)")
                            .font(Theme.Font.monoSmall)
                            .foregroundColor(Theme.Color.textSecondary)
                            .lineLimit(1)
                        if let m = contact.statusMessage, !m.isEmpty {
                            Text("· \(m)")
                                .font(.caption2.italic())
                                .foregroundColor(Theme.Color.textSecondary)
                                .lineLimit(1)
                        }
                    } else if let m = contact.statusMessage, !m.isEmpty {
                        Text("· \(m)")
                            .font(.caption2.italic())
                            .foregroundColor(Theme.Color.textSecondary)
                            .lineLimit(1)
                    } else if contact.status == .offline,
                              let last = contact.lastSeen {
                        // Server already gates this by visibility — null
                        // means hidden, online users get null too.
                        Text("· \(String(format: "contact.last_seen".localized, Self.relativeLastSeen(last)))")
                            .font(.caption2)
                            .foregroundColor(Theme.Color.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer()
            // Trailing indicators, left→right: @ then heart. Mention-only ⇒
            // @ sits at the right edge; both ⇒ heart far right, @ to its left.
            HStack(spacing: 6) {
                if hasMention {
                    Image(systemName: "at")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.Color.accent)
                }
                if hasReaction {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.pink)
                }
            }
            if let storyGroup, let onTapStory {
                // Rightmost: circular thumbnail with segmented ring
                // for stories. Wrapped in a Button so the tap
                // doesn't bubble to the row's outer `.onTapGesture`
                // (which would open the chat instead). Sized 36pt
                // to match the leading status icon column.
                Button(action: onTapStory) {
                    StoryThumbnailRing(group: storyGroup)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Theme.Metrics.rowHPad)
        .padding(.vertical, Theme.Metrics.rowVPad)
        .background(Theme.Color.bgPrimary)
    }

    @ViewBuilder
    private var statusIcon: some View {
        StatusIcon(status: contact.status, size: 28, crossIsland: contact.host != nil)
    }

    /// Coarse "last seen" buckets — minutes / hours / days. Anything
    /// over a week falls back to a localised short date so the row
    /// doesn't read "9999h ago" for long-dormant contacts.
    fileprivate static func relativeLastSeen(_ date: Date) -> String {
        let secs = Int(-date.timeIntervalSinceNow)
        if secs < 60 { return "contact.last_seen.just_now".localized }
        let mins = secs / 60
        if mins < 60 {
            return String(format: "contact.last_seen.minutes".localized, mins)
        }
        let hours = mins / 60
        if hours < 24 {
            return String(format: "contact.last_seen.hours".localized, hours)
        }
        let days = hours / 24
        if days < 7 {
            return String(format: "contact.last_seen.days".localized, days)
        }
        return DateFormatter.lastSeenLong.string(from: date)
    }
}

private extension DateFormatter {
    static let lastSeenLong: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}

/// Identifiable wrapper so the deep-link UIN drives a `.sheet(item:)` presentation.
private struct DeepLinkUIN: Identifiable, Hashable { let uin: Int; var id: Int { uin } }
private struct JoinGroupTrigger: Identifiable, Hashable { let id: Int }

/// Identifiable wrapper for `.fullScreenCover(item:)` driving the
/// story viewer. Carries the index into `StoryService.feed` of the
/// group whose first story should appear first.
private struct StoryViewerWrapper: Identifiable {
    let index: Int
    var id: Int { index }
}


private struct GroupRow: View {
    let group: RCQGroup
    @StateObject private var groups = GroupService.shared
    @ObservedObject private var sound = SoundService.shared
    @ObservedObject private var reactionInbox = ReactionInboxStore.shared
    @ObservedObject private var mentionInbox = MentionInboxStore.shared

    private var isMuted: Bool {
        sound.isMuted(thread: .group(id: group.id))
    }

    private var hasReaction: Bool {
        reactionInbox.has(.group(id: group.id))
    }

    private var hasMention: Bool {
        mentionInbox.has(.group(id: group.id))
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .topTrailing) {
                // Circle stays at 28pt to match every other home-list
                // section (contact StatusIcon + AudioRoomRow disc are
                // both 28pt) — only the inner glyph shrinks. Smaller
                // glyph reads as breathing-room around the icon, not
                // as a smaller marker.
                GroupAvatarView(
                    mediaID: group.avatarMediaID,
                    keyBase64: group.avatarMediaKey,
                    host: group.host,
                    size: 28,
                    glyphSize: 12,
                )
                if let count = groups.unread[group.id], count > 0 {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Theme.Color.statusBusy))
                        .offset(x: 6, y: -4)
                }
            }
            .frame(width: 36)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(group.name).font(Theme.Font.nickname).foregroundColor(Theme.Color.textPrimary)
                    // Crown when the local user owns this group —
                    // matches the AudioRoomRow treatment so the
                    // visual signal is consistent across surfaces.
                    if AuthService.shared.ownUIN == group.ownerUIN {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.Color.textSecondary)
                    }
                    if isMuted {
                        Image(systemName: "bell.slash.fill")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.Color.textSecondary)
                    }
                }
                Text(String(
                    format: (group.members.count == 1
                        ? "contact_list.members_one"
                        : "contact_list.members_many").localized,
                    group.members.count
                ) + (group.host.map { " · \($0)" } ?? ""))
                    .font(.caption).foregroundColor(Theme.Color.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            // Trailing indicators, left→right: @ then heart. Mention-only ⇒
            // @ sits at the right edge; both ⇒ heart far right, @ to its left.
            HStack(spacing: 6) {
                if hasMention {
                    Image(systemName: "at")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.Color.accent)
                }
                if hasReaction {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.pink)
                }
            }
        }
        .padding(.horizontal, Theme.Metrics.rowHPad)
        .padding(.vertical, Theme.Metrics.rowVPad)
        .background(Theme.Color.bgPrimary)
    }
}

/// One row in the Audio Rooms section. Speaker glyph + name + active
/// count (highlighted green when ≥1 person inside) + chevron. Owner
/// gets a tiny crown badge so they remember which rooms only they
/// can delete.
private struct AudioRoomRow: View {
    let room: AudioRoom
    @StateObject private var audio = AudioRoomService.shared

    var body: some View {
        let inside = audio.isInside(room.id)
        let isOwner = room.ownerUIN == AuthService.shared.ownUIN
        return HStack(spacing: 10) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(inside ? Color.green : Theme.Color.accent))
            }
            .frame(width: 36)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(room.name).font(Theme.Font.nickname).foregroundColor(Theme.Color.textPrimary)
                    if isOwner {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 9))
                            .foregroundColor(Theme.Color.textSecondary)
                    }
                }
                HStack(spacing: 4) {
                    if room.activeCount > 0 {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                        Text(String(format: "audio_room.row.inside".localized, room.activeCount))
                            .font(Theme.Font.monoSmall)
                            .foregroundColor(Color.green)
                    } else {
                        Text("audio_room.row.idle".localized)
                            .font(Theme.Font.monoSmall)
                            .foregroundColor(Theme.Color.textMono)
                    }
                    Text("·")
                        .font(Theme.Font.monoSmall)
                        .foregroundColor(Theme.Color.textMono)
                    Text(room.joinKey)
                        .font(Theme.Font.monoSmall)
                        .foregroundColor(Theme.Color.textMono)
                }
            }
            Spacer()
        }
        .padding(.horizontal, Theme.Metrics.rowHPad)
        .padding(.vertical, Theme.Metrics.rowVPad)
        .background(Theme.Color.bgPrimary)
    }
}

/// Small "stealth active" badge in the contact list header. Slow
/// breathing pulse so the active state catches the eye without
/// distracting. Tap surfaces the explainer alert.
private struct StealthHeaderBadge: View {
    let onTap: () -> Void
    @State private var pulse: Bool = false

    var body: some View {
        Button(action: onTap) {
            Image(systemName: "shield.fill")
                .font(.system(size: 14))
                .foregroundColor(Theme.Color.accent)
                .scaleEffect(pulse ? 1.08 : 1.0)
                .opacity(pulse ? 1.0 : 0.85)
        }
        .buttonStyle(.plain)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

/// Local anchor for the presence "stay online for N hours" countdown shown
/// in the contact-list header. Set when the user enables/changes the window
/// in Privacy settings, re-anchored on every change, cleared when off. Keyed
/// by UIN so each account on the device tracks its own window.
enum PresenceWindow {
    private static func key(_ uin: Int?) -> String { "rcq.presenceWindow.\(uin ?? 0)" }

    static func anchor(ttlMinutes: Int, uin: Int?) {
        let expiry = Date().addingTimeInterval(Double(ttlMinutes) * 60)
        UserDefaults.standard.set(expiry.timeIntervalSince1970, forKey: key(uin))
    }

    static func clear(uin: Int?) {
        UserDefaults.standard.removeObject(forKey: key(uin))
    }

    static func expiry(uin: Int?) -> Date? {
        let t = UserDefaults.standard.double(forKey: key(uin))
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }
}

/// Compact "stay visible" countdown chip (clock + "Xh Ym") that sits left of
/// the header status icon. Ticks via TimelineView; hidden when the window is
/// off or has elapsed.
private struct PresenceCountdownChip: View {
    let uin: Int?
    /// Rendered transparent + non-interactive as a width mirror on the trailing
    /// side, so the leading chip never shifts the centred nick/UIN.
    var invisible: Bool = false
    var onTap: (() -> Void)? = nil

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            if let expiry = PresenceWindow.expiry(uin: uin), expiry > context.date {
                HStack(spacing: 3) {
                    Image(systemName: "clock")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Theme.Color.accent)
                    Text(Self.label(expiry.timeIntervalSince(context.date)))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.Color.textSecondary)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Theme.Color.bgSecondary))
                .contentShape(Capsule())
                .opacity(invisible ? 0 : 1)
                .allowsHitTesting(!invisible)
                .onTapGesture { onTap?() }
            }
        }
    }

    static func label(_ secs: TimeInterval) -> String {
        let totalMin = Int(secs / 60)
        let h = totalMin / 60, m = totalMin % 60
        let hU = "presence.countdown.h_unit".localized
        let mU = "presence.countdown.m_unit".localized
        if h > 0 && m > 0 { return "\(h)\(hU) \(m)\(mU)" }
        if h > 0 { return "\(h)\(hU)" }
        if totalMin > 0 { return "\(m)\(mU)" }
        return "presence.countdown.lt1m".localized
    }
}

#Preview {
    ContactListView()
}

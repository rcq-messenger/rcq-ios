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
    @StateObject private var trades = TradesService.shared
    /// Observe so `ownEquippedPet` (read from `items.items` +
    /// `items.catalog`) re-evaluates when inventory loads after
    /// boot or when the user equips/unequips a pet from another
    /// surface — without this the own status icon in the header
    /// is a snapshot at first render and the pet stays missing.
    @StateObject private var items = ItemsService.shared
    @StateObject private var stories = StoryService.shared

    @State private var showAddContact = false
    @State private var showProfile = false
    @State private var showPending = false
    @State private var showSettings = false
    @State private var showCreateGroup = false
    @State private var showAudioRoomSheet = false
    @State private var collapsedAudioRooms = false
    /// Audio room awaiting key-rotation confirmation. Set when the
    /// owner picks "Rotate join key" from the row's context menu;
    /// cleared by the confirmation dialog's actions. Carrying the
    /// whole room (not just the id) keeps the dialog title bound to
    /// the room name without a second lookup.
    @State private var rotateKeyConfirmRoom: AudioRoom?
    @State private var showRoulette = false
    @State private var showNearby = false
    @State private var showQR = false
    @State private var showSearch = false
    @State private var showInventory = false
    /// Driven by `pendingOpenTrades` push tap. Opens the same
    /// TradesListView the trades.freshIncoming sheet uses, but
    /// without needing a specific Trade object — handy when the
    /// push lands and the trade row hasn't been pulled yet (or
    /// has since been actioned and removed from `incoming`).
    @State private var showTradesList = false
    @State private var collapsedGroups = false
    /// Long-press preview target (Telegram-style scrollable preview
    /// + action list). Set on long-press of a contact or group row;
    /// drives the `ContactPreviewOverlay` rendering at the body root.
    @State private var previewTarget: ChatTarget?
    /// Row identifier that's currently being pressed (finger held, but
    /// the long-press hasn't yet armed). Drives a subtle scale-down on
    /// the matching row so the user gets a "pushed in" cue while their
    /// finger sits on the contact. Cleared on release or when the
    /// long-press completes. Format: `"peer:<uin>"` / `"group:<id>"`.
    @State private var pressedRowID: String?
    /// Drives the story composer fullScreenCover. Bound to a
    /// nav-bar `+ camera` button.
    @State private var showStoryComposer = false
    /// Drives the fullscreen Instagram-style story viewer. Holds an
    /// `Identifiable` wrapper around the index into `stories.feed`
    /// of the group whose first story should be shown first; nil →
    /// no viewer presented.
    @State private var storyViewerGroupIndex: StoryViewerWrapper?
    @State private var collapsedFavorites = false
    @State private var collapsedArchive = true
    @State private var path = NavigationPath()
    @State private var deepLinkAddUIN: Int? = nil
    /// Pending UINs we've already attempted a forced refresh for, so
    /// `tryOpenPendingChat` doesn't loop on /contacts when the
    /// requested UIN simply doesn't exist server-side (peer burned
    /// account, etc.). Reset whenever the pending value clears.
    @State private var refreshAttemptedFor: Set<Int> = []
    /// Active "Quick Preview" sheet target. Driven from the row
    /// context menu — the sheet renders a scrollable read-only chat
    /// preview, separate from the small contextMenu peek (which is
    /// static on iOS 16). Nil = no sheet open.
    /// Active equipped-pet preview sheet. Set when the user taps
    /// the status-icon zone of a contact row (or group member)
    /// whose `equippedPet` is non-nil. Wraps the pet snapshot plus
    /// the owner's nickname/UIN so the sheet can render the
    /// "view inventory" CTA without an extra fetch.
    @State private var petPreview: PetPreviewTarget?
    /// Active trade-propose target. Set from the contact context-menu
    /// "Trade" action; presented as a sheet over the contact list.
    @State private var tradeWithContact: Contact?
    /// Active report target. Set from the contact preview's "Report"
    /// action; drives the ReportContactSheet modal which POSTs to
    /// /reports for admin triage at admin.rcq.app.
    @State private var reportContact: Contact?

    var body: some View {
        // Outer ZStack hosts the preview overlay AT THE ROOT so it
        // covers the bottom safeAreaInset bar (and anything else the
        // NavigationStack lays out). Putting the overlay inside the
        // navigation stack's ZStack let the bar poke through and
        // pushed siblings around when previewTarget toggled — the
        // overlay needs to be a sibling of the whole nav stack, not
        // a sibling of the list.
        ZStack {
            navigationStackBody
            if let pt = previewTarget {
                ContactPreviewOverlay(
                    target: pt,
                    actions: previewActions(for: pt),
                    onDismiss: {
                        // Snappy dismiss — easeOut without lingering tail.
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
            // System nav bar with our identity (status icon + nick
            // + UIN) in `.principal` plus a single ellipsis menu
            // on the trailing edge — same idiom the chat header
            // uses. Search / Inventory / Saved Messages all sit
            // inside that ellipsis menu now. Bottom is the IX-
            // style floating capsule.
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showInventory = true
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "shippingbox.fill")
                                .foregroundColor(Theme.Color.textPrimary)
                            if trades.pendingIncomingCount > 0 {
                                // Sits flush over the box's top-
                                // right corner — system toolbar's
                                // hit-area was clipping the badge
                                // when it spilled past the icon.
                                Text("\(trades.pendingIncomingCount)")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 3)
                                    .padding(.vertical, 1)
                                    .background(Color.red)
                                    .clipShape(Capsule())
                                    .offset(x: 4, y: -2)
                            }
                        }
                    }
                }
                ToolbarItem(placement: .principal) {
                    identityPrincipal
                }
                // Single trailing slot containing the own-story
                // ring + the ⋯ menu in one HStack. iOS 26's new
                // toolbar style wraps each `ToolbarItem` in its own
                // pill capsule with non-trivial inter-pill spacing —
                // putting both into one item collapses the two pills
                // into a single capsule we control. Bonus: the pill's
                // internal content rect is taller than the trailing-
                // slot's per-item clip, so the circular ring renders
                // without the top/bottom flattening we had at 20pt.
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 8) {
                        ownStoryButton
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
                AddContactView(prefillUIN: wrap.uin)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showProfile) { ProfileView() }
            .sheet(isPresented: $showPending) { PendingRequestsView() }
            .sheet(isPresented: $showSettings) { SettingsView() }
            // Random Chat is a modal-takeover surface (own header,
            // own bottom strip, own pickers). Using `fullScreenCover`
            // instead of `.sheet` removes the swipe-down cascade
            // that iOS occasionally fires when an inner sheet
            // (PhotoPicker / VideoPicker) dismisses — symptom was
            // "I sent a photo and the chat closed on me."
            // `fullScreenCover` has no swipe gesture at all, so a
            // PhotoPicker dismiss can never be reinterpreted as a
            // parent dismiss. The user still leaves explicitly via
            // the X / Close buttons.
            .fullScreenCover(isPresented: $showRoulette) { RouletteView() }
            .fullScreenCover(isPresented: $showInventory) { InventoryView() }
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
                    // Drop the user straight into the live voice
                    // session — typical "create + start talking"
                    // flow. Sheet closes itself; the full-screen
                    // AudioRoomScreen takes over from RootView.
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
            .sheet(item: $petPreview) { wrap in
                PetPreviewSheet(
                    pet: wrap.pet,
                    ownerUIN: wrap.uin,
                    ownerNickname: wrap.nickname,
                )
                .presentationDetents([.medium, .large])
            }
            .sheet(item: $tradeWithContact) { contact in
                TradeProposeView(
                    recipientUIN: contact.uin,
                    recipientNickname: contact.nickname,
                )
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
                // Pull pending trades on launch so the inventory's
                // incoming-badge and the global banner can paint
                // immediately. Cheap (filtered to status=pending).
                await trades.refreshAll()
                // Cold-launch push-tap replay. RCQAppDelegate.didReceive
                // sets these flags BEFORE this view is mounted (the
                // first `.onChange` observer never fires for values
                // already present at attach time). Same fix pattern as
                // `tryOpenPendingChat` for `pendingOpenChatUIN` —
                // check explicitly after first mount.
                if appState.pendingOpenTrades {
                    showTradesList = true
                    appState.pendingOpenTrades = false
                }
                if appState.pendingOpenPending {
                    showPending = true
                    appState.pendingOpenPending = false
                }
            }
            // Global incoming-trade nudge. When `trade_received`
            // lands over WS, surface the unified TradesListView so
            // the user sees the row inline with Accept / Decline
            // buttons attached to it directly. Previously this used
            // a separate IncomingTradeSheet that just duplicated the
            // list row — the user (rightly) called that out.
            .sheet(isPresented: Binding(
                get: { trades.freshIncoming != nil },
                set: { if !$0 { trades.freshIncoming = nil } },
            )) {
                TradesListView()
            }
            .sheet(isPresented: $showTradesList) {
                TradesListView()
            }
            .onChange(of: appState.pendingAddUIN) { newValue in
                if let uin = newValue {
                    deepLinkAddUIN = uin
                    appState.pendingAddUIN = nil
                }
            }
            // Cross-stack request from the trades list OR a tapped
            // push notification: somebody set `pendingOpenChatUIN` and
            // we're expected to push that contact's chat onto our
            // NavigationPath.
            //
            // The tricky part is timing: a tap on a push from a cold
            // launch can fire BEFORE `ContactService.refresh()` has
            // populated `vm.contacts`. The previous version then
            // dropped the request silently. Two changes below:
            //
            //   1. We DON'T clear `pendingOpenChatUIN` until we
            //      actually navigate. So if the contact isn't loaded
            //      yet, the value stays set and we retry on contact
            //      list updates.
            //   2. A second `.onChange(of: vm.contacts)` re-checks the
            //      pending UIN every time the contact list refreshes.
            //      First refresh after launch picks up the deferred
            //      navigation.
            .onChange(of: appState.pendingOpenChatUIN) { _ in
                tryOpenPendingChat()
            }
            .onChange(of: vm.contacts) { _ in
                tryOpenPendingChat()
            }
            // Push-tap routing for "Friend request" and "Trade
            // offer" pushes. RCQAppDelegate sets the corresponding
            // flag on AppState; we surface the matching sheet then
            // flip the flag back so subsequent identical taps re-
            // fire (assigning the same value twice on `onChange`
            // is a no-op, hence the explicit reset).
            .onChange(of: appState.pendingOpenPending) { newValue in
                if newValue {
                    showInventory = false
                    trades.freshIncoming = nil
                    showPending = true
                    appState.pendingOpenPending = false
                }
            }
            .onChange(of: appState.pendingOpenTrades) { newValue in
                if newValue {
                    showInventory = false
                    trades.freshIncoming = nil  // dismiss the
                    // single-trade sheet first — opening both
                    // bindings concurrently would have iOS pick
                    // one and silently drop the other.
                    showTradesList = true
                    appState.pendingOpenTrades = false
                    // Refresh in the background so by the time
                    // the user is reading the list the freshly-
                    // landed offer is in it.
                    Task { @MainActor in await trades.refreshAll() }
                }
            }
        }
    }

    /// Try to consume a pending "open chat with X" request. Pulled
    /// out into its own helper because two onChange hooks call it —
    /// one when the request lands, one when contacts finish
    /// loading. We only clear the pending value after a successful
    /// navigation so a cold-launch push tap that lands before
    /// contacts populate gets retried on the next refresh.
    ///
    /// If the requested UIN isn't in our cached contact list AND
    /// we haven't already tried a forced refresh for it, kick a
    /// `vm.refresh()` once. Covers the case where the sender re-
    /// registered (new UIN) after our last contact-list refresh —
    /// without this, a push tap from a peer with a fresh UIN would
    /// just sit in `pendingOpenChatUIN` forever, waiting for an
    /// /contacts call that nothing else triggered.
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
        showInventory = false
        trades.freshIncoming = nil
        path.append(contact)
    }

    /// One contact row + its associated context menu + tap routing.
    /// Hoisted out of the listSection's ForEach to keep the body's
    /// type-checker complexity below the implicit limit. Resolves
    /// the contact's active story group at row-build time and passes
    /// a tap callback that opens the fullscreen viewer at the right
    /// index in the live feed.
    @ViewBuilder
    private func contactRowItem(for contact: Contact) -> some View {
        let group = stories.group(forUIN: contact.uin)
        ContactRow(
            contact: contact,
            onTapPet: { showPetPreview(for: contact) },
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
        // Resolve the index in the live feed at tap-time (the array
        // can shift between render and tap as new stories arrive).
        if let idx = stories.feed.firstIndex(where: { $0.ownerUIN == uin }) {
            storyViewerGroupIndex = StoryViewerWrapper(index: idx)
        }
    }

    /// Identity for the system nav bar's `.principal` slot —
    /// status icon menu, nickname, UIN, optional status message
    /// stacked. Tap on the nickname/UIN block opens ProfileView;
    /// tap on the status icon opens the status picker menu.
    /// Own-stories thumbnail ring in the toolbar. Renders only when
    /// the user has at least one active story today — there's no
    /// "you" row in the contact list, so without this entry point
    /// you couldn't watch your own stories back. Tap opens the
    /// viewer pre-positioned on your own group; the viewer's
    /// existing menu surfaces the "show viewers" + "delete"
    /// affordances from there.
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

    /// Invisible attachment surface for the story-related fullScreen
    /// covers. Mounted as `.background(...)` so the type-checker
    /// processes it as its own subexpression and the main body
    /// stays under the implicit complexity budget.
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

    private var identityPrincipal: some View {
        // Same centring trick as `ChatView.principalContent`: a
        // `Color.clear` of the leading icon's width pads the trailing
        // edge so the nickname / UIN VStack lands in the visual
        // centre of the nav bar instead of being shoved right by
        // the status icon. Status menu stays fully tappable.
        HStack(spacing: 8) {
            Menu {
                Picker("contact_list.status_picker".localized, selection: statusBinding) {
                    ForEach(UserStatus.allCases) { status in
                        Label(status.label, image: assetName(for: status)).tag(status)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                // Own status icon picks up your equipped-pet
                // overlay too. Tap STILL opens the status picker
                // (don't override that — it's the primary purpose
                // here). To preview the pet itself, tap your own
                // contact row in the list.
                StatusWithPet(
                    status: presence.status,
                    pet: items.ownEquippedPet,
                    size: 26,
                )
            }
            Button { showProfile = true } label: {
                VStack(spacing: 0) {
                    Text(auth.nickname.isEmpty ? "—" : auth.nickname)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundColor(Theme.Color.textPrimary)
                        .lineLimit(1)
                    Text(String(auth.ownUIN ?? 0))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.Color.textMono)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Color.clear.frame(width: 26, height: 1)
        }
    }

    /// Trailing ellipsis menu — Add contact, Search and Saved
    /// Messages. The Inventory affordance lives on the leading
    /// toolbar slot instead (badge-bearing, frequently used), so
    /// it's no longer duplicated here. "Add" is duplicated from
    /// the bottom bar by request — keyboard-thumb users reach the
    /// top trailing corner more comfortably than the centre of
    /// the bottom capsule.
    @ViewBuilder
    private var contactListMenu: some View {
        Menu {
            Button {
                showAddContact = true
            } label: {
                Label("contact_list.menu.add".localized, systemImage: "person.badge.plus")
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
            if let ownUIN = auth.ownUIN {
                Button {
                    let saved = Contact.savedMessagesSelf(ownUIN: ownUIN)
                    path.append(saved)
                } label: {
                    Label("contact_list.menu.saved".localized, systemImage: "bookmark.fill")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .foregroundColor(Theme.Color.textPrimary)
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: []) {
                if vm.pendingCount > 0 {
                    pendingBanner
                }
                // Gate empty-state on a completed first refresh — cold
                // launches with non-empty contacts otherwise flash the
                // "Add contact" CTA for one frame before the stream
                // populates.
                if vm.hasLoadedOnce && vm.contacts.isEmpty && groups.groups.isEmpty && vm.pendingCount == 0 {
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
                    toggle: { vm.collapsedOffline.toggle() }
                )
                archiveSection
                Spacer().frame(height: 8)
            }
        }
        // Standard system pull-to-refresh. Pulls every surface
        // the user might want fresh in one tug — contacts +
        // groups + pending trades. Returns when all three resolve
        // so the spinner stays attached until everything settles.
        .refreshable {
            async let c: Void = vm.refresh()
            async let g: Void = groups.refresh()
            async let t: Void = trades.refreshAll()
            async let a: Void = audioRooms.refresh()
            _ = await (c, g, t, a)
        }
    }

    /// Pinned section at the top — surfaces contacts and groups the user
    /// long-pressed → "Add to Favorites". Hidden entirely when empty so the
    /// chrome doesn't take up space until there's something to show.
    @ViewBuilder
    private var favoritesSection: some View {
        let favGroups = groups.groups.filter { favorites.contains(group: $0.id) }
        let favContacts = vm.contacts.filter { favorites.contains(peer: $0.uin) }
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
                    // Favorites section duplicates rows that ALSO
                    // appear in online/offline / groups sections.
                    // Use a distinct `fav-` prefix on the press ID
                    // so a press on the favorites row doesn't also
                    // visually compress the same contact's row in
                    // the online section (and vice versa).
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
                        ContactRow(contact: contact, onTapPet: { showPetPreview(for: contact) })
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
                                    // No haptic here — `pressing: true`
                                    // fires on every touch-down including
                                    // taps and scroll-starts, which made
                                    // the whole list feel "buzzy". Visual
                                    // scale-down is the press cue;
                                    // medium-impact haptic fires on
                                    // `perform` (when the menu actually
                                    // arms) inside `openPreview`.
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

    /// "Audio Rooms" section — same shape as `groupsSection`, with a
    /// `+` in the header that opens `CreateOrJoinAudioRoomSheet`.
    /// Tapping a row enters the live voice session; long-press for
    /// owner-only Delete or self Unsubscribe.
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
                                    // Override the inherited app `.tint` (Theme.Color.accent
                                    // = green) just for this menu item. contextMenu items
                                    // pick up tint regardless of `role: .destructive`,
                                    // which previously left the icon green even though
                                    // the text rendered red. `.tint(.red)` cascades to
                                    // both halves uniformly.
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
                            // Plain opacity for per-row inserts — no
                            // .move offset. With .move(.top) the rows
                            // animate sliding down WHILE the layout below
                            // them shifts in the same frame range, which
                            // SwiftUI compositor can't always keep
                            // synced — visible as the "laggy" appearance
                            // the user flagged. Pure opacity fade is
                            // cheap and reads as smooth.
                            .transition(.opacity)
                    }
                }
            }
        }
        // Gate the whole section's opacity on `hasLoadedOnce` so the
        // initial reveal is a single clean fade-in instead of a "pop +
        // restyle" cascade as /audio_rooms returns. Per-row inserts
        // after the first load (someone creates a new room) still use
        // the per-row opacity transition above.
        .opacity(audioRooms.hasLoadedOnce ? 1 : 0)
        .animation(.easeOut(duration: 0.32), value: audioRooms.hasLoadedOnce)
        .animation(.easeOut(duration: 0.22), value: audioRooms.rooms.count)
    }

    /// Archived contacts + groups, hidden in a collapsed disclosure at
    /// the bottom of the list. Hidden entirely when nothing's archived
    /// so the chrome doesn't take up space.
    @ViewBuilder
    private var archiveSection: some View {
        let archivedGroups = groups.groups.filter { archive.contains(group: $0.id) }
        let archivedContacts = vm.archivedContacts
        let total = archivedGroups.count + archivedContacts.count
        if total > 0 {
            VStack(spacing: 0) {
                Button { collapsedArchive.toggle() } label: {
                    HStack(spacing: 6) {
                        CollapseChevron(collapsed: collapsedArchive)
                        Text("contact_list.section.archive".localized.uppercased())
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
                if !collapsedArchive {
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
                        ContactRow(contact: contact, onTapPet: { showPetPreview(for: contact) })
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

    private var pendingBanner: some View {
        Button { showPending = true } label: {
            HStack {
                Image(systemName: "person.crop.circle.badge.plus")
                    .foregroundColor(Theme.Color.accent)
                Text(String(
                    format: (vm.pendingCount == 1
                        ? "contact_list.pending_one"
                        : "contact_list.pending_many").localized,
                    vm.pendingCount
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
        title: String, count: Int, collapsed: Bool, rows: [Contact], toggle: @escaping () -> Void
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
        // Trade — same surface AddDetailView gates behind, but reachable
        // from the contact list directly so a user doesn't have to open
        // the chat or search the contact again to propose an exchange.
        out.append(ContextAction(
            title: "contact_list.ctx.trade".localized,
            systemImage: "arrow.left.arrow.right"
        ) { tradeWithContact = contact })
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
            barButton(icon: "shuffle", label: "contact_list.bar.roulette".localized) { showRoulette = true }
            barButton(icon: "location.viewfinder", label: "contact_list.bar.nearby".localized) { showNearby = true }
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

    /// Drive the pet-preview sheet from a contact row's status-icon
    /// tap. Idempotent — silently no-ops if the contact has no
    /// equipped pet (the row's button only fires for contacts with
    /// a pet, but checking here keeps the call site cheap).
    private func showPetPreview(for contact: Contact) {
        guard let pet = contact.equippedPet else { return }
        petPreview = PetPreviewTarget(
            pet: pet, uin: contact.uin, nickname: contact.nickname,
        )
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
    /// Optional tap-on-status-icon override. When the contact has an
    /// equipped pet, callers wire this to surface a preview sheet
    /// instead of opening the chat. When nil, the whole row routes
    /// to the chat as before.
    var onTapPet: (() -> Void)? = nil
    /// Active story group for this contact (nil if they have no
    /// posted stories live right now). When non-nil, a circular
    /// thumbnail ring renders at the right edge of the row; tapping
    /// it fires `onTapStory` (which the parent wires to the
    /// fullscreen viewer). Tapping anywhere else still opens the
    /// chat as before.
    var storyGroup: StoryGroup? = nil
    var onTapStory: (() -> Void)? = nil
    @ObservedObject private var sound = SoundService.shared

    private var isMuted: Bool {
        sound.isMuted(thread: .peer(uin: contact.uin))
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
                    Text(String(contact.uin))
                        .font(Theme.Font.monoSmall)
                        .foregroundColor(Theme.Color.textMono)
                    if let m = contact.statusMessage, !m.isEmpty {
                        Text("· \(m)")
                            .font(.caption2.italic())
                            .foregroundColor(Theme.Color.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer()
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

    /// Status icon zone — bare `StatusWithPet` when there's no
    /// equipped pet (no special tap handling). When a pet is
    /// equipped AND the caller provided `onTapPet`, the zone wraps
    /// in a Button that captures the tap before it reaches the
    /// row's outer `.onTapGesture`. Otherwise it falls through.
    @ViewBuilder
    private var statusIcon: some View {
        let icon = StatusWithPet(status: contact.status,
                                 pet: contact.equippedPet,
                                 size: 28)
        if let onTapPet, contact.equippedPet != nil {
            // Wrapping in a Button captures taps in the icon area;
            // the row's outer `.onTapGesture` only sees taps that
            // fall OUTSIDE the button's bounds. Native SwiftUI tap
            // consumption — no manual gesture priority needed.
            Button(action: onTapPet) { icon }
                .buttonStyle(.plain)
        } else {
            icon
        }
    }
}

/// Identifiable wrapper so the deep-link UIN drives a `.sheet(item:)` presentation.
private struct DeepLinkUIN: Identifiable, Hashable { let uin: Int; var id: Int { uin } }

/// Identifiable wrapper for `.fullScreenCover(item:)` driving the
/// story viewer. Carries the index into `StoryService.feed` of the
/// group whose first story should appear first.
private struct StoryViewerWrapper: Identifiable {
    let index: Int
    var id: Int { index }
}


/// Wrapper for `.sheet(item:)` of the equipped-pet preview. Carries
/// the pet snapshot plus the owner's identity so the preview sheet
/// can render the "see %@'s inventory" CTA without an extra fetch.
struct PetPreviewTarget: Identifiable, Hashable {
    let pet: EquippedPet
    let uin: Int
    let nickname: String
    /// Stable id keyed off (uin, instance_id) — same UIN can re-equip
    /// a different pet later, and the sheet should redraw if so.
    var id: String { "\(uin):\(pet.instanceID)" }
}


private struct GroupRow: View {
    let group: RCQGroup
    @StateObject private var groups = GroupService.shared
    @ObservedObject private var sound = SoundService.shared

    private var isMuted: Bool {
        sound.isMuted(thread: .group(id: group.id))
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .topTrailing) {
                // Circle stays at 28pt to match every other home-list
                // section (contact StatusIcon + AudioRoomRow disc are
                // both 28pt) — only the inner glyph shrinks. Smaller
                // glyph reads as breathing-room around the icon, not
                // as a smaller marker.
                Image(systemName: "person.3.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Theme.Color.accent))
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
                ))
                    .font(Theme.Font.monoSmall).foregroundColor(Theme.Color.textMono)
            }
            Spacer()
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

#Preview {
    ContactListView()
}

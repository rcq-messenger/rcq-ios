import SwiftUI
// `CGImageSource`, for decoding an island's logo at a bounded size rather than
// at whatever size its operator declared. See `IslandLogoStore.decode`.
import ImageIO

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
    @StateObject private var news = NewsService.shared
    @StateObject private var accountManager = AccountManager.shared
    // Variant A: held cross-island "message requests" count into the pending
    // banner — without it a cross-island request was invisible (no entry point).
    @ObservedObject private var ciRequests = CrossIslandRequestsStore.shared
    @ObservedObject private var socket = WebSocketService.shared
    /// Islands refused for a changed certificate, and first uses not yet
    /// noticed: the two trust banners at the top of the list draw from here
    /// and nothing else in the app has to remember to check.
    @ObservedObject private var islandTrust = IslandTrust.shared
    // Cross-island contacts render from the store directly: the merged
    // ContactService list drops them when a same-uin LOCAL contact exists.
    @ObservedObject private var ciStore = CrossIslandStore.shared
    // Duress view: the sections below that read a STORE rather than
    // `ContactService` have to be gated here as well. The stores are rebound to
    // an empty decoy namespace on entry, so this is the second line — but it is
    // the one that keeps a section honest if a rebind is ever missed.
    @ObservedObject private var panicPIN = PanicPINService.shared
    /// The home wallpaper decides how every surface on this screen paints
    /// itself, so the screen has to know when it changes. It changes when
    /// somebody picks a wallpaper and at no other time.
    @ObservedObject private var homeBackground = ChatBackgroundStore.shared
    /// The user's own chat-list sections (founder item 1 of 23.08, built to
    /// `docs/sections-design-2026-08-23.md`). The tree comes from the vault, so
    /// the same sections, in the same order, are on the desktop and on the web.
    @ObservedObject private var sectionsStore = SectionsStore.shared
    /// Which sections are folded up. Device-local and per account, and it
    /// SURVIVES this screen: the flags used to be `@State` here, so folding
    /// Offline away lasted exactly as long as the view did (founder, 23.08).
    @ObservedObject private var collapseStore = SectionCollapseStore.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var showAddContact = false
    @State private var showAddAccount = false
    @State private var showManageAccounts = false
    @State private var showProfile = false
    @State private var showPending = false
    @State private var showMyReports = false

    /// Open the reports screen from a tapped "we answered your report" push.
    /// SwiftUI will not present a sheet over a sheet, and the tap can land while
    /// Settings (or any other sheet) is already up — which is exactly where the
    /// user came from if they filed the report a minute ago. So close what is
    /// open, let the dismissal land, then present.
    private func openMyReports() {
        appState.pendingOpenReports = false
        let wasPresenting = showSettings || showProfile || showPending || showQR
            || showNearby || showDiagnostics || showAddContact
        showSettings = false
        showProfile = false
        showPending = false
        showQR = false
        showNearby = false
        showDiagnostics = false
        showAddContact = false
        guard wasPresenting else { showMyReports = true; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { showMyReports = true }
    }
    @State private var showSettings = false
    @State private var showCreateGroup = false
    @State private var showAudioRoomSheet = false
    @State private var rotateKeyConfirmRoom: AudioRoom?
    @State private var showNearby = false
    @State private var showRandom = false
    @State private var showRadio = false
    /// The `.rcq` browser, and where it opens: the menu entry asks for the
    /// start screen, a `.rcq` link tapped in a chat asks for its site.
    @State private var sitesRequest: AppState.SiteOpenRequest?
    @State private var showQR = false
    @State private var showSearch = false
    @State private var previewTarget: ChatTarget?
    // The press-down scale used to be a `@State` HERE, holding the id of the
    // row under the finger. `onLongPressGesture(pressing:)` fires on touch
    // DOWN, including the touch-down that becomes a scroll, and again when
    // the press cancels, so simply putting a finger on the list rewrote root
    // state and re-ran this whole body. It now lives inside `PressableRow`,
    // where a press is nobody's business but the row's.
    @State private var showNews = false
    @State private var showOutgoing = false
    @State private var showDiagnostics = false
    /// Sections whose PIN has been answered, for THIS appearance of the screen.
    /// Never persisted, never in the collapse set: it resets when the section
    /// is collapsed, when the app goes to the background, and on every cold
    /// start. A gate that survives those is not a gate.
    @State private var unlockedSections: Set<String> = []
    /// The section the PIN sheet is asking for right now.
    @State private var pinGateSection: String?
    /// Sections whose "this device has no PIN" notice the user has opened. A
    /// gated section renders COLLAPSED even where the flag cannot be honoured;
    /// the notice is what one tap on the header reveals, not what it opens on.
    @State private var noticeSections: Set<String> = []
    @State private var reorderingSections = false
    @State private var pickerSection: String?
    @State private var renameSectionID: String?
    @State private var renameSectionText = ""
    @State private var showNewSection = false
    @State private var newSectionText = ""
    @State private var deleteSectionID: String?
    @State private var pinConfirmSection: String?
    @State private var sectionsErrorText: String?
    @State private var path = NavigationPath()
    @State private var deepLinkAddUIN: Int? = nil
    /// Island host from the contact link's `?h=` (spec §5); nil = same island.
    @State private var deepLinkAddHost: String? = nil
    @State private var deepLinkProfileUIN: DeepLinkUIN? = nil
    @State private var showStealthInfo: Bool = false
    /// Written by Settings when it refreshes the profile. Read from the
    /// same mirror rather than fetched here: the header draws on every
    /// launch and must not wait on a request to know what to draw.
    @State private var ownBadge: String? = UserDefaults.standard.string(forKey: "rcq.ownBadge")
    @State private var refreshAttemptedFor: Set<Int> = []
    /// Group ids we already re-fetched the roster for, so a push tap that
    /// arrives before the group list exists gets exactly one retry instead of
    /// staying armed for the session (see tryOpenPendingGroup).
    @State private var groupRefreshAttemptedFor: Set<Int> = []
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

    /// Everything the sections feature presents: the PIN gate, the picker, and
    /// the four small dialogs behind the header menu.
    @ViewBuilder
    private func sectionSurfaces<V: View>(_ content: V) -> some View {
        content
            .sheet(item: Binding(
                get: { pinGateSection.map(SectionID.init) },
                set: { pinGateSection = $0?.id }
            )) { wrap in
                PINVerifySheet(title: (wrap.id == Sections.sysArchive
                                       ? "pin_verify.title.archive"
                                       : "pin_verify.title.section").localized) {
                    // ⚠ The unlocked state and NOTHING ELSE. Writing "expanded"
                    // to the collapse store here is how a gate stops being a
                    // gate: the next cold start would read it back and the
                    // section would stand open with the PIN never asked.
                    withAnimation(Self.foldAnimation) {
                        _ = unlockedSections.insert(wrap.id)
                    }
                }
            }
            .sheet(item: Binding(
                get: { pickerSection.map(SectionID.init) },
                set: { pickerSection = $0?.id }
            )) { wrap in
                SectionPickerSheet(
                    sectionID: wrap.id,
                    title: sectionTitle(wrap.id),
                    contacts: vm.contacts,
                    crossIsland: ciStore.contactsSnapshot,
                    groups: groups.groups,
                    onError: { sectionsErrorText = $0 }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .alert("sections.menu.new".localized, isPresented: $showNewSection) {
                TextField("sections.new.placeholder".localized, text: $newSectionText)
                Button("common.cancel".localized, role: .cancel) { newSectionText = "" }
                Button("sections.new.save".localized) { commitNewSection() }
            }
            .alert("sections.menu.rename".localized, isPresented: Binding(
                get: { renameSectionID != nil },
                set: { if !$0 { renameSectionID = nil } }
            )) {
                TextField("sections.new.placeholder".localized, text: $renameSectionText)
                Button("common.cancel".localized, role: .cancel) { renameSectionID = nil }
                Button("sections.rename.save".localized) { commitRenameSection() }
            }
            // The one sentence the design fixes for all three clients, shown
            // before the flag goes on rather than buried in a menu subtitle: it
            // says what the flag does and, just as importantly, what it does
            // NOT do. Never "protects", never "locks".
            .alert("sections.menu.pin".localized, isPresented: Binding(
                get: { pinConfirmSection != nil },
                set: { if !$0 { pinConfirmSection = nil } }
            )) {
                Button("common.cancel".localized, role: .cancel) { pinConfirmSection = nil }
                Button("sections.menu.pin".localized) { commitPinOn() }
            } message: {
                Text("sections.menu.pin.note".localized)
            }
            .confirmationDialog(
                "sections.menu.delete".localized,
                isPresented: Binding(
                    get: { deleteSectionID != nil },
                    set: { if !$0 { deleteSectionID = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("sections.menu.delete".localized, role: .destructive) { commitDeleteSection() }
                Button("common.cancel".localized, role: .cancel) { deleteSectionID = nil }
            } message: {
                Text("sections.menu.delete.confirm".localized)
            }
            .alert("common.error".localized, isPresented: Binding(
                get: { sectionsErrorText != nil },
                set: { if !$0 { sectionsErrorText = nil } }
            )) {
                Button("common.ok".localized) { sectionsErrorText = nil }
            } message: {
                Text(sectionsErrorText ?? "")
            }
            // A gate that survives the app going away is not a gate.
            .onChange(of: scenePhase) { phase in
                if phase != .active {
                    unlockedSections.removeAll()
                    noticeSections.removeAll()
                }
            }
    }

    /// How every surface on this screen paints itself.
    ///
    /// Flat when there is no home wallpaper, so nothing changes for the people
    /// who never set one. Translucent over a blur when there is, so the
    /// wallpaper reads through the chat list instead of being a strip of colour
    /// visible only in the gaps.
    ///
    /// The third case is the one that needs a reason. A built-in wallpaper is
    /// authored per theme (`Theme.Wallpaper`), so it can never fight the
    /// colours the rows are drawn in. A picture out of the gallery can, and
    /// there is no way to author around it: a white beach photo under the dark
    /// theme would push a translucent row light enough to take the ground out
    /// from under light text. So for CUSTOM images only, and only when the
    /// measured tone disagrees with the active theme, the tint goes back to
    /// nearly opaque and the theme reasserts itself. This is deliberately the
    /// small version of Android's `needsLightChrome`: the surface moves, not
    /// every token on the screen.
    /// The rule itself lives in `WallpaperSurface.mode`, reached through the
    /// store, and this screen and ChatView both ask the same question of it.
    /// It used to be written out again right here, which is how the chat and
    /// the chat list came to be two copies of one decision: the same picture
    /// set in both slots has to be read the same way in both, and a rule with
    /// two homes drifts the first time only one of them is corrected.
    private var wallpaperSurfaceMode: WallpaperSurface {
        homeBackground.surface(home: true, isLightTheme: colorScheme == .light)
    }

    /// Section-header band. Keeps its historical 0.7 wash when it is sitting on
    /// the theme background; over a wallpaper the surface modifier owns the
    /// transparency, and doubling the two would sink the header below its rows.
    private var sectionHeaderColor: Color {
        wallpaperSurfaceMode == .none
            ? Theme.Color.bgSecondary.opacity(0.7)
            : Theme.Color.bgSecondary
    }

    /// ⚠ Split in two on purpose. The chain on the stack below is long enough
    /// that adding the section sheets to it put the type checker over its
    /// budget ("unable to type-check this expression in reasonable time"), so
    /// the sections' own surfaces are applied in one wrapper rather than
    /// appended to the same chain.
    private var navigationStackBody: some View {
        sectionSurfaces(navigationStackCore)
    }

    private var navigationStackCore: some View {
        NavigationStack(path: $path) {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                // Optional home wallpaper (separate from the chat one). Behind
                // the list; no-op on the default. (Android parity.)
                HomeWallpaperView().ignoresSafeArea()
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
                ToolbarItem(placement: .topBarTrailing) {
                    contactListMenu
                }
                // Founder 30.08: the SYSTEM bottom bar instead of the
                // hand-built floating capsule - native material, native
                // safe-area behaviour, and on iOS 26 the system's own glass.
                // The four doors are actions, not tabs, so this stays a
                // toolbar rather than becoming a TabView that would lie
                // about the app's structure.
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { showAddContact = true } label: {
                        Image(systemName: "person.badge.plus")
                    }
                    .accessibilityLabel("contact_list.bar.add".localized)
                    Spacer()
                    Button { showQR = true } label: {
                        Image(systemName: "qrcode.viewfinder")
                    }
                    .accessibilityLabel("contact_list.bar.qr".localized)
                    if appState.serverCapabilities.nearby {
                        Spacer()
                        Button { showNearby = true } label: {
                            Image(systemName: "location.viewfinder")
                        }
                        .accessibilityLabel("contact_list.bar.nearby".localized)
                    }
                    Spacer()
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("contact_list.bar.settings".localized)
                }
            }
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
            // The phrase, once, right after a fresh registration: only when the
            // first refresh has landed, so the account (and its 24 words) exist.
            .sheet(isPresented: Binding(
                get: { appState.showPhraseNudge && vm.hasLoadedOnce },
                set: { if !$0 { appState.showPhraseNudge = false } }
            )) { RecoveryPhraseView() }
            .sheet(isPresented: $showAddAccount) { AddAccountSheet() }
            .sheet(isPresented: $showManageAccounts) { ManageAccountsSheet() }
            // fullScreenCover (vs .sheet) avoids inner PhotoPicker dismiss bubbling up and closing the chat.
            .fullScreenCover(isPresented: $showRandom) { RandomChatView() }
            .fullScreenCover(isPresented: $showRadio) { RadioDiscoveryView() }
            // fullScreenCover, like Radio: the address bar is the chrome, and a
            // sheet would put a grabber and an inch of the chat list above it.
            .fullScreenCover(item: $sitesRequest) { SitesView(initial: $0) }
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
            .task(id: appState.networkReady) {
                // Four independent fetches, together rather than in single
                // file; the services coalesce with the boot's own catch-up,
                // so this costs no second request when one is in flight.
                // Keyed on the boot reaching "token and base in place": with
                // the list painted from disk this view mounts before that,
                // and the fetches it fires then are refused by the services,
                // so they run again the moment they can succeed.
                async let c: Void = vm.refresh()
                async let g: Void = groups.refresh(joinInFlight: true)
                async let a: Void = audioRooms.refresh()
                async let n: Void = news.refresh()
                // Arriving at the list before the socket is up: the sweep
                // carries its own fifteen-second floor, so walking back and
                // forth between the list and a chat is not a request each time.
                async let v: Void = VaultSync.sweep()
                _ = await (c, g, a, n, v)
                if appState.pendingOpenPending {
                    showPending = true
                    appState.pendingOpenPending = false
                }
                if appState.pendingOpenReports {
                    openMyReports()
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
            // Keyed on the facts themselves, so this runs once when they land
            // and never again while the user scrolls.
            .task(id: accountCardKey) { recordActiveAccountCard() }
            .sheet(isPresented: $showNews) {
                NewsSheet()
            }
            .sheet(isPresented: $showOutgoing) {
                OutgoingRequestsView()
            }
            .sheet(isPresented: $showDiagnostics) { ConnectionDiagnosticsView() }
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
            .onChange(of: appState.pendingOpenReports) { newValue in
                if newValue { openMyReports() }
            }
            .sheet(isPresented: $showMyReports) { MyReportsView() }
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
            .onChange(of: appState.pendingOpenSite) { newValue in
                guard let request = newValue else { return }
                appState.pendingOpenSite = nil
                sitesRequest = request
            }
            .alert(
                "stealth.tooltip.title".localized,
                isPresented: $showStealthInfo,
            ) {
                // The badge names the feature, so it also has to answer "what
                // is a relay?" with the same FAQ anchor as every other surface.
                Button("relays.learn_more".localized) {
                    showStealthInfo = false
                    InAppBrowser.open(RelayFAQLink.url)
                }
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
        // The persistent strips - minimized call, minimized audio room,
        // now-playing audio - hosted ONCE for the whole navigation stack.
        //
        // ⚠ On the STACK, not on its root content. `safeAreaInset` reserves
        // space on the view it is applied to, and a pushed destination is not
        // inside the root's content: applied one level in, the strip was drawn
        // by the chat list and by ChatView and by nobody else, so pushing
        // Group Info or a profile dropped the audio the user is listening to
        // off the screen. Applied HERE it insets the whole stack, navigation
        // bar and all, and every destination pushed into it inherits that for
        // free - which is the entire point of a strip that survives leaving
        // the chat. Screens that are their own presentation root (a
        // fullScreenCover / sheet starts a fresh safe area) still host it
        // themselves; see ChatView's random-chat path.
        .callMinimizedBarInset()
    }

    private func tryOpenPendingGroup() {
        guard let id = appState.pendingOpenGroupID else {
            groupRefreshAttemptedFor.removeAll()
            return
        }
        guard let group = groups.groups.first(where: { $0.id == id }) else {
            // The roster is not persisted, so on a cold launch (and on a
            // censored network, where boot can take the offline branch) it is
            // empty exactly when a push tap needs it. Fetch it once, and if the
            // group still is not there, DROP the request: leaving it armed used
            // to be harmless because every setter guaranteed the group existed,
            // but a notification tap does not, and a stale flag would later
            // shove that chat on screen the moment anything mutated the roster.
            if !groupRefreshAttemptedFor.contains(id) {
                groupRefreshAttemptedFor.insert(id)
                Task { await groups.refresh() }
            } else {
                appState.pendingOpenGroupID = nil
            }
            return
        }
        appState.pendingOpenGroupID = nil
        groupRefreshAttemptedFor.removeAll()
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
        PressableRow(
            onTap: { path.append(contact) },
            onLongPress: { openPreview(.peer(contact)) }
        ) {
            ContactRow(contact: contact, surface: wallpaperSurfaceMode)
        }
        .transition(.asymmetric(
            insertion: .move(edge: .leading).combined(with: .opacity),
            removal: .opacity
        ))
    }

    /// Tiny capsule at the top-leading edge of the nav bar showing the
    /// current account's server host. Tap reveals a menu listing every
    /// local account (checkmark on active) plus an "Add another
    /// server" entry that opens `AddAccountSheet`. Hidden entirely
    /// before onboarding has minted Account[0] — the principal nav
    /// area is the user's first-launch focus, no infrastructure noise.
    @ViewBuilder
    private var accountSwitcherPill: some View {
        // The menu lists every local account by server AND uin, and switching
        // to one raises that REAL account. A decoy identity is not in the
        // roster and must not be able to reach it, so the pill is not drawn at
        // all under duress — an account switcher with one nameless entry would
        // itself say "something is hidden here".
        if accountManager.active != nil && !panicPIN.isDecoy {
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
                        // ⚠ The founder's report (24.08): "the context menu
                        // shows nothing". Every row here was text and nothing
                        // else, so a switcher listing three islands drew three
                        // identical lines and the one control whose job is to
                        // say WHERE each account lives said it in words only.
                        //
                        // A `Menu` row is a `UIMenu` action under the hood: it
                        // has an image slot, not a view slot, so the island's
                        // face has to arrive as a flat UIImage (see
                        // `IslandLogoStore.menuIcon`, which draws the lettered
                        // tile itself when the island has no logo, so NO row is
                        // ever left without a mark).
                        //
                        // The active row keeps the checkmark: it is the one
                        // thing this menu has to answer before anything else,
                        // and a tick sitting on top of a picture in a system
                        // menu row is not a thing UIKit will draw.
                        if account.id == accountManager.activeAccountID {
                            Label(title, systemImage: "checkmark")
                        } else {
                            let card = AccountCardCache.card(for: account.id)
                            Label {
                                Text(title)
                            } icon: {
                                Image(uiImage: IslandLogoStore.shared.menuIcon(
                                    name: primary,
                                    host: card?.host ?? account.displayHost,
                                    version: card?.islandLogoVersion ?? ""
                                ))
                            }
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
                // Was a bare `server.rack` glyph: the same picture whichever
                // island you were on, which made the one control that says
                // WHERE YOU ARE say nothing at all. It carries the island's
                // own face and initial now, off the cache: no fetch, and a
                // cold start on a plane still knows which island it is on.
                IslandAvatarView(
                    name: accountTitle(for: accountManager.active),
                    host: accountManager.active?.displayHost ?? "",
                    // The live one for the island we are ON, falling back to
                    // the card so a cold start draws the right picture before
                    // `/server/info` has answered.
                    logoVersion: appState.serverLogoVersion.isEmpty
                        ? (accountManager.activeAccountID.flatMap { AccountCardCache.card(for: $0)?.islandLogoVersion } ?? "")
                        : appState.serverLogoVersion,
                    size: 28
                )
            }
        } else {
            EmptyView()
        }
    }

    /// Human-readable label for an account row in the switcher menu.
    ///
    /// The island's own name (what its operator typed into the admin panel and
    /// `/server/info` serves) leads, read from the per-account cache so an
    /// account we are not currently on still has one. Then the explicit local
    /// `displayLabel`, then a catalogue entry matching the URL, and finally the
    /// bare host, which is all we honestly know about an island that has never
    /// answered.
    private func accountTitle(for account: Account?) -> String {
        guard let account else { return "" }
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

    /// Everything the switcher shows about the ACTIVE account, written whenever
    /// one of those facts changes and never on a plain render.
    ///
    /// Same shape as the desktop's per-account snapshot
    /// (`web-chat/src/lib/contacts-cache.ts`): each account persists its own
    /// card while it is the live one, and the switcher then draws every row out
    /// of those cards without asking any island anything. The island name comes
    /// from `/server/info`, which only the active account is in a position to
    /// call, so this is the only moment it can be recorded.
    private var accountCardKey: String {
        [
            accountManager.activeAccountID?.uuidString ?? "",
            appState.serverName,
            // ⚠ In the key, not just in the payload. The card is written when
            // this string changes and at no other time, so an operator who set
            // or replaced their island's logo without touching its name would
            // never have it recorded, and the switcher would keep the old
            // picture until something else about the account moved.
            appState.serverLogoVersion,
            auth.nickname,
            String(auth.ownUIN ?? 0),
        ].joined(separator: "|")
    }

    private func recordActiveAccountCard() {
        // Nothing about a decoy session is written to disk, here as everywhere.
        guard !panicPIN.isDecoy, let account = accountManager.active else { return }
        AccountCardCache.record(
            AccountCard(
                islandName: appState.serverName.trimmingCharacters(in: .whitespacesAndNewlines),
                islandLogoVersion: appState.serverLogoVersion,
                avatarMediaID: presence.ownAvatarID ?? "",
                avatarMediaKey: presence.ownAvatarKey ?? "",
                host: account.displayHost,
                uin: auth.ownUIN,
                nickname: auth.nickname
            ),
            for: account.id
        )
    }

    private var identityPrincipal: some View {
        // Trailing Color.clear pads against the leading icon to centre nick/UIN in the nav bar.
        HStack(spacing: 8) {
            // Left of the status flower, ahead of the identity block (founder,
            // 06.09). It used to sit on the far side of the nickname, which put
            // a route indicator inside the block that says who you are. It is
            // not about you, it is about how your traffic leaves.
            //
            // ⚠ Taking real width, so the name does move over when relays come
            // up. That was the founder's call once he saw both: reserving the
            // 22pt always would hold the name still, and would also hold an
            // empty gap open for the whole life of the app for a thing that is
            // off most of the time. It moves — but it slides, and the shield
            // fades in rather than blinking into place (founder, 07.09).
            if singboxActivePort > 0 {
                StealthHeaderBadge {
                    showStealthInfo = true
                }
                .frame(width: 22, height: 22)
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
            Menu {
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
                // A decoy session is deliberately offline: it has no server
                // account, so `linkUp` is false forever. Reporting that would
                // make the duress view permanently advertise "not connected",
                // which is precisely the tell the decoy exists to remove — a
                // messenger nobody could have been using. It reads as connected
                // instead (Android sets `connected = true` for the same reason).
                let linkDown = !panicPIN.isDecoy && (appState.isOffline || !socket.linkUp)
                ZStack(alignment: .bottomTrailing) {
                    // The picture, with the status kept as the badge on its
                    // edge — the same shape Android draws. Without a picture
                    // this falls back to the plain status flower, so nothing
                    // changes at all for anyone who never set one.
                    //
                    // With a picture the badge carries BOTH meanings, because
                    // it is the only mark left: orange while there is no
                    // confirmed link, the chosen status once there is. Dropping
                    // the dot without moving what it said left the header
                    // saying nothing at all about the connection.
                    PersonAvatarView(
                        mediaID: presence.ownAvatarID,
                        keyBase64: presence.ownAvatarKey,
                        status: presence.status,
                        size: 26,
                        linkDown: linkDown
                    )
                    // The connection dot is dropped when a picture is up: the
                    // status badge already sits in that corner, and two dots on
                    // top of each other read as neither.
                    if presence.ownAvatarID == nil {
                        Circle()
                            .fill(linkDown ? Color.orange : Color.green)
                            .frame(width: 9, height: 9)
                            .overlay(Circle().stroke(Theme.Color.bgPrimary, lineWidth: 1.5))
                    }
                }
            }
            Button { showProfile = true } label: {
                VStack(spacing: 0) {
                    HStack(spacing: 4) {
                        Text(auth.nickname.isEmpty ? "—" : auth.nickname)
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundColor(Theme.Color.textPrimary)
                            .lineLimit(1)
                        // Your own mark. It stays here even when you have
                        // chosen not to wear it in public: the island still
                        // gave it to you, and the setting is about everyone
                        // else, so your own row is never blanked.
                        BadgeMark(kind: ownBadge, size: 12)
                    }
                    if appState.isOffline && !panicPIN.isDecoy {
                        Text("contact_list.offline_badge".localized)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Color.orange)
                    } else {
                        Text(verbatim: "\(auth.ownUIN ?? 0)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Theme.Color.textMono)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The counterweight the comment at the top of this stack means:
            // it balances the leading icon so the nick and UIN sit centred in
            // the nav bar. It held the shield until 06.09 and is now only ever
            // empty, which is what it was there for in the first place.
            Color.clear
                .frame(width: 22, height: 22)
        }
        // On the whole stack, not on the shield: the shield's own transition
        // fades IT in, and this is what carries the avatar and the name across
        // the distance it opened up. Animating only the shield leaves the name
        // jumping the 15pt in one frame while the shield dissolves politely.
        .animation(.easeInOut(duration: 0.28), value: singboxActivePort > 0)
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
            // Stranger Mode is an extra, not a primary destination: it used to
            // hold a slot in the bottom bar next to Add / QR / Settings, which
            // put "talk to a random person" on the same footing as the contact
            // list itself. It lives here now, still behind the operator's
            // `random_chat` flag, so an island that does not run it shows
            // nothing rather than a row that 404s.
            if appState.serverCapabilities.randomChat {
                Button {
                    showRandom = true
                } label: {
                    Label("contact_list.menu.random".localized, systemImage: "shuffle")
                }
            }
            // ⚠ Radio has no server side at all: it is the Bluetooth and
            // Wi-Fi mesh that works when there is no island to reach, which
            // is the one surface that must never depend on the island's
            // opinion. Until 22.08 its ONLY door was a toolbar button inside
            // People Nearby, so retiring Nearby quietly locked the offline
            // chat behind an online feature. It gets its own door here.
            Button {
                showRadio = true
            } label: {
                Label("contact_list.menu.radio".localized, systemImage: "antenna.radiowaves.left.and.right")
            }
            // The `.rcq` browser. Here rather than in the bottom bar for the
            // same reason Stranger Mode is: it is a place you go sometimes, not
            // one of the four you reach every day (Android home-menu parity).
            Button {
                sitesRequest = AppState.SiteOpenRequest(address: nil, page: nil)
            } label: {
                Label("contact_list.menu.sites".localized, systemImage: "globe")
            }
            // RCQ relays engage AUTOMATICALLY when a direct connection is
            // blocked, but auto-detect can be wrong ("connected" yet nothing
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
                // This menu is the one place that names the relays while they
                // are OFF: the shield badge (and its explainer alert) only
                // exists once they are carrying traffic, so without this the
                // word "relay" appears here with nowhere to look it up. Android
                // carries the same item in its home menu for the same reason.
                Button {
                    InAppBrowser.open(RelayFAQLink.url)
                } label: {
                    Label("relays.learn_more".localized, systemImage: "questionmark.circle")
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
                // The trust banners (design §5.1, §5.2) live with the other
                // top banners. Never in a decoy session: an island's name and
                // a refusal on it say which island the real account lives on.
                if !panicPIN.isDecoy {
                    ForEach(islandTrust.changed.values.sorted { $0.key < $1.key }) { change in
                        IslandTrustChangedBanner(change: change) {
                            Task { await appState.reconnectAfterTrustAccepted() }
                        }
                    }
                    ForEach(islandTrust.firstUses) { notice in
                        IslandTrustFirstUseNotice(notice: notice)
                    }
                }
                if vm.pendingCount + visibleCIRequests > 0 {
                    pendingBanner
                }
                // Gate empty-state on a completed first refresh — otherwise the CTA flashes during cold launch.
                if vm.hasLoadedOnce && vm.contacts.isEmpty && groups.groups.isEmpty && vm.pendingCount + visibleCIRequests == 0 {
                    emptyState
                }
                if reorderingSections {
                    reorderBar
                }
                // ⚠ ONE pass over the groups and one over the cross-island
                // rows, here, for every section below. The CONTACTS are
                // bucketed in the view model off the roster's own change and
                // never on a body: this screen re-runs its body constantly
                // (fifteen observed objects feed it), and taking the roster
                // walk out of it is exactly what today's work was.
                let buckets = homeBuckets()
                let rendered = renderedSections(buckets)
                // Audio rooms are NOT a chat section (out of scope for v1) and
                // they do not move: they keep their place above the band that
                // starts at Other islands, whatever the user does to the order
                // around them.
                let audioAnchor = rendered.first { $0.order >= (Sections.defaultOrder[Sections.sysCI] ?? 0) }?.id
                ForEach(rendered) { rec in
                    if rec.id == audioAnchor { audioRoomsSection }
                    sectionView(rec, buckets)
                }
                if audioAnchor == nil { audioRoomsSection }
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

    // MARK: - Sections
    //
    // Every band in this list, the six built-in ones and the user's own, comes
    // out of ONE ordered array. That is how the ORDER of the built-ins syncs
    // even though their membership stays derived: the slot holds a record per
    // section, `o` ascending with ties by id, and every device sorts the same
    // way. Membership of a user section is stored; membership of a built-in
    // never is.

    /// One band the list is going to draw.
    private struct SectionRow: Identifiable {
        let id: String
        let order: Int
        let isUser: Bool
        let title: String
    }

    /// The group and cross-island buckets, built in one pass each.
    private struct HomeBuckets {
        var favGroups: [RCQGroup] = []
        var normalGroups: [RCQGroup] = []
        var archivedGroups: [RCQGroup] = []
        var filedGroups: [String: [RCQGroup]] = [:]
        var crossLoose: [Contact] = []
        var filedCross: [String: [Contact]] = [:]
    }

    /// Bucket the groups and the cross-island peers.
    ///
    /// Contacts are NOT here: the view model already partitioned them off the
    /// roster's own change (`ContactListViewModel.repartition`), which is the
    /// one place that is allowed to walk the roster.
    ///
    /// ⚠ The member key carries the HOST, and a foreign group is keyed by
    /// (remoteId, host) rather than by its local id, which is a negative alias
    /// allocated in first-sight order and means nothing on another device.
    private func homeBuckets() -> HomeBuckets {
        var out = HomeBuckets()
        let filed = vm.sectionIndex
        for group in groups.groups {
            if archive.contains(group: group.id) {
                // Render precedence: archive > user section > derived.
                out.archivedGroups.append(group)
                continue
            }
            if let sid = Sections.key(forGroup: group).flatMap({ filed[$0] }) {
                // A group placed in a user section leaves the Groups section,
                // for the same reason a contact leaves Online.
                out.filedGroups[sid, default: []].append(group)
                continue
            }
            if favorites.contains(group: group.id) { out.favGroups.append(group) }
            out.normalGroups.append(group)
        }
        for sid in Array(out.filedGroups.keys) {
            // Inside a user section: unread first, then favourite, then name.
            out.filedGroups[sid] = out.filedGroups[sid]?.sorted { a, b in
                let ua = (groups.unread[a.id] ?? 0) > 0
                let ub = (groups.unread[b.id] ?? 0) > 0
                if ua != ub { return ua }
                let fa = favorites.contains(group: a.id)
                let fb = favorites.contains(group: b.id)
                if fa != fb { return fa }
                return a.name.lowercased() < b.name.lowercased()
            }
        }
        // Every row here is a real person on a real island, read STRAIGHT out
        // of CrossIslandStore — `ContactService.clearForDecoy()` never saw it.
        // A duress session shows only what was seeded, so this bucket is empty
        // there.
        guard !panicPIN.isDecoy else { return out }
        let unread = UnreadStore.shared.allPeerCounts
        // Anything filed under one of our own island's names is not a foreign
        // peer, it is a roster row that got misclassified while the app was
        // running over the CF front (see Multihome.isOwnHost).
        let rows = ContactListViewModel.sortedByNickname(
            ciStore.contactsSnapshot
                .filter { !Multihome.isOwnHost($0.host) }
                .map { c -> Contact in
                    var c = c
                    c.unread = unread[c.uin] ?? 0
                    return c
                }
        )
        for contact in rows {
            if let sid = filed[Sections.peerKey(contact.uin, host: contact.host)] {
                out.filedCross[sid, default: []].append(contact)
            } else {
                out.crossLoose.append(contact)
            }
        }
        return out
    }

    /// Which sections render, in which order.
    ///
    /// `o` ascending, ties by id: one total order every device agrees on. The
    /// built-ins are records in the same array as the user's own sections (that
    /// is how their order syncs), so this is one list, not two.
    private func renderedSections(_ b: HomeBuckets) -> [SectionRow] {
        // ⚠⚠ `!= false`, not `== true`. An island that has not answered yet
        // keeps the cached filing: a chat can only BE filed if the island had a
        // vault when it was filed, and reading "unknown" as "no vault" draws
        // the members of a PIN-gated section, by name and with their unread
        // badges, in Online / Offline / Other islands while the section's own
        // header disappears.
        let showUser = appState.vaultCapability != false
        var out: [SectionRow] = []
        for rec in Sections.orderedSections(sectionsStore.tree) {
            let id = Sections.id(rec)
            let order = Sections.orderOf(rec)
            if Sections.str(rec, "k") == "u" {
                guard showUser else { continue }
                out.append(SectionRow(id: id, order: order, isUser: true, title: Sections.str(rec, "n") ?? ""))
                continue
            }
            // A section behind a PIN keeps its header whether or not it holds
            // anything: a header that appears only when there is something
            // inside announces exactly what the user asked to hide.
            let pinned = sectionPinned(id)
            switch id {
            case Sections.sysSaved:
                // Saved Messages is a menu entry here and a section on Android.
                // Its record rides along untouched: dropping it would delete
                // that client's ordering.
                continue
            case Sections.sysFav:
                if !pinned && b.favGroups.isEmpty && vm.favoriteContacts.isEmpty { continue }
            case Sections.sysCI:
                if !pinned && b.crossLoose.isEmpty { continue }
            case Sections.sysArchive:
                if !pinned && b.archivedGroups.isEmpty && vm.archivedContacts.isEmpty { continue }
            case Sections.sysGroups, Sections.sysOnline, Sections.sysOffline:
                break
            default:
                // A built-in id from a newer client: keep the record, draw
                // nothing.
                continue
            }
            out.append(SectionRow(id: id, order: order, isUser: false, title: builtinTitle(id)))
        }
        return out
    }

    private func builtinTitle(_ id: String) -> String {
        switch id {
        case Sections.sysFav: return "contact_list.section.favorites".localized
        case Sections.sysCI: return "contact_list.section.cross_island".localized
        case Sections.sysGroups: return "contact_list.section.groups".localized
        case Sections.sysOnline: return "contact_list.section.online".localized
        case Sections.sysOffline: return "contact_list.section.offline".localized
        case Sections.sysArchive: return "contact_list.section.archive".localized
        default: return ""
        }
    }

    private func sectionTitle(_ id: String) -> String {
        if let rec = Sections.recordFor(sectionsStore.tree, id), Sections.str(rec, "k") == "u" {
            return Sections.str(rec, "n") ?? ""
        }
        return builtinTitle(id)
    }

    @ViewBuilder
    private func sectionView(_ rec: SectionRow, _ b: HomeBuckets) -> some View {
        switch rec.id {
        case Sections.sysFav:
            sectionShell(rec, count: b.favGroups.count + vm.favoriteContacts.count) {
                ForEach(b.favGroups) { groupRowItem(for: $0) }
                ForEach(vm.favoriteContacts) { contactRowItem(for: $0) }
            }
        case Sections.sysCI:
            sectionShell(
                rec,
                count: b.crossLoose.count,
                unreadBadge: b.crossLoose.reduce(0) { $0 + ($1.unread > 0 ? 1 : 0) }
            ) {
                ForEach(b.crossLoose) { contactRowItem(for: $0) }
            }
        case Sections.sysGroups:
            sectionShell(rec, count: b.normalGroups.count, plusAction: { showCreateGroup = true }) {
                if b.normalGroups.isEmpty {
                    createFirstGroupRow
                } else {
                    ForEach(b.normalGroups) { groupRowItem(for: $0) }
                }
            }
        case Sections.sysOnline:
            sectionShell(rec, count: vm.online.count) {
                ForEach(vm.online) { contactRowItem(for: $0) }
            }
        case Sections.sysOffline:
            sectionShell(rec, count: vm.offline.count, unreadBadge: vm.offlineUnreadContacts) {
                ForEach(vm.offline) { contactRowItem(for: $0) }
            }
        case Sections.sysArchive:
            sectionShell(rec, count: b.archivedGroups.count + vm.archivedContacts.count) {
                ForEach(b.archivedGroups) { groupRowItem(for: $0) }
                ForEach(vm.archivedContacts) { contactRowItem(for: $0) }
            }
        default:
            userSection(rec, b)
        }
    }

    @ViewBuilder
    private func userSection(_ rec: SectionRow, _ b: HomeBuckets) -> some View {
        let cs = vm.filedContacts[rec.id] ?? []
        let gs = b.filedGroups[rec.id] ?? []
        let cis = b.filedCross[rec.id] ?? []
        let total = cs.count + gs.count + cis.count
        sectionShell(
            rec,
            count: total,
            unreadBadge: (cs + cis).reduce(0) { $0 + ($1.unread > 0 ? 1 : 0) },
            plusAction: { pickerSection = rec.id }
        ) {
            if total == 0 {
                // An empty user section still renders, header and plus and all:
                // the user made it on purpose. This differs from Archive and
                // Favorites, which hide when empty.
                Text("sections.empty".localized)
                    .font(.caption)
                    .foregroundColor(Theme.Color.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Metrics.rowHPad)
                    .padding(.vertical, 10)
                    .wallpaperSurface(Theme.Color.bgPrimary, wallpaperSurfaceMode)
            } else {
                ForEach(gs) { groupRowItem(for: $0) }
                ForEach(cs) { contactRowItem(for: $0) }
                ForEach(cis) { contactRowItem(for: $0) }
            }
        }
    }

    /// The header, the gate and the rows of any section, built-in or not.
    @ViewBuilder
    private func sectionShell<Rows: View>(
        _ rec: SectionRow,
        count: Int,
        unreadBadge: Int = 0,
        plusAction: (() -> Void)? = nil,
        @ViewBuilder rows: () -> Rows
    ) -> some View {
        let pinned = sectionPinned(rec.id)
        let locked = pinned && !unlockedSections.contains(rec.id)
        // A device with no PIN configured cannot honour the flag another device
        // set. It shows the key glyph and, on expand, one line and a way past.
        let noticeOpen = locked && !panicPIN.isConfigured && noticeSections.contains(rec.id)
        // ⚠ A PIN-gated section does not consult the stored fold state at all.
        // It is collapsed until the PIN is answered and open for as long as
        // that answer lives in view memory -- ALWAYS collapsed again on the
        // next open, whatever the user last did to the header.
        let collapsed = pinned ? locked : isCollapsed(rec.id)
        VStack(spacing: 0) {
            sectionHeader(
                rec, count: count, unreadBadge: unreadBadge, plusAction: plusAction,
                pinned: pinned, locked: locked, collapsed: collapsed && !noticeOpen
            )
            if noticeOpen {
                lockedWithoutPINRow(rec)
            } else if !collapsed {
                rows()
            }
        }
    }

    @ViewBuilder
    private func sectionHeader(
        _ rec: SectionRow, count: Int, unreadBadge: Int,
        plusAction: (() -> Void)?, pinned: Bool, locked: Bool, collapsed: Bool
    ) -> some View {
        let header = Button {
            if locked && panicPIN.isConfigured {
                // The sheet animates its own presentation; wrapping this one
                // would put the state flip in a fold transaction for nothing.
                pinGateSection = rec.id
            } else if locked {
                // No PIN on this device: the header opens the notice, never the
                // rows.
                withAnimation(Self.foldAnimation) {
                    if noticeSections.contains(rec.id) {
                        noticeSections.remove(rec.id)
                    } else {
                        noticeSections.insert(rec.id)
                    }
                }
            } else if pinned {
                // Unlocked and open: the tap puts the gate back. Nothing is
                // written -- the unlocked set is view memory and the fold state
                // of a gated section is not stored.
                withAnimation(Self.foldAnimation) {
                    // Discarded on purpose: a bare remove would become the
                    // closure's return value and withAnimation would infer
                    // Result == String?, clashing with the Void branches.
                    _ = unlockedSections.remove(rec.id)
                }
            } else {
                withAnimation(Self.foldAnimation) {
                    setCollapsed(rec.id, !isCollapsed(rec.id))
                }
            }
        } label: {
            HStack(spacing: 6) {
                CollapseChevron(collapsed: collapsed)
                Text(rec.title.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Theme.Color.textSecondary)
                    .lineLimit(1)
                // ⚠ While locked, NO member count and NO unread badge. Either
                // one is a leak of exactly what the user hid.
                if !locked {
                    Text("(\(count))")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.Color.textSecondary)
                }
                Spacer()
                if reorderingSections {
                    reorderControls(for: rec)
                }
                if pinned {
                    // The same key glyph Archive has always used. Never a
                    // padlock and never a shield: the flag hides a row, it
                    // encrypts nothing.
                    Image(systemName: "key.fill")
                        .foregroundColor(Theme.Color.accent)
                        .font(.system(size: 13))
                        .accessibilityLabel("sections.locked.title".localized)
                }
                if let plusAction, !locked {
                    Button(action: plusAction) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(Theme.Color.accent)
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("sections.add".localized)
                }
                if unreadBadge > 0 && !locked {
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
            .wallpaperSurface(sectionHeaderColor, wallpaperSurfaceMode)
        }
        // ⚠⚠ NO MENU ON A LOCKED SECTION, and that is the gate itself rather
        // than a nicety. The menu carries "stop asking for a PIN" and "delete
        // section", and neither of them asks for the PIN: on a locked header
        // they turn the gate off in two taps, with no verify call, no failure
        // counter and no cooldown, and then sync `p:0` (or the tombstone) to
        // every other device, where the section stops being gated too. The
        // whole point of the side-effect-free verify keeping the lockout
        // accounting is defeated without a single guess. Unlock first.
        //
        // ⚠ And nothing at all without a vault: an island that does not run one
        // has no menu, no sections and no local-only fallback, because a
        // fallback would create state that syncs badly the day it upgrades.
        if locked || appState.vaultCapability != true || panicPIN.isDecoy {
            header
        } else {
            header.contextMenu { sectionMenu(rec) }
        }
    }

    /// The section is gated behind the app PIN on THIS device.
    ///
    /// ⚠ Under duress nothing is gated. The gate verifies the REAL PIN, so
    /// asking for it in a decoy session rejects the coercer's decoy PIN as
    /// "wrong" and announces that a second PIN exists. This is what
    /// `archiveLocked` already did, kept.
    private func sectionPinned(_ id: String) -> Bool {
        if panicPIN.isDecoy { return false }
        if let flag = Sections.pinFlag(sectionsStore.tree, id) { return flag }
        // The slot has no opinion yet. Archive is the one section this client
        // has gated whenever a PIN was configured since long before the flag
        // existed, so it keeps doing that; `SectionsVault.sync` writes the
        // opinion out as a real `p:1` on the first read of the slot, which is
        // what carries it to the other clients.
        return id == Sections.sysArchive && panicPIN.isConfigured
    }

    /// What a section does before the user has ever touched its header.
    ///
    /// ⚠ Offline folds by default EXCEPT in a decoy session: the seeded roster
    /// is a handful of contacts and Offline is the only section they can land
    /// in, so the default folded the whole duress view away behind one header
    /// and the decoy opened on an empty-looking chat list. Read live rather
    /// than stored, which is the reason the store keeps a CHOICE per section
    /// instead of a set of "ids that differ from the default".
    private func defaultCollapsed(_ id: String) -> Bool {
        switch id {
        case Sections.sysArchive: return true
        case Sections.sysOffline: return !panicPIN.isDecoy
        default: return false
        }
    }

    /// One curve for every fold: header taps, the PIN gate opening and
    /// re-locking, the no-PIN notice rows and the audio-rooms strip. The
    /// rows' .transition (contactRowItem) only animates when the toggle
    /// mutation runs inside a transaction, so every toggle SITE wraps in
    /// withAnimation with this. Deliberately NOT an ambient .animation on
    /// the LazyVStack: that would also animate scroll-driven lazy
    /// realization and every unrelated layout change.
    static let foldAnimation = Animation.easeInOut(duration: 0.22)

    private func isCollapsed(_ id: String) -> Bool {
        collapseStore.isCollapsed(id, default: defaultCollapsed(id))
    }

    /// ⚠ Only ever called for a section that is NOT behind a PIN. A gated
    /// section's fold state is not stored anywhere (design §3): it is `locked`
    /// on every entry to this screen, and the unlocked state is view memory.
    private func setCollapsed(_ id: String, _ value: Bool) {
        collapseStore.set(id, collapsed: value)
    }

    /// One line and a way past, for a section another device gated while this
    /// one has no PIN to check against. Honest: a speed bump that says so.
    @ViewBuilder
    private func lockedWithoutPINRow(_ rec: SectionRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("sections.locked.nopin".localized)
                .font(.caption)
                .foregroundColor(Theme.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("sections.locked.open_anyway".localized) {
                withAnimation(Self.foldAnimation) {
                    noticeSections.remove(rec.id)
                    unlockedSections.insert(rec.id)
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(Theme.Color.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Metrics.rowHPad)
        .padding(.vertical, 10)
        .wallpaperSurface(Theme.Color.bgPrimary, wallpaperSurfaceMode)
    }

    // MARK: - The section menu

    @ViewBuilder
    private func sectionMenu(_ rec: SectionRow) -> some View {
        Button {
            reorderingSections.toggle()
        } label: {
            Label("sections.menu.reorder".localized, systemImage: "arrow.up.arrow.down")
        }
        Button {
            newSectionText = ""
            showNewSection = true
        } label: {
            Label("sections.menu.new".localized, systemImage: "folder.badge.plus")
        }
        // A device with no PIN configured cannot honour the flag, so it does
        // not offer to set one.
        if panicPIN.isConfigured {
            Button {
                if sectionPinned(rec.id) {
                    applySections { Sections.setPinned($0, rec.id, on: false) }
                } else {
                    pinConfirmSection = rec.id
                }
            } label: {
                Label(
                    (sectionPinned(rec.id) ? "sections.menu.pin.off" : "sections.menu.pin").localized,
                    systemImage: "key"
                )
            }
        }
        if rec.isUser {
            Button {
                renameSectionText = rec.title
                renameSectionID = rec.id
            } label: {
                Label("sections.menu.rename".localized, systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive) {
                deleteSectionID = rec.id
            } label: {
                Label("sections.menu.delete".localized, systemImage: "trash")
            }
            .tint(.red)
        }
    }

    /// Reorder is a MODE with arrows rather than a drag, deliberately. The
    /// headers live inside a `LazyVStack` that materialises and drops rows as
    /// the list scrolls, and a drag gesture on a lazy header fights the scroll
    /// view for the same touch; the web ships the same arrows next to its drag
    /// for the same reason. One write per move, debounced and coalesced.
    @ViewBuilder
    private func reorderControls(for rec: SectionRow) -> some View {
        HStack(spacing: 2) {
            Button { moveSection(rec.id, by: -1) } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("sections.move_up".localized)
            Button { moveSection(rec.id, by: 1) } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("sections.move_down".localized)
        }
        .foregroundColor(Theme.Color.accent)
    }

    private var reorderBar: some View {
        HStack(spacing: 8) {
            Text("sections.reorder.hint".localized)
                .font(.caption)
                .foregroundColor(Theme.Color.textSecondary)
            Spacer()
            Button("sections.reorder.done".localized) { reorderingSections = false }
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.Color.accent)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .wallpaperSurface(Theme.Color.bgSecondary, wallpaperSurfaceMode)
    }

    // MARK: - Section edits

    /// Every local edit goes through here: it patches the cached tree, repaints
    /// at the speed of the tap, and pushes to the island behind the paint.
    /// `deferred` coalesces a burst (moving sections about) into one put.
    private func applySections(deferred: Bool = false, _ edit: (SectionsTree) throws -> SectionsTree) {
        do {
            _ = try SectionsVault.mutate(edit, deferred: deferred)
        } catch let e as SectionsError {
            sectionsErrorText = "sections.err.\(e.code)".localized
        } catch {
            sectionsErrorText = "common.error".localized
        }
    }

    private func commitNewSection() {
        let name = newSectionText
        newSectionText = ""
        guard !Sections.clampName(name).isEmpty else { return }
        applySections { try Sections.createSection($0, name: name) }
    }

    private func commitRenameSection() {
        guard let id = renameSectionID else { return }
        let name = renameSectionText
        renameSectionID = nil
        guard !Sections.clampName(name).isEmpty else { return }
        applySections { Sections.renameSection($0, id, name: name) }
    }

    private func commitPinOn() {
        guard let id = pinConfirmSection else { return }
        pinConfirmSection = nil
        applySections { Sections.setPinned($0, id, on: true) }
    }

    /// Deleting a section does not touch the chats: they fall back into their
    /// derived sections on the next render.
    private func commitDeleteSection() {
        guard let id = deleteSectionID else { return }
        deleteSectionID = nil
        collapseStore.forget(id)
        unlockedSections.remove(id)
        applySections { Sections.deleteSection($0, id) }
    }

    private func moveSection(_ id: String, by delta: Int) {
        let rendered = renderedSections(homeBuckets())
        guard let at = rendered.firstIndex(where: { $0.id == id }) else { return }
        let target = at + delta
        guard target >= 0 && target < rendered.count else { return }
        place(id, nextTo: rendered[target].id, after: delta > 0)
    }

    /// `o` moves in steps of 1024 and a move takes the midpoint between the new
    /// neighbours. When they are less than 2 apart there is no room left, so
    /// every section is renormalised to `index * 1024`: a normal
    /// last-writer-wins write, rare, and it converges.
    private func place(_ id: String, nextTo anchor: String, after: Bool) {
        let rest = Sections.orderedSections(sectionsStore.tree).filter { Sections.id($0) != id }
        guard let ai = rest.firstIndex(where: { Sections.id($0) == anchor }) else { return }
        let at = after ? ai + 1 : ai
        let step = Sections.orderStep
        let before = at > 0 ? rest[at - 1] : nil
        let next = at < rest.count ? rest[at] : nil
        let lo = before.map { Sections.orderOf($0) } ?? (next.map { Sections.orderOf($0) - 2 * step } ?? 0)
        let hi = next.map { Sections.orderOf($0) } ?? (before.map { Sections.orderOf($0) + 2 * step } ?? step)
        if hi - lo < 2 {
            var ids = rest.map { Sections.id($0) }
            ids.insert(id, at: at)
            var orders: [String: Int] = [:]
            for (i, sid) in ids.enumerated() { orders[sid] = i * step }
            applySections(deferred: true) { Sections.setOrder($0, orders) }
            return
        }
        applySections(deferred: true) { Sections.setOrder($0, [id: (lo + hi) / 2]) }
    }

    // MARK: - Rows

    @ViewBuilder
    private func groupRowItem(for group: RCQGroup) -> some View {
        PressableRow(
            onTap: { path.append(group) },
            onLongPress: { openPreview(.group(group)) }
        ) {
            GroupRow(group: group, surface: wallpaperSurfaceMode)
        }
    }

    private var createFirstGroupRow: some View {
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
            .wallpaperSurface(Theme.Color.bgPrimary, wallpaperSurfaceMode)
        }
    }

    /// The audio-rooms strip folds and remembers it like every other section.
    /// It has no record in the sections tree (it is not a chat list section the
    /// vault knows about), so it carries an id of its own.
    private var audioRoomsSection: some View {
        let collapsedAudioRooms = isCollapsed(SectionCollapseStore.audioRoomsID)
        return VStack(spacing: 0) {
            Button {
                withAnimation(Self.foldAnimation) {
                    setCollapsed(SectionCollapseStore.audioRoomsID, !collapsedAudioRooms)
                }
            } label: {
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
                .wallpaperSurface(sectionHeaderColor, wallpaperSurfaceMode)
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
                        .wallpaperSurface(Theme.Color.bgPrimary, wallpaperSurfaceMode)
                    }
                } else {
                    ForEach(audioRooms.rooms) { room in
                        AudioRoomRow(room: room, surface: wallpaperSurfaceMode)
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
                                ShareLink(
                                    item: String(format: "audio_room.share.body".localized, room.name, room.joinKey)
                                ) {
                                    Label("audio_room.menu.share_key".localized, systemImage: "square.and.arrow.up")
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

    /// Big-blank fallback shown to fresh accounts whose contact AND
    /// group lists are both empty. Without it the new user lands on
    /// a screen full of "(0)" section headers and a floating capsule
    /// with no obvious next move. The CTA opens the same Add Contact
    /// sheet the bottom bar's "+" button would.
    private var emptyState: some View {
        VStack(spacing: 14) {
            // Rooms to walk into, before anything about contacts: nobody arrives
            // with friends already here, and every new account used to be
            // dropped into one beta room for exactly this reason. Now it is a
            // choice (founder, 05.09).
            DiscoverGroupsStrip { joined in
                appState.pendingOpenGroupID = joined.id
            }
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
        // The one block on this screen with no fill of its own. Without a
        // wallpaper this paints the colour it was already standing on, so it
        // looks identical; with one it stops being loose text on a photograph.
        .wallpaperSurface(Theme.Color.bgPrimary, wallpaperSurfaceMode)
    }

    /// Held cross-island requests count towards the pending banner — but never
    /// in a decoy session: each one carries a real `uin@host`, a self-asserted
    /// name and a plaintext preview of what they wrote.
    private var visibleCIRequests: Int {
        panicPIN.isDecoy ? 0 : ciRequests.requestCount
    }

    private var pendingBanner: some View {
        let total = vm.pendingCount + visibleCIRequests
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
            .wallpaperSurface(Theme.Color.bgSecondary, wallpaperSurfaceMode)
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
        // ⚠ Not for somebody the person has filed into a section of their own.
        // A contact lives in exactly ONE bucket, and a user section outranks
        // both favourites and archive, so these two did nothing visible while
        // still claiming they had: "Add to favourites" left them exactly where
        // they were, and archiving would have yanked them out of the section
        // they were deliberately put in (founder, 01.09).
        let filedInOwnSection = vm.sectionIndex[Sections.peerKey(contact.uin, host: contact.host)] != nil
        if !filedInOwnSection {
            out.append(ContextAction(
                title: (favorites.contains(peer: contact.uin)
                        ? "contact_list.ctx.remove_favorite"
                        : "contact_list.ctx.add_favorite").localized,
                systemImage: favorites.contains(peer: contact.uin) ? "star.slash" : "star"
            ) { favorites.toggle(peer: contact.uin) })
        }
        out.append(ContextAction(
            title: (muted ? "contact_list.ctx.unmute" : "contact_list.ctx.mute").localized,
            systemImage: muted ? "bell" : "bell.slash"
        ) { sound.toggleMute(thread: thread) })
        if !filedInOwnSection {
            out.append(ContextAction(
                title: (archive.contains(peer: contact.uin)
                        ? "contact_list.ctx.unarchive"
                        : "contact_list.ctx.archive").localized,
                systemImage: archive.contains(peer: contact.uin) ? "tray.and.arrow.up" : "archivebox"
            ) { archive.toggle(peer: contact.uin) })
        }
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
    /// How this row paints its own ground. Flat by default; over a home
    /// wallpaper the row becomes a translucent frosted band so the wallpaper
    /// is visible THROUGH the list rather than only in the gaps between
    /// sections, which is what "the section containers stay a flat theme
    /// colour" was describing.
    var surface: WallpaperSurface = .none
    @ObservedObject private var sound = SoundService.shared
    @ObservedObject private var reactionInbox = ReactionInboxStore.shared
    @ObservedObject private var mentionInbox = MentionInboxStore.shared
    @ObservedObject private var aliasStore = ContactAliasStore.shared

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
                PersonAvatarView(
                    mediaID: contact.avatarMediaID,
                    keyBase64: contact.avatarKeyResolved,
                    status: contact.status,
                    host: contact.host,
                    size: 28,
                    crossIsland: contact.host != nil,
                    // Feeds the App Group thumbnail the notification extension
                    // puts on this person's system notifications.
                    cacheForUIN: contact.uin
                )
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
                    // My own name for them wins over the nickname they chose
                    // (device-only, see ContactAliasStore).
                    Text(aliasStore.displayName(for: contact.uin, fallback: contact.nickname, host: contact.host))
                        .font(Theme.Font.nickname)
                        .foregroundColor(contact.status == .offline ? Theme.Color.textSecondary : Theme.Color.textPrimary)
                    BadgeMark(kind: contact.badge)
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
                    Text(verbatim: "\(contact.uin)")
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
                    } else {
                        // Two things worth saying and room for one, so they take
                        // turns (founder). Before this a status message won
                        // outright, which hid the last seen for about a third of
                        // offline contacts; sharing the line was the next try and
                        // it truncated. Server already gates the last seen by
                        // visibility - null means hidden, online users get null.
                        let seen: String? = (contact.status == .offline)
                            ? contact.lastSeen.map { "· " + String(format: "contact.last_seen".localized, Self.relativeLastSeen($0)) }
                            : nil
                        let msg: String? = (contact.statusMessage?.isEmpty == false) ? "· " + contact.statusMessage! : nil
                        if let seen, let msg {
                            AltText(a: seen, b: msg)
                                .font(.caption2)
                                .foregroundColor(Theme.Color.textSecondary)
                        } else if let one = seen ?? msg {
                            Text(one)
                                .font(msg != nil && seen == nil ? .caption2.italic() : .caption2)
                                .foregroundColor(Theme.Color.textSecondary)
                                .lineLimit(1)
                        }
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
        }
        .padding(.horizontal, Theme.Metrics.rowHPad)
        .padding(.vertical, Theme.Metrics.rowVPad)
        .wallpaperSurface(Theme.Color.bgPrimary, surface)
    }

    @ViewBuilder
    private var statusIcon: some View {
        StatusIcon(status: contact.status, size: 28, crossIsland: contact.host != nil)
    }

    /// Coarse "last seen" buckets — minutes / hours / days. Anything
    /// over a week falls back to a localised short date so the row
    /// doesn't read "9999h ago" for long-dormant contacts.
    /// "Last seen" in WORDS, not numbers (founder, 31.08).
    ///
    /// ⚠ "was here 47 minutes ago" is an activity pattern: read it a few times
    /// a day and you know when someone wakes up, commutes and sleeps. Nobody
    /// needs that to decide whether to write - "recently" answers the same
    /// question. The island already floors what it serves to the hour (A7), so
    /// the minutes were never real; printing them dressed a floored hour up as
    /// precision it does not have. Same buckets on every client.
    fileprivate static func relativeLastSeen(_ date: Date) -> String {
        LastSeenText.relative(date)
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
/// Same, for the section a sheet is about.
private struct SectionID: Identifiable, Hashable { let id: String }
private struct JoinGroupTrigger: Identifiable, Hashable { let id: Int }

private struct GroupRow: View {
    let group: RCQGroup
    var surface: WallpaperSurface = .none
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
                    BadgeMark(kind: group.badge)
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
                Text(Self.memberLabel(group.memberCount)
                    + (group.host.map { " · \($0)" } ?? ""))
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
        .wallpaperSurface(Theme.Color.bgPrimary, surface)
    }

    /// "12 members" up to 999, then the compact form: "1K members",
    /// "2.1K members". A five-figure room printed in full wrapped this row on a
    /// narrow phone, and the thresholds are the web's to the character
    /// (`Int.compactCount`), so one room never reads two different sizes on two
    /// clients.
    ///
    /// The rule itself lives in `MemberCountLabel` now, because the chat
    /// header, the search results and the forward picker print the same count
    /// and have to print it the same way.
    private static func memberLabel(_ count: Int) -> String {
        MemberCountLabel.text(count)
    }
}

/// One row in the Audio Rooms section. Speaker glyph + name + active
/// count (highlighted green when ≥1 person inside) + chevron. Owner
/// gets a tiny crown badge so they remember which rooms only they
/// can delete.
private struct AudioRoomRow: View {
    let room: AudioRoom
    var surface: WallpaperSurface = .none
    @StateObject private var audio = AudioRoomService.shared
    /// Flips the copy glyph to a tick for a moment, the way Settings does it
    /// for the UIN. Without it the button gave a haptic and looked untouched.
    @State private var keyCopied = false

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
            // The join key was printed as plain text next to the counter, and
            // the only way to take it was a long press nothing advertised. Two
            // visible controls, same as Android after 12393e5.
            Button {
                UIPasteboard.general.string = room.joinKey
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                withAnimation(.easeOut(duration: 0.12)) { keyCopied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                    withAnimation(.easeOut(duration: 0.2)) { keyCopied = false }
                }
            } label: {
                Image(systemName: keyCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 15))
                    .foregroundColor(keyCopied ? Theme.Color.accent : Theme.Color.textSecondary)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("audio_room.menu.copy_key".localized)
            ShareLink(item: String(format: "audio_room.share.body".localized, room.name, room.joinKey)) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 15))
                    .foregroundColor(Theme.Color.textSecondary)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("audio_room.menu.share_key".localized)
        }
        .padding(.horizontal, Theme.Metrics.rowHPad)
        .padding(.vertical, Theme.Metrics.rowVPad)
        .wallpaperSurface(Theme.Color.bgPrimary, surface)
    }
}

/// Small "through relays" badge in the contact list header. Slow
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

/// Press feedback that belongs to the ROW.
///
/// `onLongPressGesture(pressing:)` fires on touch DOWN, including the
/// touch-down that turns out to be a scroll, and again when the press is
/// cancelled. While the pressed row's id lived in a `@State` on
/// `ContactListView`, that meant putting a finger anywhere on the list rewrote
/// root state and re-ran the whole screen's body, twice per scroll, before a
/// single pixel had moved. A row's own press is nobody else's business, which
/// is the rule Telegram's list follows and the reason its list does not
/// stutter under a finger.
///
/// The id-prefix bookkeeping ("fav-peer:", "arch-group:") went with it: a row
/// that owns its state cannot be confused with its duplicate in another
/// section.
private struct PressableRow<Content: View>: View {
    let onTap: () -> Void
    let onLongPress: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var pressed = false

    var body: some View {
        content()
            .contentShape(Rectangle())
            .scaleEffect(pressed ? 0.96 : 1.0)
            .animation(.spring(response: 0.18, dampingFraction: 0.86), value: pressed)
            .onTapGesture(perform: onTap)
            .onLongPressGesture(
                minimumDuration: 0.18,
                // No haptic on press-down: it fires on every tap and every
                // scroll start.
                pressing: { pressed = $0 },
                perform: onLongPress
            )
    }
}

/// The home wallpaper, painted from the PER-THEME preset table.
///
/// Deliberately not `ChatBackgroundView(home: true)`: that one paints the flat
/// `ChatBackgrounds` list, whose colours are authored once and therefore
/// contradict the active theme half the time. See `Theme.Wallpaper`. The
/// custom-image branch is the same behaviour to the byte.
private struct HomeWallpaperView: View {
    @ObservedObject private var bg = ChatBackgroundStore.shared
    @State private var custom: UIImage?

    var body: some View {
        let selection = bg.homeSelection
        Group {
            if let colors = Theme.Wallpaper.colors(forSelection: selection) {
                LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
            } else if selection == "custom", let custom {
                Image(uiImage: custom).resizable().scaledToFill()
            }
        }
        .task(id: "\(selection)#\(bg.homeCustomStamp)") {
            guard selection == "custom" else { custom = nil; return }
            // Read, decode AND rasterise off the main actor: a `.task`
            // inherits the view's actor, and a 12MP gallery photo used to be
            // lazily decoded during the home screen's first frame - part of
            // the after-unlock freeze for anyone with a custom wallpaper.
            // The renderer pass forces the decode down to screen size, so
            // the main thread receives finished pixels, not a JPEG promise.
            let path = ChatBackgroundStore.imageURL(home: true).path
            let screen = await MainActor.run { UIScreen.main.bounds.size }
            custom = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let raw = UIImage(contentsOfFile: path) else { return nil }
                let scale = max(screen.width / max(raw.size.width, 1),
                                screen.height / max(raw.size.height, 1))
                guard scale < 1 else { return raw.preparingForDisplay() ?? raw }
                let size = CGSize(width: raw.size.width * scale, height: raw.size.height * scale)
                let format = UIGraphicsImageRendererFormat()
                format.opaque = true
                return UIGraphicsImageRenderer(size: size, format: format).image { _ in
                    raw.draw(in: CGRect(origin: .zero, size: size))
                }
            }.value
        }
    }
}

/// What the account switcher knows about ONE account without asking anybody.
///
/// The island's name is served by `/server/info`, and only the account that is
/// currently active can call it, and every other row in the switcher is an
/// island this process is not talking to. Cached, that stops mattering: each
/// account writes its own card while it is live, and the switcher draws all of
/// them from disk. Same division the desktop makes
/// (`web-chat/src/lib/contacts-cache.ts`: "there is nothing to fetch").
struct AccountCard: Codable {
    /// What the island calls itself. Empty when it has never answered or its
    /// operator left the field blank; callers fall back to the host.
    var islandName: String
    /// Digest of the island's logo, "" for none. Same story as the name: only
    /// the ACTIVE account can read `/server/info`, so this is the one moment it
    /// can be recorded, and the switcher then draws every island from disk.
    ///
    /// Decodes as "" on a card written before this field existed, which reads
    /// as "no logo" and draws the lettered tile: an upgrade shows the old
    /// switcher until the first `/server/info` of the new run lands.
    var islandLogoVersion: String = ""
    /// The account's OWN avatar on that island, so the switcher can draw a face
    /// per row instead of a letter. Written from presence while the account is
    /// active, exactly like the island fields: a row for another island is one
    /// this process is not talking to and cannot fetch anything for.
    var avatarMediaID: String = ""
    var avatarMediaKey: String = ""
    var host: String
    var uin: Int?
    var nickname: String
}

/// Per-account, survives a cold start, written only when a fact changes.
///
/// UserDefaults rather than the sealed roster files: an island's public name
/// and the host you already typed to reach it are not secrets, and the switcher
/// has to be able to draw a row for an account whose panic-PIN data key is not
/// unlocked in this process. Nothing here is written in a decoy session.
enum AccountCardCache {
    private static let prefix = "rcq.accountCard.v1."

    private static func key(_ id: UUID) -> String { prefix + id.uuidString }

    static func card(for id: UUID) -> AccountCard? {
        guard let data = UserDefaults.standard.data(forKey: key(id)) else { return nil }
        return try? JSONDecoder().decode(AccountCard.self, from: data)
    }

    static func record(_ fresh: AccountCard, for id: UUID) {
        // A half-known card (the boot has the host but `/server/info` has not
        // landed yet) must not overwrite a full one from the last run, or the
        // switcher would lose the island's name for a second on every launch.
        //
        // ⚠ The logo version rides the SAME guard, and only on the same
        // condition. An empty version otherwise means one of two things and
        // they are opposites: "the reply has not landed" (keep what we had) and
        // "the operator removed the logo" (believe it). `islandName` being
        // empty too is what tells them apart, because a landed reply from an
        // island that has a name fills that in whether or not it has a picture.
        if fresh.islandName.isEmpty, let existing = card(for: id), !existing.islandName.isEmpty {
            var merged = fresh
            merged.islandName = existing.islandName
            if merged.islandLogoVersion.isEmpty { merged.islandLogoVersion = existing.islandLogoVersion }
            // Same reasoning for the face: on a card written before the reply
            // landed, empty means "not read yet", not "the avatar was removed".
            if merged.avatarMediaID.isEmpty {
                merged.avatarMediaID = existing.avatarMediaID
                merged.avatarMediaKey = existing.avatarMediaKey
            }
            write(merged, for: id)
            return
        }
        write(fresh, for: id)
    }

    private static func write(_ card: AccountCard, for id: UUID) {
        guard let data = try? JSONEncoder().encode(card) else { return }
        UserDefaults.standard.set(data, forKey: key(id))
    }

    /// Dropped along with the rest of an account's local state.
    static func forget(_ id: UUID) {
        UserDefaults.standard.removeObject(forKey: key(id))
    }
}

/// An island's face: the logo its operator set, or its initial on a colour
/// derived from its host.
///
/// Islands had no picture on the wire at all until 2026-08-24, so this was
/// generated and nothing else. It still is for every island whose operator has
/// not set one, and that fallback is the point rather than a leftover: an
/// island is always drawn by something, and the something is per-island either
/// way. Rounded square, not a circle: a person is a circle and a group is a
/// circle, and an island is neither.
///
/// ⚠⚠ FALLS BACK IN FOUR DIRECTIONS AND NEVER SHOWS A BROKEN IMAGE:
///   * an island with no logo -> `logoVersion` is "" -> the tile;
///   * an island too old to know the field -> it is absent from the reply,
///     which decodes to nil -> the tile;
///   * an island that has not answered yet, or at all -> no version on its
///     card -> the tile, on the FIRST frame, replaced in place if a logo lands;
///   * bytes that arrive but do not decode, or a 404 -> `IslandLogoStore`
///     answers nil -> the tile.
/// There is no state in which this draws an empty box.
struct IslandAvatarView: View {
    let name: String
    let host: String
    /// `logo_version` from that island's `/server/info`, off the account's own
    /// card for a row this process is not talking to. "" draws the tile.
    var logoVersion: String = ""
    var size: CGFloat = 28

    /// Seeded from the decrypted-free memory cache so a hot logo is already
    /// there on the first frame instead of flashing the tile, exactly as
    /// `PersonAvatarView` seeds itself from `MediaService.cachedImage`. Switcher
    /// rows and the pill redraw constantly.
    @State private var image: UIImage?

    init(name: String, host: String, logoVersion: String = "", size: CGFloat = 28) {
        self.name = name
        self.host = host
        self.logoVersion = logoVersion
        self.size = size
        _image = State(initialValue: IslandLogoStore.shared.cached(host: host, version: logoVersion))
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            } else {
                tile
            }
        }
        .task(id: "\(host)|\(logoVersion)") {
            image = await IslandLogoStore.shared.load(host: host, version: logoVersion)
        }
    }

    private var tile: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(Self.tint(for: host))
            .frame(width: size, height: size)
            .overlay(
                Text(Self.initial(name: name, host: host))
                    .font(.system(size: size * 0.46, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            )
    }

    static func initial(name: String, host: String) -> String {
        let source = name.isEmpty ? host : name
        // First LETTER, not first character: a name that opens with an emoji or
        // a bracket would otherwise draw a tile with punctuation on it.
        guard let ch = source.first(where: { $0.isLetter || $0.isNumber }) else { return "#" }
        return String(ch).uppercased()
    }

    /// ⚠ FNV-1a over the host, never `hashValue`: Swift's hashing is seeded per
    /// process, so an island would change colour on every launch. The other
    /// three clients run the identical hash for the identical reason, so an
    /// island with no logo is the same colour on all four.
    static func tint(for host: String) -> Color {
        var hash: UInt32 = 2_166_136_261
        for byte in host.lowercased().utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        // Spread over the wheel, but kept off full saturation so the tile reads
        // as chrome rather than as an alert.
        return Color(
            hue: Double(hash % 360) / 360,
            saturation: 0.46,
            brightness: 0.62
        )
    }
}

/// The islands' own pictures: fetched once per version, then read off the disk.
///
/// Same shape as an account avatar (`MediaService`): an NSCache in front, a
/// file cache behind it, and a network read only on a miss of both. What is
/// different, and why this is not `MediaService`, is that a logo is PUBLIC
/// PLAINTEXT: no media id, no AES key, nothing to decrypt. Running it through
/// the media path would mean opening something that was never sealed.
///
/// ⚠ KEYED ON HOST **AND** VERSION. An operator can replace their island's
/// logo, and a cache keyed on the host alone would keep the old one until the
/// app was reinstalled. The version is a digest of the picture, so a new logo
/// is a new key, a new URL and a new file.
///
/// Nothing here can fail into a broken image: every miss, refusal, timeout and
/// unreadable file answers nil, and nil draws the lettered tile.
final class IslandLogoStore {
    static let shared = IslandLogoStore()

    /// `nonisolated(unsafe)` for the same reason `MediaService`'s caches are:
    /// NSCache is documented thread-safe but the Foundation overlay does not
    /// mark it Sendable, and `cached(host:version:)` is peeked from a SwiftUI
    /// `init` where an actor hop is not available.
    nonisolated(unsafe) private let memory: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        // A phone holds a handful of islands, and a logo is at most 64 KB by
        // the island's own cap. The whole store is smaller than one photo.
        c.countLimit = 16
        return c
    }()

    /// Islands whose logo failed this run, so a dead or logo-less island is not
    /// re-asked on every appearance of every row that names it. Cleared when
    /// the version changes, because that is a different picture.
    nonisolated(unsafe) private let missed = NSCache<NSString, NSNumber>()

    private var dir: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("island-logos", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func key(_ host: String, _ version: String) -> String { "\(host)|\(version)" }

    private func file(_ host: String, _ version: String) -> URL {
        let safe = key(host, version).replacingOccurrences(
            of: "[^A-Za-z0-9_|.-]", with: "_", options: .regularExpression
        )
        return dir.appendingPathComponent(safe)
    }

    /// What we already hold, with no disk and no network. Read from a SwiftUI
    /// `init` to seed the first frame.
    ///
    /// ⚠ A version we do not know yet is not a reason to draw the lettered
    /// tile. `logo_version` arrives with `/server/info`, so on a cold start,
    /// and on every switch of accounts before that answer lands, the picture
    /// was replaced by the tile and then swapped back a moment later - the
    /// island's face on the home screen "sometimes there, sometimes not"
    /// (founder, 02.09). The last picture this island served is the right
    /// thing to show while we find out whether it changed.
    func cached(host: String, version: String) -> UIImage? {
        guard !host.isEmpty else { return nil }
        if !version.isEmpty, let hit = memory.object(forKey: key(host, version) as NSString) {
            return hit
        }
        return lastKnown(host: host)
    }

    /// The newest logo this device has ever decoded for `host`, whatever
    /// version it belonged to. Memory first; then the file the last successful
    /// load wrote, which survives a restart.
    private func lastKnown(host: String) -> UIImage? {
        if let v = lastVersion.object(forKey: host as NSString) as String?,
           let hit = memory.object(forKey: key(host, v) as NSString) {
            return hit
        }
        guard let data = try? Data(contentsOf: latestFile(host)), let img = Self.decode(data) else {
            return nil
        }
        return img
    }

    /// host → the version whose picture we hold, for [lastKnown].
    nonisolated(unsafe) private let lastVersion = NSCache<NSString, NSString>()

    /// One file per island holding the last logo it served, keyed by host
    /// alone. Small (the same picture as the versioned copy) and worth its
    /// bytes: it is what makes a cold start draw the island rather than a
    /// letter.
    private func latestFile(_ host: String) -> URL {
        let safe = host.replacingOccurrences(of: "[^A-Za-z0-9_.-]", with: "_", options: .regularExpression)
        return dir.appendingPathComponent("latest_\(safe)")
    }

    /// The island's logo, from memory, then disk, then the island. nil means
    /// "draw the tile", which covers every case worth distinguishing to a
    /// caller: no logo, an island too old for the field, an island that did not
    /// answer, or bytes that did not decode. None of them is an error.
    func load(host: String, version: String) async -> UIImage? {
        guard !host.isEmpty else { return nil }
        // No version yet: `/server/info` has not answered. Show what this
        // island served last rather than the tile; the `task` that fetches
        // this view runs again with the real version when it arrives.
        guard !version.isEmpty else { return lastKnown(host: host) }
        let k = key(host, version)
        if let hit = memory.object(forKey: k as NSString) { return hit }
        if missed.object(forKey: k as NSString) != nil { return nil }
        let path = file(host, version)
        if let data = try? Data(contentsOf: path), let img = Self.decode(data) {
            memory.setObject(img, forKey: k as NSString)
            lastVersion.setObject(version as NSString, forKey: host as NSString)
            return img
        }
        // `?v=` so a changed logo is a changed URL: no cache in the chain, ours
        // or a middlebox's, can hand back the old picture.
        var comps = URLComponents(string: "https://\(host)/server/logo")
        comps?.queryItems = [URLQueryItem(name: "v", value: version)]
        guard let url = comps?.url else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("image/*", forHTTPHeaderField: "Accept")
        do {
            // ⚠⚠ `IslandHTTP`, NOT `URLSession.shared`. The host here is any
            // island the user has been shown a join confirm for, and the shared
            // session carries no proxy configuration at all: on a censored
            // network this picture was the one request that stepped outside a
            // tunnel the user had deliberately engaged, handing that island our
            // real IP and the local network its SNI before anybody had joined
            // anything. It is also why the ACTIVE island's own logo silently
            // never arrived on a network where everything else worked.
            let (data, resp) = try await IslandHTTP.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  http.expectedContentLength <= Int64(Self.maxBytes),
                  data.count <= Self.maxBytes,
                  let img = Self.decode(data) else {
                missed.setObject(1, forKey: k as NSString)
                return nil
            }
            try? data.write(to: path, options: .atomic)
            try? data.write(to: latestFile(host), options: .atomic)
            trim()
            memory.setObject(img, forKey: k as NSString)
            lastVersion.setObject(version as NSString, forKey: host as NSString)
            return img
        } catch {
            missed.setObject(1, forKey: k as NSString)
            return nil
        }
    }

    /// Ceiling on a logo, four times the 64 KB our own admin path accepts.
    ///
    /// ⚠⚠ THAT CAP IS OURS, NOT THEIRS. It is enforced where an operator
    /// UPLOADS a logo to an island we run; what a foreign island answers this
    /// unauthenticated GET with is whatever it likes, and this cache is drawn
    /// BEFORE the user has an account there. Loose on purpose: the point is not
    /// to police somebody else's operator, it is that nothing unbounded is ever
    /// held or written.
    private static let maxBytes = 256 * 1024

    /// Every logo file this store may keep, all islands together. Android holds
    /// the identical 4 MB on the identical directory.
    private static let maxDiskBytes = 4 * 1024 * 1024

    /// Longest edge we ever decode to. The picture is drawn at 56 pt at its
    /// largest, so this is already generous on a 3x screen.
    private static let maxPixels = 256

    /// Untrusted bytes to a picture, or nil.
    ///
    /// ⚠⚠ NOT `UIImage(data:)`. That accepts anything ImageIO parses and
    /// decodes at the size the FILE declares, so a 60 KB PNG (inside the cap
    /// above, not an oversized body at all) whose header says 25000x25000
    /// costs about 2.5 GB of pixels the moment SwiftUI draws it into the 56 pt
    /// frame, and the app is killed before the user has joined the island. Two
    /// gates, the same two Android puts on the same bytes (`isJpegOrPng` plus
    /// `rememberSampledBitmap(maxPx = 256)`): the format must be one the
    /// islands actually serve, and the decode is a thumbnail with a hard pixel
    /// ceiling rather than a full-size one.
    private static func decode(_ data: Data) -> UIImage? {
        guard isImage(data), let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        // The declared size, read from the header without decoding a pixel. A
        // thumbnail request alone would be enough for memory, but refusing an
        // absurd claim outright is cheaper than asking ImageIO to scale it.
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            let w = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
            let h = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
            if w > 8192 || h > 8192 { return nil }
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// PNG, JPEG, GIF or WebP by its first bytes, which is the set an island
    /// accepts on upload. The `Content-Type` is the island's claim about its own
    /// body and is not consulted.
    private static func isImage(_ d: Data) -> Bool {
        if d.count < 12 { return false }
        let b = [UInt8](d.prefix(12))
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return true }   // PNG
        if b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return true }                 // JPEG
        if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46, b[3] == 0x38 { return true }   // GIF8
        // RIFF....WEBP
        if b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
           b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return true }
        return false
    }

    /// Evict oldest files until the directory is under the cap.
    ///
    /// ⚠ `logo_version` is a string the island chooses, so a replaced logo
    /// leaves its predecessor behind under a different name, and a hostile
    /// island can mint a fresh version on every `/server/info`, which is a fresh
    /// key, a fresh miss and a fresh file every time. Without this the
    /// directory only grows. Android bounds the same directory the same way.
    private func trim() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return }
        var sized = files.map { url -> (URL, Int, Date) in
            let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return (url, v?.fileSize ?? 0, v?.contentModificationDate ?? .distantPast)
        }
        var total = sized.reduce(0) { $0 + $1.1 }
        guard total > Self.maxDiskBytes else { return }
        sized.sort { $0.2 < $1.2 }
        for (url, size, _) in sized {
            if total <= Self.maxDiskBytes { break }
            try? fm.removeItem(at: url)
            total -= size
        }
    }

    /// Forget every island's picture.
    ///
    /// ⚠ The file names are HOSTS. A burn deletes the account's own record of
    /// the islands it visited, and leaving this directory behind would mean an
    /// app that reports everything erased while the container still holds one
    /// file per island host the device ever drew, a private self-hosted one
    /// included.
    func wipe() {
        memory.removeAllObjects()
        missed.removeAllObjects()
        try? FileManager.default.removeItem(at: dir)
    }

    /// The island's face as a flat `UIImage`, for a place that can only take
    /// one: a `Menu` row, whose label SwiftUI hands to UIKit as a `UIMenu`
    /// action with an image slot and no room for a view.
    ///
    /// Falls back to DRAWING the lettered tile rather than to no icon at all,
    /// so every row in the switcher carries its island's mark whether or not
    /// that island set a logo. Rendered `.alwaysOriginal`: a UIMenu image is
    /// treated as a template by default and a coloured logo would come out as
    /// a grey silhouette.
    @MainActor
    func menuIcon(name: String, host: String, version: String, size: CGFloat = 24) -> UIImage {
        if let logo = cached(host: host, version: version) {
            return Self.rounded(logo, size: size).withRenderingMode(.alwaysOriginal)
        }
        let initial = IslandAvatarView.initial(name: name, host: host)
        let tint = UIColor(IslandAvatarView.tint(for: host))
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { ctx in
            let rect = CGRect(x: 0, y: 0, width: size, height: size)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: size * 0.28)
            tint.setFill()
            path.fill()
            let font = UIFont.systemFont(ofSize: size * 0.5, weight: .bold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.white,
            ]
            let text = initial as NSString
            let box = text.size(withAttributes: attrs)
            text.draw(
                at: CGPoint(x: (size - box.width) / 2, y: (size - box.height) / 2),
                withAttributes: attrs
            )
            _ = ctx
        }.withRenderingMode(.alwaysOriginal)
    }

    /// Square-crop and round a logo to the menu's icon size. A UIMenu draws its
    /// image at whatever size it is given, so an operator's 256px mark has to
    /// be brought down here rather than by the menu.
    private static func rounded(_ image: UIImage, size: CGFloat) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { _ in
            let rect = CGRect(x: 0, y: 0, width: size, height: size)
            UIBezierPath(roundedRect: rect, cornerRadius: size * 0.28).addClip()
            // Aspect-FILL, so a non-square logo is cropped rather than
            // letterboxed onto a transparent bar.
            let scale = max(size / image.size.width, size / image.size.height)
            let w = image.size.width * scale
            let h = image.size.height * scale
            image.draw(in: CGRect(x: (size - w) / 2, y: (size - h) / 2, width: w, height: h))
        }
    }
}

#Preview {
    ContactListView()
}

/// Open rooms, biggest first, each joinable in one tap. Drawn only when the
/// island answered with something: no heading over an empty strip.
private struct DiscoverGroupsStrip: View {
    let onJoined: (RCQGroup) -> Void
    @ObservedObject private var groups = GroupService.shared
    @State private var rooms: [GroupService.Preview] = []
    @State private var joining: Int? = nil
    @State private var loaded = false

    var body: some View {
        // ⚠ The loader hangs off a zero-height view that is ALWAYS in the tree.
        // On a `Group { if rooms.isEmpty }` there was nothing to appear, so
        // `.task` never fired and the strip never asked: seen on the QA
        // simulator as an empty home with the island answering fine.
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 0)
                .task { await load() }
                .onChange(of: groups.groups.count) { _ in
                    if rooms.isEmpty { Task { await load() } }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    if rooms.isEmpty { Task { await load() } }
                }
            if !rooms.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("contact_list.discover.title".localized.uppercased())
                        .font(.caption.weight(.medium))
                        .foregroundColor(Theme.Color.textSecondary)
                        .padding(.horizontal, 20)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(rooms) { room in
                                card(room)
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }
                .padding(.bottom, 10)
            }
        }
    }

    private func load() async {
        if loaded && !rooms.isEmpty { return }
        loaded = true
        let got = await groups.discover()
        if !got.isEmpty { rooms = got }
    }

    private func card(_ room: GroupService.Preview) -> some View {
        VStack(spacing: 8) {
            GroupAvatarView(mediaID: room.avatarMediaID, keyBase64: room.avatarMediaKey, size: 48)
            HStack(spacing: 3) {
                Text(room.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.Color.textPrimary)
                    .lineLimit(1)
                BadgeMark(kind: room.badge, size: 12)
            }
            Text(MemberCountLabel.text(room.memberCount))
                .font(.system(size: 11))
                .foregroundColor(Theme.Color.textSecondary)
            Button {
                guard joining == nil else { return }
                joining = room.id
                Task {
                    let result = await groups.join(groupID: room.id)
                    joining = nil
                    if case .success(let g) = result {
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        onJoined(g)
                    } else {
                        // Refused (closed since, blocked): the card goes, the
                        // rest of the strip stays.
                        rooms.removeAll { $0.id == room.id }
                    }
                }
            } label: {
                Text("contact_list.discover.join".localized)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(joining == room.id ? Theme.Color.textSecondary : Theme.Color.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
        }
        .frame(width: 132)
        .padding(12)
        .background(Theme.Color.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

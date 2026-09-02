import PhotosUI
import SwiftUI
import UIKit

// MARK: - Settings search (founder item 28)

/// Every row Settings search can reach, across all three settings screens.
///
/// ⚠ This enum is the contract, not a convenience. A new setting means a new
/// case here plus an entry in the owning screen's `searchEntries`, and the
/// DEBUG check in `SettingsSearchIndex` trips the moment those two disagree.
/// That is the whole reason the index is written by hand next to the rows
/// instead of being scraped out of the view tree: a scraper silently loses a
/// row that renders inside a condition, and nobody finds out until a user
/// cannot find their setting. Android's index is the same shape.
enum SettingsRow: String, CaseIterable, Hashable {
    // Settings (root)
    case theme, textSize, appIcon, chatBackground, homeBackground, animatedAvatars
    case sounds, language
    case privacyScreen, networkScreen, notificationsScreen, blockedUsers
    case historyFile, historyClear
    case uinShop, myUINs, islandRules
    case recoveryPhrase, linkedDevices, backupIsland, burnAccount
    case about, bugBounty, myReports
    // Privacy pane
    case profileVisibility, profileCard, lastSeen, relayCalls, strangers
    case genderVisibility, groupInvites, callPolicy, readReceipts
    case howItWorks, panicPIN, migrate, hallOfFame
    // Network pane
    case accounts, stealth, onion, localProxy, customServer, diagnostics, sharedRelays
    // Notifications
    case contactRequests, mutedSenders
}

/// One searchable row: what it is called on screen, where it lives, and how to
/// get there.
struct SettingsSearchEntry: Identifiable, Hashable {
    /// Which screen holds the row. The root screen scrolls to it; the others
    /// are sheets, opened with the row handed through as the highlight.
    enum Destination: Hashable { case settings, privacy, network, notifications }

    let row: SettingsRow
    /// Localization key of the row's VISIBLE label. Search matches what the
    /// user actually reads, so a retitled row stays findable for free.
    let titleKey: String
    /// Localization key of the section header the row sits under, used as the
    /// breadcrumb under each result.
    let sectionKey: String
    let destination: Destination

    var id: SettingsRow { row }

    var title: String { titleKey.localized }
    var section: String { sectionKey.localized }

    /// Comma-separated synonyms, so "пин" reaches a row labelled "PIN-код" and
    /// "wallpaper" reaches "Фон чата". Derived from the case name rather than
    /// stored, so an entry cannot be added without its alias slot existing.
    var aliasKey: String { "settings.search.alias.\(row.rawValue)" }

    /// Empty when the locale ships no alias line. `.localized` hands back the
    /// KEY itself for a missing entry, and matching against that would let
    /// "alias" or "settings" hit every row at once.
    var aliases: String {
        let value = aliasKey.localized
        return value == aliasKey ? "" : value
    }
}

enum SettingsSearchIndex {
    /// Built from the three screens' own lists, each declared beside the rows
    /// it describes.
    static let all: [SettingsSearchEntry] =
        SettingsView.searchEntries
        + PrivacySettingsView.searchEntries
        + NotificationsSettingsView.searchEntries

    /// Case- and diacritic-insensitive; "ё" folds onto "е" so a query typed
    /// either way lands.
    private static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every whitespace-separated token has to appear somewhere in the row's
    /// label or its aliases, so "фон чата" narrows instead of widening.
    static func matches(_ query: String) -> [SettingsSearchEntry] {
        let tokens = fold(query).split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return [] }
        let hits = all.filter { entry in
            let hay = fold(entry.title) + " \u{1F}" + fold(entry.aliases)
            return tokens.allSatisfy { hay.contains($0) }
        }
        // A label that starts with what was typed is what the user meant;
        // everything else keeps the screen order, which is where they would
        // have scrolled to find it.
        let head = fold(tokens[0])
        return hits.sorted { a, b in
            let sa = fold(a.title).hasPrefix(head)
            let sb = fold(b.title).hasPrefix(head)
            return sa == sb ? false : sa
        }
    }

    #if DEBUG
    /// Fails the moment a row exists that search cannot reach. Called from the
    /// Settings screen so it runs on any debug build that opens it.
    static func assertComplete() {
        let indexed = Set(all.map(\.row))
        let missing = SettingsRow.allCases.filter { !indexed.contains($0) }
        assert(missing.isEmpty, "Settings search index misses: \(missing.map(\.rawValue))")
    }
    #endif
}

extension View {
    /// Marks a row as a search destination: it becomes the scroll anchor for
    /// its `SettingsRow`, and wears a brief accent wash while search is
    /// pointing at it.
    ///
    /// `listRowBackground` on the row overrides the one the Section sets, so
    /// the normal state has to repaint `bgSecondary` itself.
    func settingsSearchRow(_ row: SettingsRow, highlight: SettingsRow?) -> some View {
        self
            .id(row)
            .listRowBackground(
                (highlight == row ? Theme.Color.accent.opacity(0.22) : Theme.Color.bgSecondary)
                    .animation(.easeInOut(duration: 0.25), value: highlight)
            )
    }
}

/// Search over every settings row, opened from the magnifier in the Settings
/// title bar. Picking a result closes this sheet and hands the row back; the
/// caller does the navigating once this is off screen.
struct SettingsSearchSheet: View {
    let onPick: (SettingsSearchEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var focused: Bool

    private var results: [SettingsSearchEntry] { SettingsSearchIndex.matches(query) }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                // Field at the BOTTOM, results above it. With the field on
                // top every match was a reach across the whole screen from the
                // key just pressed, and the taller the phone the worse it got.
                // Down here it rides the keyboard, which SwiftUI lifts it over,
                // and the results end where the thumb already is.
                VStack(spacing: 0) {
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        placeholder("settings.search.empty.idle".localized)
                    } else if results.isEmpty {
                        placeholder("search.empty.no_match".localized)
                    } else {
                        List(results) { entry in
                            Button {
                                onPick(entry)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.title)
                                        .foregroundColor(Theme.Color.textPrimary)
                                    Text(entry.section)
                                        .font(.caption2)
                                        .foregroundColor(Theme.Color.textSecondary)
                                }
                            }
                            .listRowBackground(Theme.Color.bgSecondary)
                        }
                        .scrollContentBackground(.hidden)
                        .listStyle(.plain)
                    }
                    field
                }
            }
            .navigationTitle("settings.search.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel".localized) { dismiss() }
                }
            }
        }
        .onAppear { focused = true }
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(Theme.Color.textSecondary)
            TextField("settings.search.placeholder".localized, text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($focused)
                .foregroundColor(Theme.Color.textPrimary)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(Theme.Color.textSecondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.Color.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func placeholder(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.footnote)
                .foregroundColor(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var theme = ThemeManager.shared
    @StateObject private var sound = SoundService.shared
    @StateObject private var auth = AuthService.shared
    @StateObject private var presence = PresenceService.shared
    // Own profile picture, plus the picker that sets it. Seeded from the
    // island on appear so the header is right on a cold start rather than
    // only after the profile screen has been opened.
    // Seeded synchronously from the last known values, then refreshed in the
    // background. Reading them only from `/users/me/info` meant the header drew
    // the status flower on every appearance and swapped in the picture a moment
    // later, which reads as "it loads every time" even though the image itself
    // was cached all along.
    // ⚠ NOT from UserDefaults in a decoy session. UserDefaults is outside the
    // encrypted store, so the cached picture there belongs to the REAL account
    // — and the decoy header rendered it, which means the screen a coerced user
    // shows to someone was wearing their own face. Founder's report. In a decoy
    // session the header starts blank and only ever holds what was picked
    // inside that session.
    @State private var ownAvatarID: String? =
        PanicPINService.shared.isDecoy ? nil : UserDefaults.standard.string(forKey: "rcq.ownAvatarID")
    @State private var ownAvatarKey: String? =
        PanicPINService.shared.isDecoy ? nil : UserDefaults.standard.string(forKey: "rcq.ownAvatarKey")
    /// A picture chosen inside a decoy session. Held in memory for the life of
    /// the session only: it never reaches the island, `UserDefaults` or any
    /// store on disk, because anything written down is a record that a decoy
    /// was used.
    @State private var decoyAvatarData: Data?
    /// Bumped on every decoy pick. `PersonAvatarView` seeds its image in
    /// `init`, so the header only redraws when its identity changes.
    @State private var decoyAvatarGeneration = 0
    @State private var avatarPick: PhotosPickerItem?
    @State private var avatarBusy = false
    @State private var confirmClearHistory = false
    @State private var confirmBurn = false
    @State private var burning = false
    @State private var showAbout = false
    @State private var showUINShop = false
    @State private var showMyUINs = false
    /// How many numbers this account holds besides the one it uses; decides
    /// whether "My numbers" is worth a row on an island with no shop.
    @State private var heldUINCount = 0
    @State private var showBugBounty = false
    @State private var showSoundSheet = false
    @State private var showLinkWeb = false
    @State private var showPrivacy = false
    @State private var showNetwork = false
    @State private var showNotifications = false
    @State private var showMyReports = false
    @State private var showIslandRules = false
    @State private var burnFailed = false
    @State private var showBlockedUsers = false
    @State private var showRecovery = false
    @State private var showLinkedDevices = false
    @State private var showBackupIsland = false
    @State private var showBackupFile = false
    @State private var uinCopied: Bool = false
    /// Settings search (item 28). `pendingSearchPick` is held back until the
    /// search sheet is really gone: routing straight from the result tap puts
    /// a dismiss and a present into one transaction on the same host and UIKit
    /// drops one of them, the same trap `LinkedDevicesView`'s QR scanner hit.
    @State private var showSearch = false
    @State private var pendingSearchPick: SettingsSearchEntry?
    /// The row search jumped to, tinted for a moment so the eye lands on it.
    @State private var highlightedRow: SettingsRow?
    /// Handed to the sub-screens when the picked row lives inside one of them.
    @State private var privacyHighlight: SettingsRow?
    @State private var notificationsHighlight: SettingsRow?
    @StateObject private var language = LanguageManager.shared
    @ObservedObject private var panicPIN = PanicPINService.shared
    /// The island row reads the pin store, and a handshake behind the screen
    /// can change what is on file; `revision` is what redraws it.
    @ObservedObject private var islandTrust = IslandTrust.shared
    @State private var trustCopied: Bool = false
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                ScrollViewReader { proxy in
                    Form {
                        Section {
                            identityHeader
                        }
                        .listRowBackground(Theme.Color.bgSecondary)

                        appearanceSection
                        soundSection
                        languageSection
                        screensSection
                        historySection
                        uinSection
                        islandSection
                        accountSection

                        // Web-chat link hidden for App Store submission. Flip #if false → true when web is ready.
                        #if false
                        Section {
                            Button {
                                showLinkWeb = true
                            } label: {
                                HStack {
                                    Image(systemName: "laptopcomputer.and.iphone")
                                        .foregroundColor(Theme.Color.accent)
                                    Text("settings.link_web".localized).foregroundColor(Theme.Color.textPrimary)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundColor(Theme.Color.textSecondary)
                                }
                            }
                        } footer: {
                            Text("settings.link_web.footer".localized)
                        }
                        .listRowBackground(Theme.Color.bgSecondary)
                        #endif

                        aboutAndBugBountySection
                    }
                    .scrollContentBackground(.hidden)
                    // The scroll proxy only exists inside the reader, so the
                    // jump is driven off the highlight rather than done in
                    // `routeSearchPick` where the pick is handled.
                    .onChange(of: highlightedRow) { row in
                        guard let row else { return }
                        withAnimation { proxy.scrollTo(row, anchor: .center) }
                    }
                }
            }
            .navigationTitle("settings.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".localized) { dismiss() }
                }
                // Item 28: the magnifier took this slot from the share-my-link
                // button (founder's call). Search is what people reach for in
                // a list this long; the contact link still travels by QR.
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSearch = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(Theme.Color.accent)
                    }
                    .accessibilityLabel("settings.search.title".localized)
                }
            }
            .sheet(isPresented: $showSearch, onDismiss: routeSearchPick) {
                SettingsSearchSheet { entry in pendingSearchPick = entry }
            }
            .sheet(isPresented: $showAbout) { AboutSheet() }
            .fullScreenCover(isPresented: $showUINShop) { UINShopView() }
            // Refreshed on dismiss: releasing a number inside the sheet
            // changes the count this screen prints, and without this the row
            // kept the pre-release figure until Settings was reopened.
            .sheet(isPresented: $showMyUINs, onDismiss: { Task { await refreshHeldUINCount() } }) {
                MyUINsView()
            }
            .task {
                #if DEBUG
                SettingsSearchIndex.assertComplete()
                #endif
                // Everything "visibility after leaving" left behind on this
                // device when the feature was removed.
                PresenceRemovalCleanup.runOnce()
                await refreshHeldUINCount()
            }
            .sheet(isPresented: $showBugBounty) { BugBountySheet() }
            .sheet(isPresented: $showSoundSheet) { SoundSettingsSheet() }
            .sheet(isPresented: $showLinkWeb) {
                LinkWebView()
                    .presentationDetents([.height(360), .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showPrivacy, onDismiss: { privacyHighlight = nil }) {
                PrivacySettingsView(pane: .privacy, highlight: privacyHighlight)
            }
            .sheet(isPresented: $showNetwork, onDismiss: { privacyHighlight = nil }) {
                PrivacySettingsView(pane: .network, highlight: privacyHighlight)
            }
            .sheet(isPresented: $showNotifications, onDismiss: { notificationsHighlight = nil }) {
                NotificationsSettingsView(highlight: notificationsHighlight)
            }
            .sheet(isPresented: $showMyReports) { MyReportsView() }
            .alert("settings.account.burn_failed".localized, isPresented: $burnFailed) {
                Button("common.ok".localized, role: .cancel) {}
            }
            .sheet(isPresented: $showIslandRules) {
                IslandRulesSheet(
                    title: appState.serverName.isEmpty ? islandHost : appState.serverName,
                    rules: appState.serverWelcome
                )
            }
            .sheet(isPresented: $showBlockedUsers) { BlockedUsersView() }
            .sheet(isPresented: $showRecovery) { RecoveryPhraseView() }
            .sheet(isPresented: $showLinkedDevices) { LinkedDevicesView() }
            .sheet(isPresented: $showBackupIsland) { BackupIslandView().environmentObject(appState) }
            .sheet(isPresented: $showBackupFile) { BackupFileView() }
            .confirmationDialog(
                "settings.history.confirm.title".localized,
                isPresented: $confirmClearHistory,
                titleVisibility: .visible
            ) {
                Button("settings.history.confirm.button".localized, role: .destructive) {
                    MessageStore.shared.clearAll()
                }
                Button("common.cancel".localized, role: .cancel) {}
            } message: {
                Text("settings.history.confirm.message".localized)
            }
            .confirmationDialog(
                burnTitle,
                isPresented: $confirmBurn,
                titleVisibility: .visible
            ) {
                Button("settings.account.burn.confirm".localized, role: .destructive) {
                    Task {
                        burning = true
                        // The island decides whether anything was erased. If it
                        // did not answer, nothing local is touched and the
                        // screen stays open saying so, rather than closing on
                        // "deleted" over an account that is still there.
                        let done = await AppState.shared.burnAccount(requireServerErase: true)
                        burning = false
                        if done { dismiss() } else { burnFailed = true }
                    }
                }
                Button("common.cancel".localized, role: .cancel) {}
            } message: {
                Text(burnMessage)
            }
        }
        // Apply the active theme to the Settings sheet itself. A
        // `.sheet` is its own presentation context and does NOT
        // inherit the root's `.preferredColorScheme`, so flipping the
        // theme picker used to restyle the app behind the sheet but
        // leave the Settings window on the old scheme until reopened.
        // `theme` is observed, so this re-applies live on every flip.
        .preferredColorScheme(theme.theme.colorScheme)
    }

    /// Runs once the search sheet is really off screen (see
    /// `pendingSearchPick`). A row on this screen scrolls into view and lights
    /// up for a moment; a row that lives inside one of the sub-screens opens
    /// that screen with the highlight handed through.
    private func routeSearchPick() {
        guard let entry = pendingSearchPick else { return }
        pendingSearchPick = nil
        switch entry.destination {
        case .settings:
            // Cleared first so picking the SAME row twice still changes the
            // value, and the scroll in `onChange` fires again.
            highlightedRow = nil
            DispatchQueue.main.async {
                highlightedRow = entry.row
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                    if highlightedRow == entry.row {
                        withAnimation { highlightedRow = nil }
                    }
                }
            }
        case .privacy:
            privacyHighlight = entry.row
            showPrivacy = true
        case .network:
            privacyHighlight = entry.row
            showNetwork = true
        case .notifications:
            notificationsHighlight = entry.row
            showNotifications = true
        }
    }

    // MARK: - sections
    //
    // Every Section below used to sit inline in `body`. The comments on
    // `historySection` and `aboutAndBugBountySection` were already saying the
    // Form was at the Swift type-checker's ceiling before item 28 hung a
    // search anchor off each row, so the rest followed them out.

    @ViewBuilder
    private var appearanceSection: some View {
        Section("settings.appearance".localized) {
            Picker("settings.appearance.theme".localized, selection: $theme.theme) {
                ForEach(AppTheme.allCases) { t in
                    Text(t.label).tag(t)
                }
            }
            .settingsSearchRow(.theme, highlight: highlightedRow)
            // #3 accessibility: in-app text size (scales the whole
            // app via Dynamic Type; "System" follows the OS setting).
            Picker("settings.textsize".localized, selection: $theme.textSize) {
                ForEach(AppTextSize.allCases) { s in
                    Text(s.label).tag(s)
                }
            }
            .settingsSearchRow(.textSize, highlight: highlightedRow)
            if AppIconManager.shared.supportsAlternateIcons {
                NavigationLink {
                    AppIconView()
                } label: {
                    HStack {
                        Text("settings.app_icon".localized)
                        Spacer()
                        Text(AppIconManager.shared.currentOption.displayName)
                            .font(.caption)
                            .foregroundColor(Theme.Color.textSecondary)
                    }
                }
                .settingsSearchRow(.appIcon, highlight: highlightedRow)
            }
            NavigationLink {
                ChatBackgroundPicker()
            } label: {
                Text("settings.chat_bg".localized)
            }
            .settingsSearchRow(.chatBackground, highlight: highlightedRow)
            NavigationLink {
                ChatBackgroundPicker(home: true)
            } label: {
                Text("settings.home_bg".localized)
            }
            .settingsSearchRow(.homeBackground, highlight: highlightedRow)
            Toggle(isOn: $theme.animateAvatars) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("settings.animate_avatars".localized)
                        .foregroundColor(Theme.Color.textPrimary)
                    Text("settings.animate_avatars.footer".localized)
                        .font(.caption)
                        .foregroundColor(Theme.Color.textSecondary)
                }
            }
            .settingsSearchRow(.animatedAvatars, highlight: highlightedRow)
        }
    }

    @ViewBuilder
    private var soundSection: some View {
        Section("settings.sound".localized) {
            Button {
                showSoundSheet = true
            } label: {
                HStack {
                    Text("settings.sound.row".localized)
                        .foregroundColor(Theme.Color.textPrimary)
                    Spacer()
                    Text(sound.isEnabled
                         ? "settings.sound.row.on".localized
                         : "settings.sound.row.off".localized)
                        .foregroundColor(Theme.Color.textSecondary)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(Theme.Color.textSecondary)
                }
            }
            .settingsSearchRow(.sounds, highlight: highlightedRow)
        }
    }

    @ViewBuilder
    private var languageSection: some View {
        Section {
            // Menu (not Picker) so per-row .disabled greys out unfinished languages.
            Menu {
                ForEach(AppLanguage.available) { lang in
                    Button {
                        language.set(lang)
                    } label: {
                        HStack {
                            Text(lang.nativeName)
                            if lang == language.current {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .disabled(!lang.isAvailable)
                }
            } label: {
                HStack {
                    Text("settings.language".localized)
                        .foregroundColor(Theme.Color.textPrimary)
                    Spacer()
                    Text(language.current.nativeName)
                        .foregroundColor(Theme.Color.textSecondary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundColor(Theme.Color.textSecondary)
                }
            }
            .settingsSearchRow(.language, highlight: highlightedRow)
        } header: {
            Text("settings.language".localized)
        } footer: {
            Text("settings.language.footer".localized)
        }
    }

    /// The four doors out of Settings: the two privacy panes, notifications
    /// and the blocked list.
    @ViewBuilder
    private var screensSection: some View {
        Section {
            Button {
                showPrivacy = true
            } label: {
                HStack {
                    Image(systemName: "lock.fill").foregroundColor(Theme.Color.accent)
                    Text("settings.privacy".localized)
                        .foregroundColor(Theme.Color.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundColor(Theme.Color.textSecondary)
                }
            }
            .settingsSearchRow(.privacyScreen, highlight: highlightedRow)
            Button {
                showNetwork = true
            } label: {
                HStack {
                    Image(systemName: "network").foregroundColor(Theme.Color.accent)
                    Text("settings.network".localized)
                        .foregroundColor(Theme.Color.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundColor(Theme.Color.textSecondary)
                }
            }
            .settingsSearchRow(.networkScreen, highlight: highlightedRow)
            Button {
                showNotifications = true
            } label: {
                HStack {
                    Image(systemName: "bell.fill").foregroundColor(Theme.Color.accent)
                    Text("settings.notifications".localized)
                        .foregroundColor(Theme.Color.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundColor(Theme.Color.textSecondary)
                }
            }
            .settingsSearchRow(.notificationsScreen, highlight: highlightedRow)
            // Apple UGC guidance 1.2 requires a centralised blocked-users surface.
            Button {
                showBlockedUsers = true
            } label: {
                HStack {
                    Image(systemName: "hand.raised.fill").foregroundColor(.red)
                    Text("settings.blocked_users".localized)
                        .foregroundColor(Theme.Color.textPrimary)
                    Spacer()
                    let count = ContactService.shared.contacts.filter { $0.blocked }.count
                    if count > 0 {
                        Text(verbatim: "\(count)")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(Theme.Color.textSecondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundColor(Theme.Color.textSecondary)
                }
            }
            .settingsSearchRow(.blockedUsers, highlight: highlightedRow)
        } footer: {
            Text("settings.privacy.footer.short".localized)
        }
    }

    /// How many numbers this account holds, off the island.
    ///
    /// A decoy session is forced to zero rather than asked: it has no island
    /// to ask, and a number count is exactly the kind of detail a decoy must
    /// not be able to hint at.
    private func refreshHeldUINCount() async {
        guard !panicPIN.isDecoy else { heldUINCount = 0; return }
        heldUINCount = (await AppState.shared.myUINs())?.owned.count ?? 0
    }

    /// Self-host backends running rcq-server-ref report uin_shop=false via
    /// /server/info and the row hides entirely: operators handle UIN
    /// allocation out of band (Telegram channel, BTCPay, manual assignment)
    /// because the in-app Apple IAP transaction is bound to our developer
    /// account regardless of which backend the user is on. See
    /// project_rcq_monetization_model for the design.
    ///
    /// My numbers has its own condition: it shows whenever this account holds
    /// anything, shop or no shop. An operator who closes the shop must not
    /// strand people on the wrong number, and a self-hoster can hand a member
    /// a second one by hand (POST /admin/uin/grant). Islands too old to answer
    /// /uin/mine leave heldCount at zero and the row stays hidden.
    ///
    /// `serverCapabilities` is whatever the REAL session's boot fetched (a
    /// decoy never calls /server/info), so the shop row would advertise a
    /// storefront for an account that has no island. `heldUINCount` is forced
    /// to 0 there.
    @ViewBuilder
    private var uinSection: some View {
        if (appState.serverCapabilities.uinShop && !panicPIN.isDecoy) || heldUINCount > 0 {
            Section {
                if appState.serverCapabilities.uinShop {
                    Button {
                        showUINShop = true
                    } label: {
                        HStack {
                            Image(systemName: "number.square.fill")
                                .foregroundColor(Theme.Color.accent)
                            Text("settings.uin_shop".localized)
                                .foregroundColor(Theme.Color.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundColor(Theme.Color.textSecondary)
                        }
                    }
                    .settingsSearchRow(.uinShop, highlight: highlightedRow)
                }
                Button {
                    showMyUINs = true
                } label: {
                    HStack {
                        Image(systemName: "tray.full.fill")
                            .foregroundColor(Theme.Color.accent)
                        Text("my_uins.title".localized)
                            .foregroundColor(Theme.Color.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundColor(Theme.Color.textSecondary)
                    }
                }
                .settingsSearchRow(.myUINs, highlight: highlightedRow)
            } footer: {
                // The footer describes the SHOP; without one it would be
                // advertising a storefront this island does not have.
                Text(appState.serverCapabilities.uinShop
                     ? "settings.uin_shop.footer".localized
                     : "my_uins.settings.footer".localized)
            }
        }
    }

    /// The island this account lives on, in its own words. Both fields come
    /// from `/server/info`, both are typed by the operator in the admin panel,
    /// and until this row existed the only place either of them appeared was
    /// the confirm before joining SOMEBODY ELSE'S island, so an operator could
    /// name their island and write its rules and never see them on their own.
    @ViewBuilder
    private var islandSection: some View {
        Section {
            HStack {
                // Was `server.rack`: the same drawing on every island, on the
                // one row whose whole job is to say WHICH island. The
                // operator's logo now, or the lettered tile for an island that
                // set none, which is still a mark of its own rather than one
                // glyph shared by all of them.
                IslandAvatarView(
                    name: appState.serverName,
                    host: islandHost,
                    logoVersion: appState.serverLogoVersion,
                    size: 28
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(appState.serverName.isEmpty ? islandHost : appState.serverName)
                        .foregroundColor(Theme.Color.textPrimary)
                    // The host repeats under a name and nowhere else: two
                    // lines saying the same host is one line of noise.
                    if !appState.serverName.isEmpty {
                        Text(islandHost)
                            .font(.caption)
                            .foregroundColor(Theme.Color.textSecondary)
                    }
                }
            }
            islandTrustRow
            if !appState.serverWelcome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    showIslandRules = true
                } label: {
                    HStack {
                        Image(systemName: "text.book.closed.fill").foregroundColor(Theme.Color.accent)
                        Text("settings.island.rules".localized)
                            .foregroundColor(Theme.Color.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundColor(Theme.Color.textSecondary)
                    }
                }
                .settingsSearchRow(.islandRules, highlight: highlightedRow)
            }
        } header: {
            Text("settings.island".localized)
        }
        .listRowBackground(Theme.Color.bgSecondary)
    }

    @ViewBuilder
    private var accountSection: some View {
        Section {
            Button {
                showRecovery = true
            } label: {
                HStack {
                    Image(systemName: "key.fill").foregroundColor(Theme.Color.accent)
                    Text("settings.account.recovery".localized)
                        .foregroundColor(Theme.Color.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundColor(Theme.Color.textSecondary)
                }
            }
            .settingsSearchRow(.recoveryPhrase, highlight: highlightedRow)
            Button {
                showLinkedDevices = true
            } label: {
                HStack {
                    Image(systemName: "laptopcomputer.and.iphone").foregroundColor(Theme.Color.accent)
                    Text("linkeddevices.title".localized)
                        .foregroundColor(Theme.Color.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundColor(Theme.Color.textSecondary)
                }
            }
            .settingsSearchRow(.linkedDevices, highlight: highlightedRow)
            Button {
                showBackupIsland = true
            } label: {
                HStack {
                    Image(systemName: "externaldrive.badge.icloud").foregroundColor(Theme.Color.accent)
                    Text("multihome.title".localized)
                        .foregroundColor(Theme.Color.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundColor(Theme.Color.textSecondary)
                }
            }
            .settingsSearchRow(.backupIsland, highlight: highlightedRow)
            Button(role: .destructive) {
                confirmBurn = true
            } label: {
                HStack {
                    Image(systemName: "flame")
                    Text(burning ? "settings.account.burning".localized : "settings.account.burn".localized)
                    Spacer()
                    if burning { ProgressView().scaleEffect(0.7) }
                }
            }
            .disabled(burning)
            .settingsSearchRow(.burnAccount, highlight: highlightedRow)
        } header: {
            Text("settings.account".localized)
        } footer: {
            Text("settings.account.footer".localized)
        }
    }

    /// Extracted for the same reason as the section below: adding the second
    /// row here was what tipped `body` past the type-checker's ceiling.
    @ViewBuilder
    private var historySection: some View {
        Section("settings.history".localized) {
            Button {
                showBackupFile = true
            } label: {
                HStack {
                    Image(systemName: "doc.zipper").foregroundColor(Theme.Color.accent)
                    Text("settings.history.file".localized)
                        .foregroundColor(Theme.Color.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundColor(Theme.Color.textSecondary)
                }
            }
            .settingsSearchRow(.historyFile, highlight: highlightedRow)
            Button(role: .destructive) {
                confirmClearHistory = true
            } label: {
                HStack {
                    Image(systemName: "trash")
                    Text("settings.history.clear".localized)
                }
            }
            .settingsSearchRow(.historyClear, highlight: highlightedRow)
        }
    }

    /// Extracted to keep `body` under the Swift type-checker's
    /// complexity ceiling. The Form's other 10+ sections were already
    /// hovering at the limit; folding the bug-bounty section plus the
    /// `BountyCreditsCard` into one closure pushed it over.
    @ViewBuilder
    private var aboutAndBugBountySection: some View {
        Section {
            Button {
                showAbout = true
            } label: {
                HStack {
                    Image(systemName: "info.circle").foregroundColor(Theme.Color.accent)
                    Text("settings.account.about".localized).foregroundColor(Theme.Color.textPrimary)
                    Spacer()
                    Text(appVersion)
                        .font(.caption2)
                        .foregroundColor(Theme.Color.textSecondary)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundColor(Theme.Color.textSecondary)
                }
            }
            .settingsSearchRow(.about, highlight: highlightedRow)
            // An island that runs no report desk gets neither entry: a form the
            // island answers 403 and a screen that stays empty are worse than an
            // absent menu row. Flag comes from /server/info and defaults
            // permissive, so an island older than it keeps both.
            if appState.serverCapabilities.reports {
                Button {
                    showBugBounty = true
                } label: {
                    HStack {
                        Image(systemName: "ladybug.fill").foregroundColor(Theme.Color.accent)
                        Text("settings.account.bug_bounty".localized).foregroundColor(Theme.Color.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundColor(Theme.Color.textSecondary)
                    }
                }
                .settingsSearchRow(.bugBounty, highlight: highlightedRow)
                // Directly under the form that files a report: this is where the
                // person who just filed one looks for the answer. It used to sit
                // up next to Notifications, which is where the answer NOTIFICATION
                // is configured, not where the answer is read (founder, and the
                // same move the Android client made in v0.79).
                Button {
                    showMyReports = true
                } label: {
                    HStack {
                        Image(systemName: "flag.fill").foregroundColor(Theme.Color.accent)
                        Text("settings.my_reports".localized).foregroundColor(Theme.Color.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundColor(Theme.Color.textSecondary)
                    }
                }
                .settingsSearchRow(.myReports, highlight: highlightedRow)
            }
        }
        .listRowBackground(Theme.Color.bgSecondary)
    }

    // MARK: - search index
    //
    // ⚠ Every row above is here, and every row added above belongs here. The
    // DEBUG check in `SettingsSearchIndex` is what catches a row that forgot.
    // Order is screen order, so results that tie fall out top-down.
    static let searchEntries: [SettingsSearchEntry] = [
        .init(row: .theme, titleKey: "settings.appearance.theme",
              sectionKey: "settings.appearance", destination: .settings),
        .init(row: .textSize, titleKey: "settings.textsize",
              sectionKey: "settings.appearance", destination: .settings),
        .init(row: .appIcon, titleKey: "settings.app_icon",
              sectionKey: "settings.appearance", destination: .settings),
        .init(row: .chatBackground, titleKey: "settings.chat_bg",
              sectionKey: "settings.appearance", destination: .settings),
        .init(row: .homeBackground, titleKey: "settings.home_bg",
              sectionKey: "settings.appearance", destination: .settings),
        .init(row: .animatedAvatars, titleKey: "settings.animate_avatars",
              sectionKey: "settings.appearance", destination: .settings),
        .init(row: .sounds, titleKey: "settings.sound.row",
              sectionKey: "settings.sound", destination: .settings),
        .init(row: .language, titleKey: "settings.language",
              sectionKey: "settings.language", destination: .settings),
        .init(row: .privacyScreen, titleKey: "settings.privacy",
              sectionKey: "settings.title", destination: .settings),
        .init(row: .networkScreen, titleKey: "settings.network",
              sectionKey: "settings.title", destination: .settings),
        .init(row: .notificationsScreen, titleKey: "settings.notifications",
              sectionKey: "settings.title", destination: .settings),
        .init(row: .blockedUsers, titleKey: "settings.blocked_users",
              sectionKey: "settings.title", destination: .settings),
        .init(row: .historyFile, titleKey: "settings.history.file",
              sectionKey: "settings.history", destination: .settings),
        .init(row: .historyClear, titleKey: "settings.history.clear",
              sectionKey: "settings.history", destination: .settings),
        .init(row: .uinShop, titleKey: "settings.uin_shop",
              sectionKey: "settings.title", destination: .settings),
        .init(row: .myUINs, titleKey: "my_uins.title",
              sectionKey: "settings.title", destination: .settings),
        .init(row: .islandRules, titleKey: "settings.island.rules",
              sectionKey: "settings.island", destination: .settings),
        .init(row: .recoveryPhrase, titleKey: "settings.account.recovery",
              sectionKey: "settings.account", destination: .settings),
        .init(row: .linkedDevices, titleKey: "linkeddevices.title",
              sectionKey: "settings.account", destination: .settings),
        .init(row: .backupIsland, titleKey: "multihome.title",
              sectionKey: "settings.account", destination: .settings),
        .init(row: .burnAccount, titleKey: "settings.account.burn",
              sectionKey: "settings.account", destination: .settings),
        .init(row: .about, titleKey: "settings.account.about",
              sectionKey: "settings.title", destination: .settings),
        .init(row: .bugBounty, titleKey: "settings.account.bug_bounty",
              sectionKey: "settings.title", destination: .settings),
        .init(row: .myReports, titleKey: "settings.my_reports",
              sectionKey: "settings.title", destination: .settings),
    ]

    /// Read my own picture back from the island. `/users/me` answers with the
    /// owner-self view, which always carries it.
    private func loadOwnAvatar() async {
        // A decoy session has no server account, and `auth.ownUIN` here is the
        // synthetic one. The DuressGate refuses the request anyway; returning
        // first keeps the header from flickering through a failed fetch.
        guard !PanicPINService.shared.isDecoy else { return }
        guard let uin = auth.ownUIN else { return }
        guard let p: UserProfile = try? await APIClient.shared.request("GET", "/users/\(uin)/info") else { return }
        PresenceService.shared.setOwnAvatar(id: p.avatarMediaID, key: p.avatarMediaKey)
        ownAvatarID = p.avatarMediaID
        ownAvatarKey = p.avatarMediaKey
        UserDefaults.standard.set(p.avatarMediaID, forKey: "rcq.ownAvatarID")
        UserDefaults.standard.set(p.avatarMediaKey, forKey: "rcq.ownAvatarKey")
    }

    /// Encrypt + upload the picked image, then hand the island the id and key.
    /// GIFs go up as raw bytes so the frames survive; anything else takes the
    /// still-image path, which JPEG-encodes.
    private func setOwnAvatar(from item: PhotosPickerItem) async {
        // Under duress this PUT /users/me would rename the REAL account's
        // picture and then broadcast it to every real cross-island contact.
        // The gate blocks the request; this stops the spinner ever appearing.
        //
        // But it used to return here and do NOTHING VISIBLE, which is its own
        // tell: a person under duress taps their picture, picks a photo, and
        // the app shrugs. So the decoy session keeps the picture in memory for
        // as long as it lasts. Nothing is uploaded, nothing is written down —
        // a file on disk would be evidence that a decoy exists.
        if PanicPINService.shared.isDecoy {
            decoyAvatarData = try? await item.loadTransferable(type: Data.self)
            decoyAvatarGeneration += 1
            return
        }
        avatarBusy = true
        defer { avatarBusy = false }
        // ⚠ The key is NOT in the body any more. It used to be, and the island
        // stored it in users.avatar_media_key beside the uin and the nickname,
        // so a seized island opened every face it held. The picture is sealed
        // under my profile key, which goes to my contacts over E2E instead.
        // Sending the id ALONE also clears whatever key the island still holds
        // for me, which is what retires the old plaintext one.
        struct Body: Encodable {
            let avatar_media_id: String
        }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            let pk = await ProfileKeyService.shared.ensureMine()
            let res: MediaService.UploadResult
            if AnimatedGIFView.isGIF(data) {
                res = try await MediaService.shared.uploadGIF(data: data, under: pk)
            } else {
                guard let img = UIImage(data: data) else { return }
                res = try await MediaService.shared.uploadImage(img, under: pk)
            }
            let _: UserProfile = try await APIClient.shared.request(
                "PUT", "/users/me",
                body: Body(avatar_media_id: res.mediaID),
            )
            // Hand the key to everyone entitled to it. Detached: the picture is
            // already saved, and one unreachable contact must not cost the rest
            // their copy - they ask with `pkeyask` later.
            Task.detached { await ProfileKeyService.shared.fanOut(keyB64: res.keyBase64) }
            // Through the shared holder, so the main screen's header lights up
            // with the new picture instead of waiting for the next launch.
            PresenceService.shared.setOwnAvatar(id: res.mediaID, key: res.keyBase64)
            ownAvatarID = res.mediaID
            ownAvatarKey = res.keyBase64
            // §5e: the island only tells people ON this island. Every accepted
            // cross-island contact gets the new picture pushed to them — the
            // encrypted blob deposited to THEIR island, the key sealed to them.
            // Detached so the picker stops spinning as soon as the save landed.
            Task { await CrossIslandSender.broadcastProfile() }
        } catch {
            // Silent: the header simply keeps the flower, and the user can try
            // again. A modal here would be louder than the failure deserves.
        }
    }

    /// Pulled out of `identityHeader`: inlined, the picker plus the avatar plus
    /// the surrounding stack blew past what the type-checker will chew through
    /// in one expression.
    @ViewBuilder
    private var avatarPickerButton: some View {
        // `presence.status` is read here rather than inside the picker's label
        // closure: PhotosPicker takes that closure as Sendable, and touching a
        // main-actor property from inside it is an error under Swift 6.
        let status = presence.status
        PhotosPicker(selection: $avatarPick, matching: .images) {
            PersonAvatarView(
                mediaID: ownAvatarID,
                keyBase64: ownAvatarKey,
                status: status,
                size: 48,
                localImageData: decoyAvatarData
            )
            .id(decoyAvatarGeneration)
        }
        .buttonStyle(.plain)
        // Hung on this small view rather than on `body`: the settings form is
        // already at the edge of what the type-checker will solve in one go.
        .task { await loadOwnAvatar() }
        // Single-argument form: the deployment target is below iOS 17, where
        // the two-argument onChange does not exist.
        .onChange(of: avatarPick) { item in
            guard let item else { return }
            Task { await setOwnAvatar(from: item); avatarPick = nil }
        }
    }

    @ViewBuilder
    private var identityHeader: some View {
        HStack(spacing: 12) {
            // The picture is the button, the way every messenger does it, and
            // the status stays ON it rather than being replaced by it.
            avatarPickerButton
            VStack(alignment: .leading, spacing: 4) {
                Text(auth.nickname.isEmpty ? "—" : auth.nickname)
                    .font(.system(.title3, weight: .semibold))
                    .foregroundColor(Theme.Color.textPrimary)
                Button {
                    if let uin = auth.ownUIN {
                        UIPasteboard.general.string = String(uin)
                        UISelectionFeedbackGenerator().selectionChanged()
                        uinCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                            if uinCopied { uinCopied = false }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(verbatim: "\(auth.ownUIN ?? 0)")
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundColor(Theme.Color.textMono)
                        // The tick and the haptic already say it. The word next
                        // to them was the same message a third time.
                        Image(systemName: uinCopied ? "checkmark.circle.fill" : "doc.on.doc")
                            .font(.caption)
                            .foregroundColor(uinCopied ? Theme.Color.accent : Theme.Color.textSecondary)
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var burnTitle: String {
        "settings.account.burn.title".localized
    }

    private var burnMessage: String {
        "settings.account.burn.message".localized
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    /// The island this account lives on.
    ///
    /// ⚠ Deliberately NOT `APIClient.shared.baseURL`. That resolves to the
    /// bypass proxy whenever one is active, and naming the proxy as your island
    /// would be a lie on the one row that exists to answer "where does my
    /// account actually live". The island is the picked backend, proxy or no
    /// proxy — the same value `CustomServerSheet` writes.
    private var islandHost: String {
        let picked = UserDefaults.standard.string(forKey: "rcq.baseURL")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = (picked?.isEmpty == false) ? picked! : APIClient.prodBaseURL
        return URL(string: base)?.host ?? base
    }

    /// How this island is trusted (design §5.3): through a certificate
    /// authority, or by a fingerprint this device holds, with the address to
    /// hand to somebody so they can pin it before their first connection.
    @ViewBuilder
    private var islandTrustRow: some View {
        if let status = islandTrustStatus {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: status.record.mode == .ca ? "checkmark.shield" : "lock.shield")
                    .foregroundColor(Theme.Color.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 6) {
                    Text((status.record.mode == .ca ? "island.trust.settings.ca" : "island.trust.settings.pinned").localized)
                        .foregroundColor(Theme.Color.textPrimary)
                    if status.record.mode == .pinned, let fp = status.record.fp {
                        Text(IslandTrust.displayFingerprint(fp))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(Theme.Color.textMono)
                        Button {
                            UIPasteboard.general.string = IslandTrust.shareAddress(status.endpoint, fingerprint: fp)
                            UISelectionFeedbackGenerator().selectionChanged()
                            trustCopied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                                if trustCopied { trustCopied = false }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: trustCopied ? "checkmark.circle.fill" : "doc.on.doc")
                                Text("island.trust.copy".localized)
                            }
                            .font(.caption)
                            .foregroundColor(trustCopied ? Theme.Color.accent : Theme.Color.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// The store's record for the picked island, or the CA-only verdict for
    /// the flagship and the fronts, which the rule never writes to the store.
    /// Nil until this device has completed a handshake with a custom island.
    private var islandTrustStatus: (endpoint: IslandTrust.Endpoint, record: IslandTrust.Record)? {
        _ = islandTrust.revision
        let picked = UserDefaults.standard.string(forKey: "rcq.baseURL")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = (picked?.isEmpty == false) ? picked! : APIClient.prodBaseURL
        guard let end = IslandTrust.endpoint(fromAddress: base) else { return nil }
        if IslandTrust.isCAOnly(end.host, extra: IslandTrust.caOnlyHostsProvider()) {
            return (end, IslandTrust.Record(mode: .ca, since: 0, noticed: true))
        }
        return IslandTrust.shared.status(forAddress: base)
    }
}

// MARK: - Island house rules

/// The operator's welcome text, read-only and scrollable. It is free text of
/// any length typed in the admin panel, so it gets a screen rather than a row.
private struct IslandRulesSheet: View {
    let title: String
    let rules: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                ScrollView {
                    Text(rules)
                        .font(.callout)
                        .foregroundColor(Theme.Color.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(16)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".localized) { dismiss() }
                }
            }
        }
    }
}

// MARK: - Alternate app icon

/// One selectable launcher icon. `id == nil` is the primary (default) icon;
/// a non-nil id must match an **iOS App Icon** set name in Assets.xcassets.
struct AppIconOption: Identifiable, Equatable {
    let id: String?
    let labelKey: String
    /// Asset name for the in-app thumbnail. Defaults to `"<id>Preview"`.
    var previewAsset: String? = nil

    var displayName: String { labelKey.localized }
}

/// Alternate app-icon support (lets the user hide the RCQ flower or pick a
/// different look). Backed by UIKit's `setAlternateIconName`.
///
/// ── HOW TO ADD AN ICON (founder, once the art exists) ─────────────────
///  1. In Assets.xcassets add a new **iOS App Icon** set named e.g.
///     `IconMono` (a single 1024pt image is enough).
///  2. (Recommended) add a normal **Image Set** named `IconMonoPreview`
///     (~120pt rounded render) for the chooser thumbnail. Without it the
///     chooser falls back to a neutral placeholder.
///  3. In Xcode → target Build Settings, set **Include All App Icon
///     Assets = Yes** (`ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS`).
///     That is what makes catalog alt-icons addressable by name. Do this
///     once; it covers every alternate.
///  4. Append one line to `options` below, id == the App Icon set name:
///        AppIconOption(id: "IconMono", labelKey: "settings.app_icon.mono")
///  5. Add the label string to Localizable.strings (en + ru).
/// The chooser, selection, checkmark and persistence all work already.
@MainActor
final class AppIconManager: ObservableObject {
    static let shared = AppIconManager()

    /// The catalogue. First entry is the default; append alternates here.
    let options: [AppIconOption] = [
        AppIconOption(id: nil, labelKey: "settings.app_icon.default", previewAsset: "AppIconPreview"),
        // AppIconOption(id: "IconMono",  labelKey: "settings.app_icon.mono"),
        // AppIconOption(id: "IconDark",  labelKey: "settings.app_icon.dark"),
    ]

    /// nil = primary icon is active.
    @Published private(set) var currentIconID: String?

    var supportsAlternateIcons: Bool { UIApplication.shared.supportsAlternateIcons }

    var currentOption: AppIconOption {
        options.first { $0.id == currentIconID } ?? options[0]
    }

    private init() {
        currentIconID = UIApplication.shared.alternateIconName
    }

    func set(_ option: AppIconOption) {
        guard option.id != currentIconID else { return }
        UIApplication.shared.setAlternateIconName(option.id) { [weak self] error in
            Task { @MainActor in
                if let error {
                    print("[AppIcon] setAlternateIconName(\(option.id ?? "primary")) failed: \(error)")
                } else {
                    self?.currentIconID = option.id
                }
            }
        }
    }

    func previewImage(for option: AppIconOption) -> UIImage? {
        let name = option.previewAsset ?? option.id.map { "\($0)Preview" }
        if let name, let img = UIImage(named: name) { return img }
        // Fall back to the alternate/primary icon file itself if present.
        if let id = option.id, let img = UIImage(named: id) { return img }
        return UIImage(named: "AppIcon")
    }
}

/// Settings → Appearance → App icon. Renders whatever is in
/// `AppIconManager.options`; with no alternates added yet it shows only
/// "Default" (the scaffold is plug-and-play once art lands).
/// Web sessions linked to this account (connect-to-web). Lists them and lets
/// the user disconnect any. Removing the last one drops the account back to
/// single-device server-side (v=2 resumes).
struct LinkedDevicesView: View {
    @Environment(\.dismiss) private var dismiss

    struct Device: Identifiable, Decodable {
        let device_id: String
        let label: String
        let created_at: String
        var id: String { device_id }
    }

    @State private var devices: [Device]? = nil // nil = loading
    @State private var failed = false
    @State private var revoking: Set<String> = []
    @State private var showScanner = false
    @State private var pendingLink: AppState.WebLinkRequest? = nil
    /// What the scanner found, held back until the scanner itself is off the
    /// screen. Assigning `pendingLink` from inside the scanner's callback put a
    /// dismiss and a present into ONE transaction on the same host, and UIKit
    /// drops one of them — the scanner stayed up with `showScanner` already
    /// false, so its Close button wrote `false` into a binding that was already
    /// false and did nothing at all. Founder: "даже кнопка «закрыть» не
    /// работает".
    @State private var scanned: AppState.WebLinkRequest? = nil
    /// #643: the account's KEY SLOTS — every install holding encryption keys
    /// of its own, which is the one list a recovery-phrase login cannot stay
    /// out of. Distinct from the QR-link registry above it. Read-only in v1:
    /// revoking a slot is a key operation with consequences of its own.
    struct KeySlot: Identifiable, Decodable {
        let device_id: Int
        let label: String?
        var id: Int { device_id }
    }
    struct KeySlotsResp: Decodable { let uin: Int; let devices: [KeySlot] }
    @State private var slots: [KeySlot] = []
    @State private var ownSlot: Int? = nil
    /// Пункт 13: the slot the two-step revoke confirm is armed for, the one
    /// whose POST is in flight, and the error line for the failure alert.
    @State private var revokeTarget: KeySlot? = nil
    @State private var revokingSlot: Int? = nil
    @State private var revokeError: String? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                content
            }
            .navigationTitle("linkeddevices.nav".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".localized) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showScanner = true } label: {
                        Image(systemName: "qrcode.viewfinder")
                    }
                    .tint(Theme.Color.accent)
                }
            }
            .task { await reload() }
            .sheet(isPresented: $showScanner, onDismiss: {
                // The confirm sheet is raised only once the scanner has
                // actually gone. Same serialization the attachment menu in
                // ChatView uses, and the same ordering Android gets for free
                // because its scanner is a separate activity that finishes
                // before the result callback runs.
                guard let req = scanned else { return }
                scanned = nil
                DispatchQueue.main.async { pendingLink = req }
            }) {
                WebLinkScannerSheet { req in scanned = req }
            }
            // onDismiss fires on ANY dismissal (Close button OR swipe-down), so
            // the just-linked device shows up without re-opening the drawer.
            .sheet(item: $pendingLink, onDismiss: { Task { await reload() } }) { req in
                WebLinkSheet(request: req, onClose: { pendingLink = nil })
            }
            // Пункт 13, step two of the revoke confirm.
            .confirmationDialog(
                "linkeddevices.slots.revoke.title".localized,
                isPresented: Binding(
                    get: { revokeTarget != nil },
                    set: { if !$0 { revokeTarget = nil } }
                ),
                titleVisibility: .visible,
                presenting: revokeTarget
            ) { s in
                Button(
                    String(format: "linkeddevices.slots.revoke.confirm".localized, slotName(s)),
                    role: .destructive
                ) {
                    Task { await revokeSlot(s) }
                }
                Button("common.cancel".localized, role: .cancel) {}
            } message: { _ in
                Text("linkeddevices.slots.revoke.message".localized)
            }
            .alert(
                "common.error".localized,
                isPresented: Binding(
                    get: { revokeError != nil },
                    set: { if !$0 { revokeError = nil } }
                )
            ) {
                Button("common.ok".localized) { revokeError = nil }
            } message: {
                Text(revokeError ?? "")
            }
            // The island announces a slot revocation to every session of the
            // account (same channel as slot claims). Refresh the list so a
            // revoke made elsewhere disappears here; nothing heavier.
            .onReceive(
                NotificationCenter.default.publisher(for: .rcqDeviceSlotRevoked)
                    .receive(on: DispatchQueue.main)
            ) { _ in
                Task { await reloadSlots() }
            }
        }
    }

    @ViewBuilder private var content: some View {
        if devices == nil {
            ProgressView().tint(Theme.Color.accent)
        } else if (devices ?? []).isEmpty && slots.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 40)).foregroundColor(Theme.Color.textSecondary)
                Text((failed ? "linkeddevices.error" : "linkeddevices.empty").localized)
                    .foregroundColor(Theme.Color.textPrimary)
                Text("linkeddevices.hint".localized)
                    .font(.footnote).foregroundColor(Theme.Color.textSecondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 28)
                Button {
                    showScanner = true
                } label: {
                    Label("linkeddevices.connect".localized, systemImage: "qrcode.viewfinder")
                        .fontWeight(.semibold)
                        .padding(.horizontal, 20).padding(.vertical, 12)
                        .background(Theme.Color.accent)
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                }
                .padding(.top, 4)
            }
        } else {
            List {
                if !slots.isEmpty {
                    Section {
                        ForEach(slots) { s in
                            HStack(spacing: 12) {
                                Image(systemName: slotIcon(s))
                                    .foregroundColor(Theme.Color.accent)
                                Text(slotName(s)).foregroundColor(Theme.Color.textPrimary)
                                Spacer()
                                if ownSlot == s.device_id {
                                    Text("linkeddevices.slots.this".localized)
                                        .font(.caption).foregroundColor(Theme.Color.accent)
                                } else if s.device_id != 1, ownSlot != nil {
                                    // Пункт 13: a slot that is neither the
                                    // primary (the server refuses that one -
                                    // rotating it is /auth/reissue's job) nor
                                    // OUR OWN can be retired. Step one of the
                                    // two-step confirm; the dialog is step two.
                                    if revokingSlot == s.device_id {
                                        ProgressView().scaleEffect(0.7)
                                    } else {
                                        Button("linkeddevices.slots.revoke".localized, role: .destructive) {
                                            revokeTarget = s
                                        }
                                        .font(.callout)
                                        .disabled(revokingSlot != nil)
                                    }
                                }
                            }
                            .listRowBackground(Theme.Color.bgSecondary)
                        }
                    } header: {
                        Text("linkeddevices.slots.title".localized)
                    } footer: {
                        Text("linkeddevices.slots.hint".localized)
                    }
                }
                Section {
                    if (devices ?? []).isEmpty {
                        // ⚠ "No browsers are connected" is a CLAIM, and it must
                        // not be made on a failed read. The key-slots section
                        // above is populated for every bootstrapped account, so
                        // this list is no longer the only thing on screen and
                        // the whole view stopped falling through to its error
                        // state: a timed-out /devices would have told the user,
                        // definitively, that nobody is linked — on the screen
                        // whose whole purpose is to reveal a browser they did
                        // not link themselves.
                        Text((failed ? "linkeddevices.error" : "linkeddevices.empty").localized)
                            .foregroundColor(Theme.Color.textSecondary)
                            .listRowBackground(Theme.Color.bgSecondary)
                    }
                    ForEach(devices ?? []) { d in
                        HStack(spacing: 12) {
                            Image(systemName: "laptopcomputer").foregroundColor(Theme.Color.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(d.label.isEmpty ? "Web" : d.label).foregroundColor(Theme.Color.textPrimary)
                                if d.created_at.count >= 10 {
                                    Text(String(format: "linkeddevices.connected".localized, String(d.created_at.prefix(10))))
                                        .font(.caption).foregroundColor(Theme.Color.textSecondary)
                                }
                            }
                            Spacer()
                            if revoking.contains(d.device_id) {
                                ProgressView().scaleEffect(0.7)
                            } else {
                                Button("linkeddevices.disconnect".localized, role: .destructive) {
                                    Task { await revoke(d) }
                                }
                                .font(.callout)
                            }
                        }
                        .listRowBackground(Theme.Color.bgSecondary)
                    }
                } header: {
                    Text("linkeddevices.web.title".localized)
                } footer: {
                    Text("linkeddevices.hint".localized)
                }
            }
            .scrollContentBackground(.hidden)
        }
    }

    private func slotName(_ s: KeySlot) -> String {
        if s.device_id == 1 { return "linkeddevices.slots.primary".localized }
        if let l = s.label, !l.isEmpty { return l }
        return "linkeddevices.slots.unnamed".localized
    }

    /// The row's glyph comes from the slot's LABEL, not its index. The first
    /// cut drew slot 1 as a phone and everything else as a laptop, and the
    /// founder's own account is the counter-example: his desktop rides the
    /// legacy primary keys in slot 1, the iPhone sits in slot 2 — drawn as a
    /// laptop.
    ///
    /// What the registry actually carries: iOS registers UIDevice model
    /// ("iPhone"/"iPad"), Android the literal "Android", web/desktop the
    /// clientLabel shape ("RCQ Desktop · macOS", "Chrome · macOS", legacy
    /// "Desktop"/"Web"). Order is the whole trick: "desktop" first (the app,
    /// whatever OS trails it), then browser names before OS names so
    /// "Safari · iOS" and "Chrome · Android" read as the web sessions they
    /// are, not as phones.
    private func slotIcon(_ s: KeySlot) -> String {
        let l = (s.label ?? "").lowercased()
        if !l.isEmpty {
            if l.contains("desktop") { return "laptopcomputer" }
            for b in ["chrome", "firefox", "safari", "edge", "opera",
                      "brave", "vivaldi", "yandex", "browser", "web"]
            where l.contains(b) { return "globe" }
            if l.contains("ipad") || l.contains("tablet") { return "ipad" }
            for p in ["iphone", "ipod", "android", "phone"]
            where l.contains(p) { return "iphone" }
            for d in ["mac", "windows", "linux"]
            where l.contains(d) { return "laptopcomputer" }
        }
        // No platform in the label. The server names slot 1 literally
        // "primary", so the primary slot always lands here; the account's
        // first device is most often the phone that created it, and that
        // guess is a LAST RESORT only — index must never again be the rule
        // (the founder's slot 1 is a desktop, and nothing can tell us).
        return s.device_id == 1 ? "iphone" : "laptopcomputer.and.iphone"
    }

    private func reload() async {
        failed = false
        // A decoy session must not list the REAL account's web sessions, and
        // must not read as broken either: "no devices linked" is the honest
        // answer for an identity that exists on no server, and it is the state
        // an ordinary account starts in.
        guard !PanicPINService.shared.isDecoy else { devices = []; return }
        do {
            let list: [Device] = try await APIClient.shared.request("GET", "/devices")
            devices = list
        } catch {
            failed = true
            devices = []
        }
        await reloadSlots()
    }

    /// Best-effort beside the registry: an island too old for per-device keys
    /// 404s here, which simply leaves the section out.
    ///
    /// Authenticated on purpose, and it has to stay so: since Stage 3 the
    /// island answers `/keys/{uin}/devices` to anyone, but fills `label` only
    /// for the OWNER asking about their own account (server 2026.08.23.5).
    /// Read it anonymously and every slot below turns "unnamed", and the
    /// revoke confirm could no longer say which install it is about to
    /// retire. The owner about itself names no pair, so there is nothing to
    /// hide from the island here.
    private func reloadSlots() async {
        guard !PanicPINService.shared.isDecoy else { slots = []; ownSlot = nil; return }
        guard let uin = SignalProtocolStores.shared.localUIN else { return }
        ownSlot = SignalProtocolStores.shared.localDeviceId
        guard let resp: KeySlotsResp = try? await APIClient.shared.request("GET", "/keys/\(uin)/devices")
        else { return }
        slots = resp.devices.sorted { $0.device_id < $1.device_id }
    }

    private func revoke(_ d: Device) async {
        revoking.insert(d.device_id)
        let _: EmptyResponse? = try? await APIClient.shared.request("DELETE", "/devices/\(d.device_id)")
        revoking.remove(d.device_id)
        await reload()
    }

    /// Пункт 13: retire a key slot (server 2026.08.21.8). Senders stop
    /// fanning out to it and its one-time prekeys are gone; the install that
    /// held it keeps only what it already received. Slot 1 is refused
    /// server-side and never offers the button here. A young linked session
    /// touching something older than itself gets the cooldown 403, turned
    /// into the human sentence it means (hours, rounded up).
    private func revokeSlot(_ s: KeySlot) async {
        revokingSlot = s.device_id
        do {
            let _: EmptyResponse = try await APIClient.shared.request(
                "POST", "/keys/devices/\(s.device_id)/revoke"
            )
            slots.removeAll { $0.device_id == s.device_id }
        } catch {
            revokeError = Self.revokeErrorMessage(error)
        }
        revokingSlot = nil
    }

    /// 403 {"detail":{"code":"revoke_cooldown","wait_seconds":N}} becomes
    /// "try again in {ceil(N/3600)} h"; anything else is the generic failure.
    static func revokeErrorMessage(_ error: Error) -> String {
        if case APIError.http(403, let body) = error,
           let body,
           body.contains("revoke_cooldown"),
           let range = body.range(of: #""wait_seconds"\s*:\s*(\d+)"#, options: .regularExpression),
           let secs = Int(body[range].drop(while: { !$0.isNumber })) {
            let hours = max(1, Int((Double(secs) / 3600).rounded(.up)))
            return String(format: "linkeddevices.slots.revoke.cooldown".localized, hours)
        }
        return "linkeddevices.slots.revoke.failed".localized
    }
}

/// Camera scanner for the "connect a browser" flow. Reads the rcq://link QR
/// shown on chat.rcq.app and hands the token + web pubkey to [onLink]; ignores
/// any other QR so a stray code doesn't do anything.
private struct WebLinkScannerSheet: View {
    let onLink: (AppState.WebLinkRequest) -> Void
    @Environment(\.dismiss) private var dismiss
    /// AVFoundation hands the same code over several times before the session
    /// finishes stopping, and each delivery used to raise another confirm
    /// sheet. @State, not a plain var: QRScannerView never refreshes its
    /// captured closure (`updateUIViewController` is empty), so only
    /// reference-backed storage is read correctly from that first struct copy.
    @State private var handled = false
    @State private var invalid = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                QRScannerView { raw in handle(raw) }
                    .ignoresSafeArea()
                VStack {
                    Spacer()
                    Text("linkeddevices.scan_hint".localized)
                        .font(.footnote)
                        .foregroundColor(.white)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(.black.opacity(0.55))
                        .clipShape(Capsule())
                        .padding(.bottom, 40)
                }
            }
            .navigationTitle("linkeddevices.connect".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel".localized) { dismiss() }
                }
            }
            .alert("qr.alert.invalid_code".localized, isPresented: $invalid) {
                Button("common.ok".localized) { dismiss() }
            }
        }
    }

    private func handle(_ raw: String) {
        guard !handled else { return }
        guard let url = URL(string: raw), url.scheme == "rcq", url.host == "link",
              let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let token = q.first(where: { $0.name == "t" })?.value, !token.isEmpty,
              let webPub = q.first(where: { $0.name == "k" })?.value, !webPub.isEmpty
        else {
            // NOT "keep scanning": the capture session was stopped the moment
            // this code was read, so the preview behind us is a frozen frame.
            // Say so and give the user the way out, the way Android's toast
            // does.
            handled = true
            invalid = true
            return
        }
        handled = true
        let c = q.first(where: { $0.name == "c" })?.value?.trimmingCharacters(in: .whitespaces)
        let label = (c?.isEmpty == false) ? String(c!.prefix(24)) : "Web"
        onLink(AppState.WebLinkRequest(token: token, webPub: webPub, clientLabel: label))
        // Close ourselves. The parent raises the confirm sheet from onDismiss,
        // once this one is really gone.
        dismiss()
    }
}

struct AppIconView: View {
    @StateObject private var icons = AppIconManager.shared

    var body: some View {
        ZStack {
            Theme.Color.bgPrimary.ignoresSafeArea()
            Form {
                Section {
                    ForEach(icons.options) { option in
                        Button {
                            icons.set(option)
                        } label: {
                            HStack(spacing: 14) {
                                thumb(option)
                                Text(option.displayName)
                                    .foregroundColor(Theme.Color.textPrimary)
                                Spacer()
                                if option.id == icons.currentIconID {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(Theme.Color.accent)
                                }
                            }
                        }
                    }
                } footer: {
                    Text("settings.app_icon.footer".localized)
                        .foregroundColor(Theme.Color.textSecondary)
                }
                .listRowBackground(Theme.Color.bgSecondary)
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("settings.app_icon".localized)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func thumb(_ option: AppIconOption) -> some View {
        if let img = icons.previewImage(for: option) {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.Color.bgPrimary)
                .frame(width: 52, height: 52)
                .overlay(
                    Image(systemName: "app.dashed")
                        .foregroundColor(Theme.Color.textSecondary)
                )
        }
    }
}

// MARK: - Backup island (multihoming, federation v1)

/// Settings surface for multihoming: this account also registers on a second,
/// independent island (same keypair), so messages land in both mailboxes and a
/// single island death loses nothing. The heavy lifting lives in `Multihome`;
/// this view just lists/adds/removes backup homes and republishes the record.
struct BackupIslandView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    @State private var homes: [MultihomeStore.Home] = []
    @State private var host = ""
    @State private var busy = false
    @State private var autoBusy = false
    @State private var advanced = false
    @State private var error: String? = nil
    // §5a.5 promote: confirm-first — the number and connected island change.
    @State private var promoteTarget: MultihomeStore.Home? = nil

    private var autoHomes: [MultihomeStore.Home] { homes.filter { $0.auto == true } }
    private var manualHomes: [MultihomeStore.Home] { homes.filter { $0.auto != true } }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                Form {
                    Section {
                        Text("multihome.body".localized)
                            .font(.footnote)
                            .foregroundColor(Theme.Color.textSecondary)
                    }
                    .listRowBackground(Theme.Color.bgSecondary)

                    // One toggle for normal users: the island comes from the
                    // public catalogue (auto_backup-flagged entries).
                    Section {
                        Toggle(isOn: Binding(
                            get: { !autoHomes.isEmpty },
                            set: { setAuto($0) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("multihome.auto.title".localized)
                                    .foregroundColor(Theme.Color.textPrimary)
                                Text("multihome.auto.sub".localized)
                                    .font(.caption)
                                    .foregroundColor(Theme.Color.textSecondary)
                            }
                        }
                        .tint(Theme.Color.accent)
                        .disabled(autoBusy)
                        if autoBusy {
                            HStack {
                                Text("multihome.auto.busy".localized)
                                    .font(.footnote)
                                    .foregroundColor(Theme.Color.textSecondary)
                                Spacer()
                                ProgressView().scaleEffect(0.7)
                            }
                        }
                        ForEach(autoHomes) { h in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(h.host)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundColor(Theme.Color.textPrimary)
                                Text(String(format: "multihome.row_uin".localized, "\(h.uin)"))
                                    .font(.caption)
                                    .foregroundColor(Theme.Color.textSecondary)
                            }
                        }
                        if let error {
                            Text(error)
                                .font(.footnote)
                                .foregroundColor(.red)
                        }
                    }
                    .listRowBackground(Theme.Color.bgSecondary)

                    // Manual host entry stays for self-hosters, tucked away.
                    Section {
                        Button {
                            advanced.toggle()
                        } label: {
                            Text((advanced ? "▾ " : "▸ ") + "multihome.advanced".localized)
                                .font(.footnote)
                                .foregroundColor(Theme.Color.textSecondary)
                        }
                        if advanced {
                            ForEach(manualHomes) { h in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(h.host)
                                            .font(.system(.body, design: .monospaced))
                                            .foregroundColor(Theme.Color.textPrimary)
                                        Text(String(format: "multihome.row_uin".localized, "\(h.uin)"))
                                            .font(.caption)
                                            .foregroundColor(Theme.Color.textSecondary)
                                    }
                                    Spacer()
                                    // Two buttons in one Form row need .borderless
                                    // or a row tap fires BOTH.
                                    VStack(alignment: .trailing, spacing: 6) {
                                        Button("multihome.remove".localized) { remove(h) }
                                            .font(.callout)
                                            .foregroundColor(Theme.Color.accent)
                                            .buttonStyle(.borderless)
                                            .disabled(busy)
                                        Button("multihome.promote".localized) { promoteTarget = h }
                                            .font(.callout)
                                            .foregroundColor(Theme.Color.textSecondary)
                                            .buttonStyle(.borderless)
                                            .disabled(busy)
                                    }
                                }
                            }
                            TextField("multihome.host_hint".localized, text: $host)
                                .font(.system(.body, design: .monospaced))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                            Button {
                                add()
                            } label: {
                                HStack {
                                    Text((busy ? "multihome.busy" : "multihome.add").localized)
                                    Spacer()
                                    if busy { ProgressView().scaleEffect(0.7) }
                                }
                            }
                            .disabled(busy || host.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    } footer: {
                        Text("multihome.footer".localized)
                            .foregroundColor(Theme.Color.textSecondary)
                    }
                    .listRowBackground(Theme.Color.bgSecondary)
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("multihome.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".localized) { dismiss() }
                }
            }
            .onAppear {
                reload()
                // Open the manual block for self-hosters who already added an
                // island by hand; everyone else sees just the toggle.
                if !manualHomes.isEmpty { advanced = true }
            }
            .alert(
                "multihome.promote.title".localized,
                isPresented: Binding(
                    get: { promoteTarget != nil },
                    set: { if !$0 { promoteTarget = nil } }
                ),
                presenting: promoteTarget
            ) { h in
                Button("multihome.promote.confirm".localized) { promote(h) }
                Button("common.cancel".localized, role: .cancel) {}
            } message: { h in
                Text(String(format: "multihome.promote.body".localized, h.host))
            }
        }
    }

    private func reload() {
        let uin = MessageService.shared.ownUIN
        homes = uin != 0 ? MultihomeStore.shared.list(ownUin: uin) : []
    }

    /// §5a.5: the heavy lifting (recover-first, abort-if-unreachable, store
    /// swap, session reboot) lives in AppState.promoteBackupToPrimary.
    private func promote(_ home: MultihomeStore.Home) {
        busy = true
        error = nil
        Task {
            let err = await appState.promoteBackupToPrimary(host: home.host)
            await MainActor.run {
                busy = false
                if let err { error = err } else { reload() }
            }
        }
    }

    private func setAuto(_ on: Bool) {
        let uin = MessageService.shared.ownUIN
        guard uin != 0, !autoBusy else { return }
        autoBusy = true
        error = nil
        let nickname = KeychainStore.string(KeychainStore.Keys.nickname) ?? "user-\(uin)"
        Task {
            do {
                if on {
                    _ = try await Multihome.enableAutoBackup(ownUin: uin, nickname: nickname)
                } else {
                    Multihome.disableAutoBackup(ownUin: uin)
                }
                await AuthService.shared.publishHomeIslandRecord(ownUIN: uin)
                await MessageService.shared.pushHomeRecordToContacts()
                if on { await Multihome.drainBackupQueues(ownUin: uin) }
                await MainActor.run {
                    autoBusy = false
                    reload()
                }
            } catch {
                let message: String
                switch error {
                case Multihome.AddError.noIsland: message = "multihome.err.none".localized
                case Multihome.AddError.network(let detail):
                    message = "multihome.err.generic".localized + " (\(detail))"
                default: message = "multihome.err.generic".localized
                }
                await MainActor.run {
                    self.error = message
                    autoBusy = false
                    reload()
                }
            }
        }
    }

    private func add() {
        let uin = MessageService.shared.ownUIN
        guard uin != 0 else { return }
        busy = true
        error = nil
        let nickname = KeychainStore.string(KeychainStore.Keys.nickname) ?? "user-\(uin)"
        Task {
            do {
                _ = try await Multihome.addBackupIsland(ownUin: uin, hostInput: host, nickname: nickname)
                await AuthService.shared.publishHomeIslandRecord(ownUIN: uin)
                await MessageService.shared.pushHomeRecordToContacts()
                await Multihome.drainBackupQueues(ownUin: uin)
                await MainActor.run {
                    host = ""
                    busy = false
                    reload()
                }
            } catch {
                let message: String
                switch error {
                case Multihome.AddError.invalidHost: message = "multihome.err.invalid".localized
                case Multihome.AddError.notAFingerprint: message = "island.trust.not_fingerprint".localized
                case Multihome.AddError.fingerprintOnCAHost: message = "island.trust.ca_only".localized
                case Multihome.AddError.trustRefused:
                    // The banner with the two fingerprints and the button is on
                    // the main screen; this line says why nothing was dialled.
                    let change = IslandTrust.shared.change(forAddress: host)
                    message = String(
                        format: (change?.typed == true ? "island.trust.changed_typed" : "island.trust.changed").localized,
                        change?.host ?? host
                    )
                case Multihome.AddError.primaryIsland: message = "multihome.err.primary".localized
                case Multihome.AddError.alreadyAdded: message = "multihome.err.already".localized
                case Multihome.AddError.network(let detail):
                    message = "multihome.err.generic".localized + " (\(detail))"
                default: message = "multihome.err.generic".localized
                }
                await MainActor.run {
                    self.error = message
                    busy = false
                }
            }
        }
    }

    private func remove(_ home: MultihomeStore.Home) {
        let uin = MessageService.shared.ownUIN
        MultihomeStore.shared.remove(ownUin: uin, host: home.host)
        reload()
        Task { await AuthService.shared.publishHomeIslandRecord(ownUIN: uin); await MessageService.shared.pushHomeRecordToContacts() }
    }
}

/// Global chat-wallpaper picker (Android parity): None + custom-from-gallery +
/// built-in gradient presets. The selection applies behind every chat.
private struct ChatBackgroundPicker: View {
    /// false = chat wallpaper, true = home / chat-list wallpaper.
    var home = false
    @StateObject private var bg = ChatBackgroundStore.shared
    @State private var showPicker = false
    private let cols = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        let sel = bg.selection(home: home)
        ScrollView {
            LazyVGrid(columns: cols, spacing: 12) {
                tile(label: "chat_bg.none".localized, selected: sel.isEmpty,
                     fill: AnyView(Theme.Color.bgSecondary)) { bg.set("", home: home) }
                tile(label: "chat_bg.custom".localized, selected: sel == "custom",
                     fill: AnyView(Theme.Color.bgSecondary), icon: "photo.on.rectangle") { showPicker = true }
                ForEach(ChatBackgrounds.presets) { p in
                    tile(label: p.label, selected: sel == "preset:\(p.id)",
                         fill: AnyView(LinearGradient(colors: p.colors, startPoint: .top, endPoint: .bottom))) {
                        bg.set("preset:\(p.id)", home: home)
                    }
                }
            }
            .padding(12)
        }
        .background(Theme.Color.bgPrimary.ignoresSafeArea())
        .navigationTitle((home ? "settings.home_bg" : "settings.chat_bg").localized)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPicker) {
            PhotoPicker(selectionLimit: 1) { images in
                showPicker = false
                guard let img = images.first, let data = img.jpegData(compressionQuality: 0.85) else { return }
                bg.saveCustom(data, home: home)
            }
        }
    }

    @ViewBuilder
    private func tile(label: String, selected: Bool, fill: AnyView, icon: String? = nil, onTap: @escaping () -> Void) -> some View {
        VStack(spacing: 4) {
            ZStack {
                fill.clipShape(RoundedRectangle(cornerRadius: 12))
                if let icon { Image(systemName: icon).foregroundColor(Theme.Color.textPrimary) }
                if selected {
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(Theme.Color.accent)
                                .padding(6)
                        }
                        Spacer()
                    }
                }
            }
            .aspectRatio(0.72, contentMode: .fit)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Theme.Color.accent : .clear, lineWidth: 2.5))
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            Text(label).font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.Color.textPrimary).lineLimit(1)
        }
    }
}

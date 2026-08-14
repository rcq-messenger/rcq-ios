import PhotosUI
import SwiftUI
import UIKit

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
    @State private var ownAvatarID: String? = UserDefaults.standard.string(forKey: "rcq.ownAvatarID")
    @State private var ownAvatarKey: String? = UserDefaults.standard.string(forKey: "rcq.ownAvatarKey")
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
    @State private var showBlockedUsers = false
    @State private var showRecovery = false
    @State private var showLinkedDevices = false
    @State private var showBackupIsland = false
    @State private var showBackupFile = false
    @State private var uinCopied: Bool = false
    @StateObject private var language = LanguageManager.shared
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                Form {
                    Section {
                        identityHeader
                    }
                    .listRowBackground(Theme.Color.bgSecondary)

                    Section("settings.appearance".localized) {
                        Picker("settings.appearance.theme".localized, selection: $theme.theme) {
                            ForEach(AppTheme.allCases) { t in
                                Text(t.label).tag(t)
                            }
                        }
                        // #3 accessibility: in-app text size (scales the whole
                        // app via Dynamic Type; "System" follows the OS setting).
                        Picker("settings.textsize".localized, selection: $theme.textSize) {
                            ForEach(AppTextSize.allCases) { s in
                                Text(s.label).tag(s)
                            }
                        }
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
                        }
                        NavigationLink {
                            ChatBackgroundPicker()
                        } label: {
                            Text("settings.chat_bg".localized)
                        }
                        NavigationLink {
                            ChatBackgroundPicker(home: true)
                        } label: {
                            Text("settings.home_bg".localized)
                        }
                        Toggle(isOn: $theme.animateAvatars) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("settings.animate_avatars".localized)
                                    .foregroundColor(Theme.Color.textPrimary)
                                Text("settings.animate_avatars.footer".localized)
                                    .font(.caption)
                                    .foregroundColor(Theme.Color.textSecondary)
                            }
                        }
                    }
                    .listRowBackground(Theme.Color.bgSecondary)

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
                    }
                    .listRowBackground(Theme.Color.bgSecondary)


                    Section {
                        // Menu (not Picker) so per-row .disabled greys out unfinished languages.
                        Menu {
                            ForEach(AppLanguage.allCases) { lang in
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
                    } header: {
                        Text("settings.language".localized)
                    } footer: {
                        Text("settings.language.footer".localized)
                    }
                    .listRowBackground(Theme.Color.bgSecondary)

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
                    } footer: {
                        Text("settings.privacy.footer.short".localized)
                    }
                    .listRowBackground(Theme.Color.bgSecondary)

                    historySection

                    // Self-host backends running rcq-server-ref report
                    // uin_shop=false via /server/info and the row hides
                    // entirely — operators handle UIN allocation out of
                    // band (Telegram channel, BTCPay, manual assignment)
                    // because the in-app Apple IAP transaction is bound
                    // to our developer account regardless of which
                    // backend the user is on. See
                    // project_rcq_monetization_model for the design.
                    // My numbers has its own condition: it shows whenever
                    // this account holds anything, shop or no shop. An
                    // operator who closes the shop must not strand people on
                    // the wrong number, and a self-hoster can hand a member a
                    // second one by hand (POST /admin/uin/grant). Islands too
                    // old to answer /uin/mine leave heldCount at zero and the
                    // row stays hidden.
                    if appState.serverCapabilities.uinShop || heldUINCount > 0 {
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
                        } footer: {
                            // The footer describes the SHOP; without one it
                            // would be advertising a storefront this island
                            // does not have.
                            Text(appState.serverCapabilities.uinShop
                                 ? "settings.uin_shop.footer".localized
                                 : "my_uins.settings.footer".localized)
                        }
                        .listRowBackground(Theme.Color.bgSecondary)
                    }

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
                    } header: {
                        Text("settings.account".localized)
                    } footer: {
                        Text("settings.account.footer".localized)
                    }
                    .listRowBackground(Theme.Color.bgSecondary)

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
            }
            .navigationTitle("settings.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".localized) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    shareContactLinkButton
                }
            }
            .sheet(isPresented: $showAbout) { AboutSheet() }
            .fullScreenCover(isPresented: $showUINShop) { UINShopView() }
            .sheet(isPresented: $showMyUINs) { MyUINsView() }
            .task { heldUINCount = (await AppState.shared.myUINs())?.owned.count ?? 0 }
            .sheet(isPresented: $showBugBounty) { BugBountySheet() }
            .sheet(isPresented: $showSoundSheet) { SoundSettingsSheet() }
            .sheet(isPresented: $showLinkWeb) {
                LinkWebView()
                    .presentationDetents([.height(360), .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showPrivacy) { PrivacySettingsView(pane: .privacy) }
            .sheet(isPresented: $showNetwork) { PrivacySettingsView(pane: .network) }
            .sheet(isPresented: $showNotifications) { NotificationsSettingsView() }
            .sheet(isPresented: $showMyReports) { MyReportsView() }
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
                        await AppState.shared.burnAccount()
                        burning = false
                        dismiss()
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

    @ViewBuilder
    private var shareContactLinkButton: some View {
        if let uin = auth.ownUIN, let url = URL(string: "https://rcq.app/u/\(uin)") {
            ShareLink(
                item: url,
                subject: Text(auth.nickname.isEmpty ? "RCQ" : auth.nickname),
                message: Text(String(format: "settings.share.message".localized, auth.nickname.isEmpty ? "—" : auth.nickname, uin)),
            ) {
                Image(systemName: "square.and.arrow.up")
                    .foregroundColor(Theme.Color.accent)
            }
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
            Button(role: .destructive) {
                confirmClearHistory = true
            } label: {
                HStack {
                    Image(systemName: "trash")
                    Text("settings.history.clear".localized)
                }
            }
        }
        .listRowBackground(Theme.Color.bgSecondary)
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
        }
        .listRowBackground(Theme.Color.bgSecondary)
    }

    /// Read my own picture back from the island. `/users/me` answers with the
    /// owner-self view, which always carries it.
    private func loadOwnAvatar() async {
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
        avatarBusy = true
        defer { avatarBusy = false }
        struct Body: Encodable {
            let avatar_media_id: String
            let avatar_media_key: String
        }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            let res: MediaService.UploadResult
            if AnimatedGIFView.isGIF(data) {
                res = try await MediaService.shared.uploadGIF(data: data)
            } else {
                guard let img = UIImage(data: data) else { return }
                res = try await MediaService.shared.uploadImage(img)
            }
            let _: UserProfile = try await APIClient.shared.request(
                "PUT", "/users/me",
                body: Body(avatar_media_id: res.mediaID, avatar_media_key: res.keyBase64),
            )
            // Through the shared holder, so the main screen's header lights up
            // with the new picture instead of waiting for the next launch.
            PresenceService.shared.setOwnAvatar(id: res.mediaID, key: res.keyBase64)
            ownAvatarID = res.mediaID
            ownAvatarKey = res.keyBase64
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
                size: 48
            )
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
                        Text(verbatim: "#\(auth.ownUIN ?? 0)")
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
        }
    }

    @ViewBuilder private var content: some View {
        if devices == nil {
            ProgressView().tint(Theme.Color.accent)
        } else if (devices ?? []).isEmpty {
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
                Section {
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
                } footer: {
                    Text("linkeddevices.hint".localized)
                }
            }
            .scrollContentBackground(.hidden)
        }
    }

    private func reload() async {
        failed = false
        do {
            let list: [Device] = try await APIClient.shared.request("GET", "/devices")
            devices = list
        } catch {
            failed = true
            devices = []
        }
    }

    private func revoke(_ d: Device) async {
        revoking.insert(d.device_id)
        let _: EmptyResponse? = try? await APIClient.shared.request("DELETE", "/devices/\(d.device_id)")
        revoking.remove(d.device_id)
        await reload()
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

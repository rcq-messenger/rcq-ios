import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var theme = ThemeManager.shared
    @StateObject private var sound = SoundService.shared
    @StateObject private var auth = AuthService.shared
    @StateObject private var presence = PresenceService.shared
    @State private var confirmClearHistory = false
    @State private var confirmBurn = false
    @State private var burning = false
    @State private var showAbout = false
    @State private var showUINShop = false
    @State private var showBugBounty = false
    @State private var showSoundSheet = false
    @State private var showLinkWeb = false
    @State private var showPrivacy = false
    @State private var showNotifications = false
    @State private var showBlockedUsers = false
    @State private var showRecovery = false
    @State private var showLinkedDevices = false
    @State private var showBackupIsland = false
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
                                Text("settings.privacy_network".localized)
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

                    Section("settings.history".localized) {
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

                    // Self-host backends running rcq-server-ref report
                    // uin_shop=false via /server/info and the row hides
                    // entirely — operators handle UIN allocation out of
                    // band (Telegram channel, BTCPay, manual assignment)
                    // because the in-app Apple IAP transaction is bound
                    // to our developer account regardless of which
                    // backend the user is on. See
                    // project_rcq_monetization_model for the design.
                    if appState.serverCapabilities.uinShop {
                        Section {
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
                        } footer: {
                            Text("settings.uin_shop.footer".localized)
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
            .sheet(isPresented: $showBugBounty) { BugBountySheet() }
            .sheet(isPresented: $showSoundSheet) { SoundSettingsSheet() }
            .sheet(isPresented: $showLinkWeb) {
                LinkWebView()
                    .presentationDetents([.height(360), .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showPrivacy) { PrivacySettingsView() }
            .sheet(isPresented: $showNotifications) { NotificationsSettingsView() }
            .sheet(isPresented: $showBlockedUsers) { BlockedUsersView() }
            .sheet(isPresented: $showRecovery) { RecoveryPhraseView() }
            .sheet(isPresented: $showLinkedDevices) { LinkedDevicesView() }
            .sheet(isPresented: $showBackupIsland) { BackupIslandView().environmentObject(appState) }
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
        }
        .listRowBackground(Theme.Color.bgSecondary)
    }

    @ViewBuilder
    private var identityHeader: some View {
        HStack(spacing: 12) {
            StatusIcon(status: presence.status, size: 40)
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
                        Image(systemName: uinCopied ? "checkmark.circle.fill" : "doc.on.doc")
                            .font(.caption)
                            .foregroundColor(uinCopied ? Theme.Color.accent : Theme.Color.textSecondary)
                        if uinCopied {
                            Text("link_web.copied".localized)
                                .font(.caption2)
                                .foregroundColor(Theme.Color.accent)
                        }
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
            .sheet(isPresented: $showScanner) {
                WebLinkScannerSheet { req in showScanner = false; pendingLink = req }
            }
            .sheet(item: $pendingLink) { req in
                WebLinkSheet(request: req, onClose: {
                    pendingLink = nil
                    Task { await reload() }
                })
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
        }
    }

    private func handle(_ raw: String) {
        guard let url = URL(string: raw), url.scheme == "rcq", url.host == "link",
              let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let token = q.first(where: { $0.name == "t" })?.value, !token.isEmpty,
              let webPub = q.first(where: { $0.name == "k" })?.value, !webPub.isEmpty
        else { return } // not a connect-to-web QR; keep scanning
        onLink(AppState.WebLinkRequest(token: token, webPub: webPub))
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

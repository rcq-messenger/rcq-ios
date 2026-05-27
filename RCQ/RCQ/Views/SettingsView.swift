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
    @State private var uinCopied: Bool = false
    @StateObject private var language = LanguageManager.shared

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

                    Section {
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
            .sheet(isPresented: $showUINShop) { UINShopView() }
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
                        Text(String(auth.ownUIN ?? 0))
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

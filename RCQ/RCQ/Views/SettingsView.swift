import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var theme = ThemeManager.shared
    @StateObject private var sound = SoundService.shared
    @StateObject private var auth = AuthService.shared
    @StateObject private var presence = PresenceService.shared
    @StateObject private var itemsSvc = ItemsService.shared
    @State private var confirmClearHistory = false
    @State private var confirmBurn = false
    @State private var burning = false
    @State private var confirmMigrate = false
    @State private var migrating = false
    @State private var migrationAlert: String?
    @State private var showShop = false

    // Mirrors `routers/migrate.py:MIGRATION_TOKEN_COST`.
    private let migrationCost: Int = 99
    @State private var showAbout = false
    @State private var showBugBounty = false
    @State private var showLinkWeb = false
    @State private var showPrivacy = false
    @State private var showNotifications = false
    @State private var showBlockedUsers = false
    @State private var uinCopied: Bool = false
    @StateObject private var language = LanguageManager.shared
    @AppStorage("rcq.gameMinis.enabled") private var minisEnabled: Bool = true
    // Foundation toggles — UI-only until routing + billing land.
    @AppStorage("rcq.network.vpn_enabled") private var vpnEnabled: Bool = false
    @AppStorage("rcq.network.pay_for_large_files") private var payForLargeFiles: Bool = false
    @State private var trafficUsage: MediaService.TrafficUsage?

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
                        Toggle(isOn: $sound.isEnabled) {
                            Text("settings.sound.toggle".localized)
                                .foregroundColor(Theme.Color.textPrimary)
                        }
                        .tint(Theme.Color.accent)
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

                    Section {
                        Toggle(isOn: Binding(
                            get: { itemsSvc.inventoryPublic },
                            set: { newValue in
                                Task { await itemsSvc.setInventoryPublic(newValue) }
                            },
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("settings.inventory.public".localized)
                                    .foregroundColor(Theme.Color.textPrimary)
                                Text("settings.inventory.public.footer".localized)
                                    .font(.caption2)
                                    .foregroundColor(Theme.Color.textSecondary)
                            }
                        }
                        .tint(Theme.Color.accent)
                        Toggle(isOn: $minisEnabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("settings.minis.toggle".localized)
                                    .foregroundColor(Theme.Color.textPrimary)
                                Text("settings.minis.toggle.footer".localized)
                                    .font(.caption2)
                                    .foregroundColor(Theme.Color.textSecondary)
                            }
                        }
                        .tint(Theme.Color.accent)
                    }
                    .listRowBackground(Theme.Color.bgSecondary)

                    Section {
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: "shield.lefthalf.filled")
                                .foregroundColor(Theme.Color.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("settings.network.proxy".localized)
                                    .foregroundColor(Theme.Color.textPrimary)
                                Text("settings.network.proxy.footer".localized)
                                    .font(.caption2)
                                    .foregroundColor(Theme.Color.textSecondary)
                            }
                            Spacer()
                            Toggle("", isOn: $vpnEnabled)
                                .labelsHidden()
                                .tint(Theme.Color.accent)
                                .disabled(true)
                        }
                        HStack {
                            Image(systemName: "clock.badge.checkmark")
                                .foregroundColor(Theme.Color.textSecondary)
                            Text("settings.network.coming_soon".localized)
                                .font(.caption2.weight(.semibold))
                                .foregroundColor(Theme.Color.textSecondary)
                            Spacer()
                        }
                    } header: {
                        Text("settings.network".localized)
                    }
                    .listRowBackground(Theme.Color.bgSecondary)

                    Section {
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: "internaldrive")
                                .foregroundColor(Theme.Color.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("settings.traffic.used".localized)
                                    .foregroundColor(Theme.Color.textPrimary)
                                Text(usedMBString)
                                    .font(.system(.callout, design: .monospaced))
                                    .foregroundColor(Theme.Color.textSecondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("settings.traffic.spent".localized)
                                    .font(.caption2)
                                    .foregroundColor(Theme.Color.textSecondary)
                                HStack(spacing: 3) {
                                    ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                                        .frame(width: 12, height: 12)
                                    Text("\(trafficUsage?.jetonsSpent ?? 0)")
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .foregroundColor(Theme.Color.textPrimary)
                                }
                            }
                        }
                        Toggle(isOn: $payForLargeFiles) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("settings.traffic.pay_large".localized)
                                    .foregroundColor(Theme.Color.textPrimary)
                                Text("settings.traffic.pay_large.footer".localized)
                                    .font(.caption2)
                                    .foregroundColor(Theme.Color.textSecondary)
                            }
                        }
                        .tint(Theme.Color.accent)
                    } header: {
                        Text("settings.traffic".localized)
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
                        // If wallet can't cover fee, redirect to shop instead of disabling the row.
                        let canAfford = itemsSvc.wallet.tokens >= migrationCost
                        Button {
                            if canAfford {
                                confirmMigrate = true
                            } else {
                                showShop = true
                            }
                        } label: {
                            HStack {
                                Image(systemName: "arrow.uturn.right.circle")
                                    .foregroundColor(canAfford ? Theme.Color.accent : Theme.Color.textSecondary)
                                Text(migrating
                                    ? "settings.migrate.busy".localized
                                    : (canAfford
                                        ? "settings.migrate.label".localized
                                        : "settings.migrate.label.need_tokens".localized)
                                )
                                .foregroundColor(canAfford ? Theme.Color.textPrimary : Theme.Color.textSecondary)
                                Spacer()
                                if migrating {
                                    ProgressView().scaleEffect(0.7)
                                } else {
                                    HStack(spacing: 3) {
                                        ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                                            .frame(width: 12, height: 12)
                                        Text("\(migrationCost)")
                                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                            .foregroundColor(canAfford ? Theme.Color.textSecondary : Color.red)
                                    }
                                }
                            }
                        }
                        .disabled(migrating)
                    } footer: {
                        Text("settings.migrate.footer".localized)
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
            .sheet(isPresented: $showBugBounty) { BugBountySheet() }
            .sheet(isPresented: $showShop) {
                BuyTokensSheet()
                    .presentationDetents([.medium, .large])
            }
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
            .confirmationDialog(
                "settings.migrate.confirm.title".localized,
                isPresented: $confirmMigrate,
                titleVisibility: .visible,
            ) {
                Button("settings.migrate.confirm.button".localized) {
                    Task {
                        migrating = true
                        let result = await AppState.shared.migrateAccount()
                        migrating = false
                        switch result {
                        case .success(let newUIN):
                            migrationAlert = String(format: "settings.migrate.success".localized, newUIN)
                        case .insufficientTokens(let required, let have):
                            migrationAlert = String(
                                format: "settings.migrate.error.insufficient".localized,
                                required, have,
                            )
                        case .cooldown:
                            migrationAlert = "settings.migrate.error.cooldown".localized
                        case .other(let msg):
                            migrationAlert = msg.isEmpty ? "settings.migrate.error.generic".localized : msg
                        }
                    }
                }
                Button("common.cancel".localized, role: .cancel) {}
            } message: {
                Text("settings.migrate.confirm.message".localized)
            }
            .alert(
                "settings.migrate.alert.title".localized,
                isPresented: Binding(
                    get: { migrationAlert != nil },
                    set: { if !$0 { migrationAlert = nil } },
                ),
                actions: {
                    Button("common.ok".localized, role: .cancel) {
                        migrationAlert = nil
                        dismiss()
                    }
                },
                message: {
                    Text(migrationAlert ?? "")
                }
            )
            .task {
                trafficUsage = await MediaService.shared.fetchTrafficUsage()
            }
        }
    }

    /// "23.4 MB" — formatted from `trafficUsage.bytesUsed` for the
    /// Settings readout. Same `ByteCountFormatter` as the file bubble
    /// so units line up across the app.
    private var usedMBString: String {
        let bytes = trafficUsage?.bytesUsed ?? 0
        let f = ByteCountFormatter()
        f.allowedUnits = [.useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: Int64(bytes))
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

    @ViewBuilder
    private var identityHeader: some View {
        HStack(spacing: 12) {
            StatusWithPet(
                status: presence.status,
                pet: itemsSvc.ownEquippedPet,
                size: 40,
            )
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
            walletReadout
        }
        .padding(.vertical, 4)
    }

    private var walletReadout: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 4) {
                ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                    .frame(width: 16, height: 16)
                Text("\(itemsSvc.wallet.tokens)")
                    .font(.system(.subheadline, weight: .semibold).monospacedDigit())
                    .foregroundColor(Theme.Color.textPrimary)
            }
            HStack(spacing: 4) {
                ItemAssetImage(bundleSubdir: "Items", filename: "gem", ext: "gif")
                    .frame(width: 16, height: 16)
                Text("\(itemsSvc.wallet.scrolls)")
                    .font(.system(.subheadline, weight: .semibold).monospacedDigit())
                    .foregroundColor(Theme.Color.textPrimary)
            }
        }
    }

    private var hasSignificantInventory: Bool {
        !itemsSvc.items.isEmpty
            || itemsSvc.wallet.tokens > 0
            || itemsSvc.wallet.scrolls > 0
    }

    private var burnTitle: String {
        (hasSignificantInventory
            ? "settings.account.burn.title_inventory"
            : "settings.account.burn.title").localized
    }

    private var burnMessage: String {
        if hasSignificantInventory {
            let tally = String(
                format: "settings.account.burn.tally".localized,
                itemsSvc.items.count,
                itemsSvc.wallet.tokens,
                itemsSvc.wallet.scrolls
            )
            return String(format: "settings.account.burn.message_inventory".localized, tally)
        }
        return "settings.account.burn.message".localized
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}

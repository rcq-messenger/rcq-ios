import SwiftUI

/// Privacy pickers split out of `SettingsView` once the list grew
/// past four entries. All five tri-state policies (last-seen /
/// gender / group invites / trade offers / calls) load from
/// `/users/me/info` on appear and write through PUT `/users/me`
/// on change. Local defaults match the server's column defaults so
/// a render before the GET completes doesn't flicker through a
/// wrong-looking value.
struct PrivacySettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var lastSeenVisibility: String = "everyone"
    /// Opt-in: when ON, the server keeps showing the user's chosen
    /// status to contacts even after the WS connection has been gone
    /// past the staleness window. Lets the user appear "around" with
    /// Online / Away / DND even when the app is not running.
    @State private var presencePersistent: Bool = false
    /// Allowed values match the server allow-list: 0 (forever), 30,
    /// 60, 180, 480, 1440. Picker labels render to the localised
    /// strings below.
    @State private var presenceTTLMinutes: Int = 0
    @State private var gender: String = ""
    @State private var genderVisibility: String = "nobody"
    @State private var profileVisibility: String = "everyone"
    @State private var groupInvitePolicy: String = "everyone"
    /// Mirrored to `@AppStorage("rcq.privacy.callPolicy")` so
    /// `ChatView` can gate the call-button affordance without
    /// re-fetching `/users/me/info` on every render.
    @State private var callPolicy: String = "everyone"
    @AppStorage("rcq.privacy.callPolicy") private var callPolicyCache: String = "everyone"
    /// Mirrored to `@AppStorage("rcq.privacy.readReceiptsVisibility")`
    /// so `MessageService.markRead` can suppress outbound receipts
    /// without re-fetching `/users/me/info` per read.
    @State private var readReceiptsVisibility: String = "everyone"
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

    private var pinConfigured: Bool { PanicPINService.shared.isConfigured }

    /// Stealth-mode status label for the trailing slot on the
    /// PrivacySettingsView row. Reflects the actual connection state,
    /// not the legacy "always show Авто" placeholder.
    private var stealthStatusLabel: String {
        let trimmed = proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if autoProxyActive { return "settings.network.stealth.auto_on".localized }
        if singboxAutoDisabled { return "settings.network.stealth.off".localized }
        return "settings.network.stealth.direct".localized
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                Form {
                    // One Section per option so its footer (a per-
                    // policy explanation) docks directly under the
                    // picker instead of dumping all five descriptions
                    // in one bottom block. Reads top-down, no need to
                    // hunt for the right paragraph.
                    Section {
                        scopePicker(
                            title: "settings.privacy.profile".localized,
                            selection: $profileVisibility,
                            field: "profile_visibility"
                        )
                    } footer: {
                        Text("settings.privacy.profile.desc".localized)
                    }
                    .listRowBackground(Theme.Color.bgSecondary)
                    Section {
                        scopePicker(
                            title: "settings.privacy.last_seen".localized,
                            selection: $lastSeenVisibility,
                            field: "last_seen_visibility"
                        )
                    } footer: {
                        Text("settings.privacy.last_seen.desc".localized)
                    }
                    .listRowBackground(Theme.Color.bgSecondary)
                    Section {
                        Toggle(isOn: $presencePersistent) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("settings.privacy.persistent_presence".localized)
                                    .foregroundColor(Theme.Color.textPrimary)
                                Text("settings.privacy.persistent_presence.desc".localized)
                                    .font(.caption2)
                                    .foregroundColor(Theme.Color.textSecondary)
                            }
                        }
                        .tint(Theme.Color.accent)
                        .onChange(of: presencePersistent) { newValue in
                            Task { await pushBoolField("presence_persistent", newValue) }
                        }
                        if presencePersistent {
                            Picker(selection: $presenceTTLMinutes) {
                                Text("settings.privacy.presence_ttl.30m".localized).tag(30)
                                Text("settings.privacy.presence_ttl.1h".localized).tag(60)
                                Text("settings.privacy.presence_ttl.3h".localized).tag(180)
                                Text("settings.privacy.presence_ttl.8h".localized).tag(480)
                                Text("settings.privacy.presence_ttl.24h".localized).tag(1440)
                            } label: {
                                Text("settings.privacy.presence_ttl".localized)
                                    .foregroundColor(Theme.Color.textPrimary)
                            }
                            .onChange(of: presenceTTLMinutes) { newValue in
                                Task { await pushIntField("presence_ttl_minutes", newValue) }
                            }
                        }
                    }
                    .listRowBackground(Theme.Color.bgSecondary)
                    Section {
                        scopePicker(
                            title: "settings.privacy.gender_visible".localized,
                            selection: $genderVisibility,
                            field: "gender_visibility"
                        )
                        .disabled(gender.isEmpty)
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
                            // markRead — mirror immediately so the
                            // gate flips without a round-trip.
                            readReceiptsCache = newValue
                        }
                    } footer: {
                        Text("settings.privacy.read_receipts.desc".localized)
                    }
                    .listRowBackground(Theme.Color.bgSecondary)

                    securitySection
                    networkSection
                    migrationSection
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("settings.privacy_network".localized)
            .navigationBarTitleDisplayMode(.inline)
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
            .task { await loadVisibility() }
        }
    }

    // MARK: - moved sections (PIN / inventory / network / traffic / migration)

    @ViewBuilder
    private var securitySection: some View {
        if !PanicPINService.shared.isDecoy {
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
            } footer: {
                Text("settings.panic_pin.footer".localized)
            }
            .listRowBackground(Theme.Color.bgSecondary)
        }
    }

    private var networkSection: some View {
        Section {
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
        } header: {
            Text("settings.masking".localized)
        } footer: {
            Text("settings.network.proxy.intro".localized)
                .font(.caption2)
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
        guard let uin = AuthService.shared.ownUIN else { return }
        do {
            let p: UserProfile = try await APIClient.shared.request("GET", "/users/\(uin)/info")
            if let v = p.lastSeenVisibility { lastSeenVisibility = v }
            if let v = p.genderVisibility { genderVisibility = v }
            if let v = p.profileVisibility { profileVisibility = v }
            if let v = p.groupInvitePolicy { groupInvitePolicy = v }
            if let v = p.callPolicy {
                callPolicy = v
                callPolicyCache = v
            }
            if let v = p.readReceiptsVisibility {
                readReceiptsVisibility = v
                readReceiptsCache = v
            }
            if let v = p.presencePersistent { presencePersistent = v }
            if let v = p.presenceTTLMinutes {
                // Migrate legacy "forever" (0) silently to 24h so the
                // picker shows a real selection. The forever option was
                // removed because it lies about presence: app closed for
                // days, contacts still see "online".
                presenceTTLMinutes = v == 0 ? 1440 : v
                if v == 0 {
                    Task { await pushIntField("presence_ttl_minutes", 1440) }
                }
            }
            gender = p.gender ?? ""
        } catch {
            // Soft-fail — the picker write paths still work, the
            // worst case is the displayed default doesn't match
            // the server until the user picks something.
        }
    }

    /// Int variant — for presence_ttl_minutes and any future numeric
    /// preference. Same dynamic-key trick as the bool/string variants
    /// so the server's PUT /users/me partial-update path treats it as
    /// a single-field set.
    private func pushIntField(_ key: String, _ value: Int) async {
        struct Body: Encodable {
            let key: String
            let value: Int
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

    /// Boolean variant of `pushField` for toggles like
    /// `presence_persistent`. The server's PUT /users/me handler treats
    /// missing keys as no-op so the partial payload is safe.
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
}

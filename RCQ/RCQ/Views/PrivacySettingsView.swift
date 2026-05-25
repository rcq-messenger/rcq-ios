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
    @State private var tradePolicy: String = "everyone"
    /// Mirrored to `@AppStorage("rcq.privacy.callPolicy")` so
    /// `ChatView` can gate the call-button affordance without
    /// re-fetching `/users/me/info` on every render.
    @State private var callPolicy: String = "everyone"
    @AppStorage("rcq.privacy.callPolicy") private var callPolicyCache: String = "everyone"
    /// Mirrored to `@AppStorage("rcq.privacy.readReceiptsVisibility")`
    /// so `MessageService.markRead` can suppress outbound receipts
    /// without re-fetching `/users/me/info` per read.
    @State private var readReceiptsVisibility: String = "everyone"
    @AppStorage("rcq.privacy.readReceiptsVisibility") private var readReceiptsCache: String = "everyone"
    @State private var reputationVisibility: String = "everyone"
    @AppStorage("rcq.requirePINForItems") private var requirePINForItems = false

    @StateObject private var itemsSvc = ItemsService.shared
    @State private var showPINSettings = false
    @State private var showProxyURL = false
    @State private var showDiagnostics = false
    @State private var showShop = false
    @State private var confirmMigrate = false
    @State private var migrating = false
    @State private var migrationAlert: String?
    @State private var trafficUsage: MediaService.TrafficUsage?
    @AppStorage("rcq.network.pay_for_large_files") private var payForLargeFiles = false
    @AppStorage("rcq.proxyURL") private var proxyURL: String = ""
    private let migrationCost: Int = 99

    private var pinConfigured: Bool { PanicPINService.shared.isConfigured }

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
                                Text("settings.privacy.presence_ttl.forever".localized).tag(0)
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
                            title: "settings.privacy.trade_offers".localized,
                            selection: $tradePolicy,
                            field: "trade_policy"
                        )
                    } footer: {
                        Text("settings.privacy.trade_offers.desc".localized)
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
                    Section {
                        scopePicker(
                            title: "settings.privacy.reputation".localized,
                            selection: $reputationVisibility,
                            field: "reputation_visibility"
                        )
                    } footer: {
                        Text("settings.privacy.reputation.desc".localized)
                    }
                    .listRowBackground(Theme.Color.bgSecondary)
                    Section {
                        Toggle(isOn: $requirePINForItems) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("settings.privacy.item_pin".localized)
                                    .foregroundColor(Theme.Color.textPrimary)
                                Text("settings.privacy.item_pin.desc".localized)
                                    .font(.caption2)
                                    .foregroundColor(Theme.Color.textSecondary)
                            }
                        }
                        .tint(Theme.Color.accent)
                        .disabled(!pinConfigured)
                    } footer: {
                        // No-PIN hint stays as a footer — the inline
                        // description above is the "what does this do"
                        // line; the footer is the "why is it disabled"
                        // line and only renders when relevant.
                        if !pinConfigured {
                            Text("settings.privacy.item_pin.desc.no_pin".localized)
                        }
                    }
                    .listRowBackground(Theme.Color.bgSecondary)

                    securitySection
                    inventorySection
                    networkSection
                    trafficSection
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
            .sheet(isPresented: $showDiagnostics) { ConnectionDiagnosticsView() }
            .sheet(isPresented: $showShop) {
                BuyTokensSheet()
                    .presentationDetents([.medium, .large])
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
            .task { await loadVisibility() }
            .task {
                trafficUsage = await MediaService.shared.fetchTrafficUsage()
            }
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

    private var inventorySection: some View {
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
        }
        .listRowBackground(Theme.Color.bgSecondary)
    }

    private var networkSection: some View {
        Section {
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
                    Text(proxyURL.isEmpty
                         ? "settings.network.proxy.unset".localized
                         : proxyURL)
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

    private var trafficSection: some View {
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
                Text("settings.traffic.pay_large".localized)
                    .foregroundColor(Theme.Color.textPrimary)
            }
            .tint(Theme.Color.accent)
        } header: {
            Text("settings.traffic".localized)
        } footer: {
            Text("settings.traffic.pay_large.footer".localized)
                .font(.caption2)
        }
        .listRowBackground(Theme.Color.bgSecondary)
    }

    private var migrationSection: some View {
        Section {
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
    }

    private var usedMBString: String {
        let bytes = trafficUsage?.bytesUsed ?? 0
        let f = ByteCountFormatter()
        f.allowedUnits = [.useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: Int64(bytes))
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
            if let v = p.tradePolicy { tradePolicy = v }
            if let v = p.callPolicy {
                callPolicy = v
                callPolicyCache = v
            }
            if let v = p.readReceiptsVisibility {
                readReceiptsVisibility = v
                readReceiptsCache = v
            }
            if let v = p.reputationVisibility { reputationVisibility = v }
            if let v = p.presencePersistent { presencePersistent = v }
            if let v = p.presenceTTLMinutes { presenceTTLMinutes = v }
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

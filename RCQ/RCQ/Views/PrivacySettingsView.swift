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
    @State private var gender: String = ""
    @State private var genderVisibility: String = "nobody"
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
                            title: "settings.privacy.last_seen".localized,
                            selection: $lastSeenVisibility,
                            field: "last_seen_visibility"
                        )
                    } footer: {
                        Text("settings.privacy.last_seen.desc".localized)
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
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("settings.privacy".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".localized) { dismiss() }
                }
            }
            .task { await loadVisibility() }
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
            gender = p.gender ?? ""
        } catch {
            // Soft-fail — the picker write paths still work, the
            // worst case is the displayed default doesn't match
            // the server until the user picks something.
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

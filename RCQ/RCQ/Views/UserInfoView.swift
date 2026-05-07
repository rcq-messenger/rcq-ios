import SwiftUI

struct UserInfoView: View {
    let uin: Int
    let isOwn: Bool

    @State private var profile: UserProfile?
    @State private var loading = true
    @State private var draft: UserProfile?
    @State private var saving = false
    @State private var showTrade = false
    @State private var showInventory = false
    @StateObject private var visits = VisitStore.shared
    @StateObject private var contacts = ContactService.shared

    var body: some View {
        ZStack {
            Theme.Color.bgPrimary.ignoresSafeArea()
            if loading {
                ProgressView().tint(Theme.Color.accent)
            } else if let p = (isOwn ? draft : profile) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header(p)
                        section("profile.section.identity".localized) {
                            field("profile.field.nickname".localized, p.nickname, editable: isOwn) { draft?.nickname = $0 }
                            field("profile.field.uin".localized, String(p.uin), editable: false, mono: true) { _ in }
                        }
                        section("profile.section.personal".localized) {
                            field("profile.field.first_name".localized, p.firstName ?? "", editable: isOwn) { draft?.firstName = $0 }
                            field("profile.field.last_name".localized, p.lastName ?? "", editable: isOwn) { draft?.lastName = $0 }
                            field("profile.field.age".localized, p.age.map(String.init) ?? "", editable: isOwn) {
                                draft?.age = Int($0)
                            }
                            genderRow(p)
                        }
                        section("profile.section.location".localized) {
                            field("profile.field.city".localized, p.city ?? "", editable: isOwn) { draft?.city = $0 }
                            field("profile.field.country".localized, p.country ?? "", editable: isOwn) { draft?.country = $0 }
                        }
                        section("profile.section.about".localized) {
                            multiline("profile.field.about".localized, p.about ?? "", editable: isOwn) { draft?.about = $0 }
                            field(
                                "profile.field.interests".localized,
                                p.interests.joined(separator: ", "),
                                editable: isOwn
                            ) { value in
                                draft?.interests = value.split(separator: ",").map {
                                    $0.trimmingCharacters(in: .whitespaces)
                                }
                            }
                            field("profile.field.homepage".localized, p.homepage ?? "", editable: isOwn) { draft?.homepage = $0 }
                        }
                        section("profile.section.status".localized) {
                            field("profile.field.status_message".localized, p.statusMessage ?? "", editable: isOwn) {
                                draft?.statusMessage = $0
                            }
                        }
                        if !isOwn {
                            // Per-contact custom notification sound
                            // (ICQ-classic feature). Pack list comes
                            // from `SoundPack.allCases`; once the
                            // lootbox Voices section ships, this
                            // expands to include traded packs from
                            // inventory.
                            section("profile.section.notifications".localized) {
                                customSoundPicker(uin: p.uin)
                            }
                        }
                        if isOwn {
                            section("profile.section.audience".localized) {
                                let n = visits.count(within: 7 * 86_400)
                                HStack {
                                    Text("profile.field.profile_views".localized)
                                        .font(.caption)
                                        .foregroundColor(Theme.Color.textSecondary)
                                        .frame(width: 110, alignment: .leading)
                                    Text("\(n)")
                                        .font(.body.monospacedDigit())
                                        .foregroundColor(Theme.Color.textPrimary)
                                    Text("profile.audience.last_7".localized)
                                        .font(.caption)
                                        .foregroundColor(Theme.Color.textSecondary)
                                    Spacer()
                                }
                            }
                        }
                        // Bottom CTAs (Trade / View inventory / Save /
                        // Share) used to live here as full-width
                        // buttons. They migrated to the navbar
                        // (`trailingToolbarContent`) so the body now
                        // stays a clean info-only surface.
                    }
                    .padding(16)
                }
            } else {
                Text("profile.unavailable".localized).foregroundColor(Theme.Color.textSecondary)
            }
        }
        .navigationTitle("profile.title".localized)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                trailingToolbarContent
            }
        }
        .task { await load() }
        .sheet(isPresented: $showTrade) {
            if let p = profile {
                TradeProposeView(recipientUIN: p.uin, recipientNickname: p.nickname)
            }
        }
        .fullScreenCover(isPresented: $showInventory) {
            if let p = profile {
                PublicInventoryView(uin: p.uin, nickname: p.nickname)
            }
        }
    }

    /// Trailing nav-bar slot. Self-profile gets a checkmark Save
    /// button (disabled until `hasChanges`); peer profile gets a
    /// single ellipsis menu with Propose-trade + View-inventory.
    /// Trade entry honours the peer's `tradePolicy` (hidden when
    /// "nobody" / "contacts" + we aren't a contact) — server still
    /// 403s as the safety net but the UI doesn't surface a button
    /// the user can't actually use.
    @ViewBuilder
    private var trailingToolbarContent: some View {
        if isOwn {
            Button {
                Task { await save() }
            } label: {
                if saving {
                    ProgressView().scaleEffect(0.8)
                } else {
                    Image(systemName: "checkmark")
                        .foregroundColor(saveEnabled ? Theme.Color.accent : Theme.Color.textSecondary)
                }
            }
            .disabled(!saveEnabled)
        } else if let p = profile {
            Menu {
                if peerCanReceiveTrade {
                    Button {
                        showTrade = true
                    } label: {
                        Label("profile.cta.propose_trade".localized, systemImage: "arrow.left.arrow.right")
                    }
                }
                Button {
                    showInventory = true
                } label: {
                    Label("profile.cta.view_inventory".localized, systemImage: "shippingbox")
                }
                Divider()
                // Block + Report at the bottom — separated by a
                // Divider so destructive actions don't blur with
                // benign ones above. Same pair appears on every
                // UGC surface that exposes another user.
                UserSafetyActions(
                    targetUIN: p.uin,
                    targetNickname: p.nickname,
                    context: "profile",
                    style: .menu,
                )
                .tint(.red)
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundColor(Theme.Color.textPrimary)
            }
        }
    }

    /// Whether the peer's `tradePolicy` allows us to send a trade.
    /// Defaults to `true` while the profile is still loading so the
    /// menu doesn't flash empty mid-fetch.
    private var peerCanReceiveTrade: Bool {
        let policy = profile?.tradePolicy ?? "everyone"
        if policy == "nobody" { return false }
        if policy == "contacts" {
            return contacts.contacts.contains(where: { $0.uin == uin })
        }
        return true
    }

    @ViewBuilder
    private func customSoundPicker(uin: Int) -> some View {
        // Read current pack via @StateObject-equivalent — we observe
        // via `ContactSoundStore.shared` directly. The picker's
        // option list is derived from the user's own inventory:
        // `default` plus one entry per UNIQUE voice-pack kind they
        // own. No mock list — empty inventory ⇒ "Default" only.
        let store = ContactSoundStore.shared
        let items = ItemsService.shared
        let current = store.packID(for: uin) ?? SoundPack.default.id
        let packs = SoundPack.availablePacks(
            items: items.items,
            catalog: items.catalog,
        )
        Picker(selection: Binding(
            get: { current },
            set: { newValue in
                store.setPack(newValue == SoundPack.default.id ? nil : newValue, for: uin)
            }
        )) {
            ForEach(packs) { pack in
                Text(pack.label).tag(pack.id)
            }
        } label: {
            Text("profile.field.custom_sound".localized)
                .font(.caption)
                .foregroundColor(Theme.Color.textSecondary)
        }
        .pickerStyle(.menu)
        .tint(Theme.Color.accent)
    }

    /// Header: a single big status icon, nickname, UIN, optional status message. The
    /// status icon is the visual anchor — duplicating it next to the nickname would
    /// just be noise, so we don't.
    private func header(_ p: UserProfile) -> some View {
        HStack(spacing: 12) {
            // Status icon picks up the equipped-pet overlay too.
            // No tap-routing here: own-profile users don't need a
            // self-pet-preview (they own the inventory), and peer
            // profiles already expose "View inventory" via the
            // toolbar ellipsis menu where the same content lives.
            StatusWithPet(status: p.status, pet: p.equippedPet, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.nickname).font(.title3.bold()).foregroundColor(Theme.Color.textPrimary)
                Text(String(p.uin)).font(Theme.Font.mono).foregroundColor(Theme.Color.textMono)
                if let m = p.statusMessage, !m.isEmpty {
                    Text(m).font(.caption.italic()).foregroundColor(Theme.Color.textSecondary)
                }
                // Last-seen is server-filtered: nil means the
                // viewer is outside the target's privacy window
                // ("contacts" with no mutual contact, or "nobody").
                // Only show when peer is offline — for online/away
                // /dnd the status icon is the active signal.
                if p.status == .offline, let ts = p.lastSeen {
                    Text(String(format: "profile.last_seen".localized, LastSeenFormatter.shared.relative(from: ts)))
                        .font(.caption2)
                        .foregroundColor(Theme.Color.textSecondary)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Theme.Color.textSecondary)
            // alignment .leading so multiline content (About me) lays out flush left
            // alongside the single-line key/value rows. Without this, SwiftUI's default
            // .center alignment centers any child wider than the column.
            VStack(alignment: .leading, spacing: 6) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Theme.Color.bgSecondary)
                .cornerRadius(4)
        }
    }

    /// Gender row: a constrained Picker for the owner so the
    /// only writable values are the three the server validates,
    /// or a read-only label + icon for everyone else.
    @ViewBuilder
    private func genderRow(_ profile: UserProfile) -> some View {
        // Resolve the gender we're rendering: draft (in-edit own
        // profile) → profile (committed). Empty string = "don't
        // share", same as the Picker tag for the dont_share option.
        let resolved = (isOwn ? (draft?.gender ?? profile.gender) : profile.gender) ?? ""
        let displayLabel = resolved.isEmpty
            ? "settings.privacy.gender.dont_share".localized
            : genderLabel(resolved)
        HStack {
            Text("profile.field.gender".localized)
                .font(.caption)
                .foregroundColor(Theme.Color.textSecondary)
                .frame(width: 110, alignment: .leading)
            if isOwn {
                // Menu with a CUSTOM label so we can stack the gender
                // text + glyph + dropdown chevron in our own HStack.
                // Stock SwiftUI Picker hides custom labels (and only
                // exposes Text-tagged options), which is why the
                // earlier Picker-with-icon-after-Spacer attempt
                // never actually rendered the glyph the user could
                // see — the label position belonged to the system
                // chrome, not our HStack. Menu honours arbitrary
                // SwiftUI content for both the trigger and the
                // option list.
                Menu {
                    Button("settings.privacy.gender.dont_share".localized) {
                        draft?.gender = nil
                    }
                    Button("settings.privacy.gender.male".localized) {
                        draft?.gender = "male"
                    }
                    Button("settings.privacy.gender.female".localized) {
                        draft?.gender = "female"
                    }
                    Button("settings.privacy.gender.other".localized) {
                        draft?.gender = "other"
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(displayLabel)
                            .foregroundColor(Theme.Color.textPrimary)
                        if !resolved.isEmpty {
                            GenderIcon(gender: resolved, size: 14)
                        }
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundColor(Theme.Color.textSecondary)
                    }
                }
                Spacer()
            } else if !resolved.isEmpty {
                // Icon AFTER the label text — reads as a small
                // trailing badge instead of a leading bullet.
                HStack(spacing: 6) {
                    Text(genderLabel(resolved))
                        .foregroundColor(Theme.Color.textPrimary)
                    GenderIcon(gender: resolved, size: 14)
                }
                Spacer()
            } else {
                Text("—").foregroundColor(Theme.Color.textPrimary)
                Spacer()
            }
        }
    }

    private func genderLabel(_ raw: String) -> String {
        switch raw {
        case "male":   return "settings.privacy.gender.male".localized
        case "female": return "settings.privacy.gender.female".localized
        case "other":  return "settings.privacy.gender.other".localized
        default:       return raw
        }
    }

    @ViewBuilder
    private func field(
        _ label: String, _ value: String, editable: Bool, mono: Bool = false,
        onChange: @escaping (String) -> Void
    ) -> some View {
        HStack {
            Text(label).font(.caption).foregroundColor(Theme.Color.textSecondary).frame(width: 110, alignment: .leading)
            if editable {
                TextField("", text: Binding(get: { value }, set: { onChange($0) }))
                    .foregroundColor(Theme.Color.textPrimary)
                    .font(mono ? Theme.Font.mono : .body)
            } else {
                Text(value.isEmpty ? "—" : value)
                    .foregroundColor(Theme.Color.textPrimary)
                    .font(mono ? Theme.Font.mono : .body)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func multiline(
        _ label: String, _ value: String, editable: Bool, onChange: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundColor(Theme.Color.textSecondary)
            if editable {
                TextField("", text: Binding(get: { value }, set: { onChange($0) }), axis: .vertical)
                    .lineLimit(3...8)
                    .foregroundColor(Theme.Color.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
            } else {
                Text(value.isEmpty ? "—" : value)
                    .foregroundColor(Theme.Color.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
            }
        }
    }

    private var hasChanges: Bool {
        guard let d = draft, let p = profile else { return false }
        return d != p
    }

    private var saveEnabled: Bool { isOwn && hasChanges && !saving }

    private func load() async {
        do {
            let p: UserProfile = try await APIClient.shared.request("GET", "/users/\(uin)/info")
            self.profile = p
            self.draft = p
            self.loading = false
            // Fire a sealed `.visit` envelope so the target device can tally a
            // "+1 in last 7 days" on their own profile. Skipped for our own
            // profile. Throttled per (target, session) inside MessageService.
            if !isOwn {
                Task {
                    await MessageService.shared.sendVisit(
                        toUIN: p.uin,
                        identityKey: p.identityKey,
                        signingKey: p.signingKey,
                        signalIdentityKey: p.signalIdentityKey
                    )
                }
            }
        } catch {
            self.loading = false
        }
    }

    private func save() async {
        guard let d = draft else { return }
        saving = true
        struct Body: Encodable {
            let nickname: String?
            let first_name: String?
            let last_name: String?
            let age: Int?
            let gender: String?
            let city: String?
            let country: String?
            let about: String?
            let interests: [String]?
            let homepage: String?
            let status_message: String?
        }
        let body = Body(
            nickname: d.nickname,
            first_name: d.firstName,
            last_name: d.lastName,
            age: d.age,
            gender: d.gender,
            city: d.city,
            country: d.country,
            about: d.about,
            interests: d.interests,
            homepage: d.homepage,
            status_message: d.statusMessage
        )
        do {
            let updated: UserProfile = try await APIClient.shared.request("PUT", "/users/me", body: body)
            self.profile = updated
            self.draft = updated
            AuthService.shared.updateNicknameLocal(updated.nickname)
        } catch { }
        saving = false
    }
}

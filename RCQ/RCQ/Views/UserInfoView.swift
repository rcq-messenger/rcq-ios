import LibSignalClient
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
    @State private var showGiveReputation = false
    @State private var showReputationHistory = false
    @State private var petPreview: PetPreviewTarget?
    /// One-shot flag — true briefly after reputation is granted to
    /// flash a green up-arrow next to the counter.
    @State private var repJustBumped = false
    @StateObject private var visits = VisitStore.shared
    @StateObject private var contacts = ContactService.shared
    // Observed so the custom-sound picker re-renders the moment an
    // assignment changes — without this the picker label kept showing
    // the previous pack until the whole view was rebuilt.
    @StateObject private var contactSounds = ContactSoundStore.shared

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
                            // Per-contact custom notification sound.
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
        .sheet(isPresented: $showReputationHistory) {
            ReputationHistorySheet()
        }
        .sheet(item: $petPreview) { wrap in
            PetPreviewSheet(
                pet: wrap.pet,
                ownerUIN: wrap.uin,
                ownerNickname: wrap.nickname,
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showGiveReputation) {
            if let p = profile {
                GiveReputationSheet(
                    targetUIN: p.uin,
                    targetNickname: p.nickname,
                ) { newTotal in
                    // Server is the source of truth; splice the
                    // post-grant total into the on-screen profile.
                    withAnimation { profile?.reputation = newTotal }
                    triggerRepBump()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .rcqReputationChanged)) { note in
            // Fired when a WS `reputation_changed` event lands. We
            // only update the on-screen profile if this view is
            // pointed at the same UIN whose counter just moved.
            guard let target = note.userInfo?["target_uin"] as? Int,
                  let total  = note.userInfo?["new_total"]  as? Int,
                  target == uin else { return }
            // The own-profile path renders `draft`, not `profile`
            // (see `body`'s `isOwn ? draft : profile`). Update BOTH
            // so the counter animates live whichever view is shown —
            // updating only `profile` left the visible `draft` stale.
            withAnimation {
                profile?.reputation = total
                draft?.reputation = total
            }
            triggerRepBump()
        }
    }

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
                Button {
                    resetSecureSession(uin: p.uin)
                } label: {
                    Label("profile.cta.reset_session".localized, systemImage: "key.fill")
                }
                Divider()
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
        let store = ContactSoundStore.shared
        let items = ItemsService.shared
        // Read live from the observed store (`contactSounds`) so the
        // picker reflects the current assignment on every render.
        let current = contactSounds.packID(for: uin) ?? SoundPack.default.id
        let packs = SoundPack.availablePacks(
            items: items.items,
            catalog: items.catalog,
        )
        HStack {
            Picker(selection: Binding(
                get: { current },
                set: { newValue in
                    store.setPack(newValue == SoundPack.default.id ? nil : newValue, for: uin)
                    // Preview the pack the user just picked so they
                    // hear what they assigned without round-tripping
                    // through the inventory to memorise a number.
                    if newValue != SoundPack.default.id {
                        SoundService.shared.preview(kindID: newValue)
                    }
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

            Spacer()

            // Replay the currently-assigned pack — lets the user
            // re-hear the choice without re-selecting it. Hidden when
            // the contact is on the default cue (nothing custom to
            // preview).
            if current != SoundPack.default.id {
                Button {
                    SoundService.shared.preview(kindID: current)
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(Theme.Color.accent)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func header(_ p: UserProfile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                // Tap the pet to preview it — same affordance as the
                // contact list / group info. Plain status icon stays
                // non-interactive when no pet is equipped.
                if let pet = p.equippedPet {
                    Button {
                        petPreview = PetPreviewTarget(
                            pet: pet, uin: p.uin, nickname: p.nickname,
                        )
                    } label: {
                        StatusWithPet(status: p.status, pet: pet, size: 48)
                    }
                    .buttonStyle(.plain)
                } else {
                    StatusWithPet(status: p.status, pet: nil, size: 48)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.nickname).font(.title3.bold()).foregroundColor(Theme.Color.textPrimary)
                    Text(String(p.uin)).font(Theme.Font.mono).foregroundColor(Theme.Color.textMono)
                    if let m = p.statusMessage, !m.isEmpty {
                        Text(m).font(.caption.italic()).foregroundColor(Theme.Color.textSecondary)
                    }
                    // Server filters lastSeen to nil when outside the
                    // target's privacy window. Only show when offline.
                    if p.status == .offline, let ts = p.lastSeen {
                        Text(String(format: "profile.last_seen".localized, LastSeenFormatter.shared.relative(from: ts)))
                            .font(.caption2)
                            .foregroundColor(Theme.Color.textSecondary)
                    }
                }
                Spacer()
            }
            reputationRow(p)
        }
    }

    @ViewBuilder
    private func reputationRow(_ p: UserProfile) -> some View {
        // Two display modes wrapped in a single row so the layout
        // doesn't shift between "rep visible" and "rep hidden".
        // - Visible: ⭐ 1.2K · [Give]
        // - Hidden (other user's privacy): just [Give Reputation]
        // - Own profile: ⭐ 1.2K (no Give button — can't grant to self)
        let value = p.reputation
        HStack(spacing: 10) {
            if let value {
                if isOwn {
                    // Owner's own counter — tappable, opens history.
                    Button {
                        showReputationHistory = true
                    } label: {
                        reputationValueContent(value, showChevron: true)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    // Other user's counter — plain, NOT a disabled
                    // Button (a disabled Button dimmed the whole row,
                    // which read as "greyed out / semi-transparent").
                    reputationValueContent(value, showChevron: false)
                }
            }
            Spacer()
            if !isOwn {
                Button {
                    showGiveReputation = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.caption2.weight(.bold))
                        Text(value == nil
                             ? "profile.reputation.give_long".localized
                             : "profile.reputation.give_short".localized)
                            .font(.caption.weight(.semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .foregroundColor(Theme.Color.accent)
                    .background(Theme.Color.accent.opacity(0.12))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// The ⭐ N row content, shared by the own (tappable) and the
    /// third-party (plain) render paths. `repJustBumped` flashes a
    /// one-shot green up-arrow when reputation was just granted.
    @ViewBuilder
    private func reputationValueContent(_ value: Int, showChevron: Bool) -> some View {
        HStack(spacing: 4) {
            ItemAssetImage(bundleSubdir: "Items", filename: "rep", ext: "gif")
                .frame(width: 15, height: 15)
            Text(value.compactCount)
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundColor(Theme.Color.textPrimary)
            Text("profile.reputation.label".localized)
                .font(.caption)
                .foregroundColor(Theme.Color.textSecondary)
            if repJustBumped {
                // One-shot rise — slides up + fades, no looping.
                Image(systemName: "arrow.up")
                    .font(.caption.weight(.bold))
                    .foregroundColor(.green)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if showChevron {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundColor(Theme.Color.textSecondary)
            }
        }
    }

    /// Flash the green up-arrow once, then retire it. Called both on a
    /// local grant success and on an inbound `reputation_changed` WS
    /// event for this UIN.
    private func triggerRepBump() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            repJustBumped = true
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            withAnimation(.easeOut(duration: 0.4)) { repJustBumped = false }
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Theme.Color.textSecondary)
            VStack(alignment: .leading, spacing: 6) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Theme.Color.bgSecondary)
                .cornerRadius(4)
        }
    }

    @ViewBuilder
    private func genderRow(_ profile: UserProfile) -> some View {
        // Empty string = "don't share" (same as the dont_share tag).
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
                // Menu (not Picker): Picker hides custom labels, so the
                // glyph next to the gender text needs Menu's free-form
                // trigger content.
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
            // Fire a sealed .visit envelope so the target can tally a
            // "+1 in last 7 days" tally. Throttled per (target, session)
            // inside MessageService.
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

    /// Drop the local libsignal session for this peer so the next
    /// outbound message bootstraps a fresh session against their
    /// CURRENT prekey bundle. Used when a peer reinstalls / re-
    /// registers and the sender's cached session points at stale
    /// identity keys — symptom is "messages go from sim to phone
    /// fine, but phone → sim arrives as ciphertext that decrypts to
    /// garbage and gets dropped silently". After a reset, the next
    /// /messages/sealed hits `processPreKeyBundle` again and the
    /// chain is healthy.
    private func resetSecureSession(uin: Int) {
        guard let addr = try? ProtocolAddress(name: String(uin), deviceId: 1) else { return }
        SignalProtocolStores.shared.deleteSession(for: addr)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

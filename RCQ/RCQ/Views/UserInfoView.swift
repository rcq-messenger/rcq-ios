import LibSignalClient
import SwiftUI

struct UserInfoView: View {
    let uin: Int
    let isOwn: Bool
    @Environment(\.dismiss) private var dismiss

    @State private var profile: UserProfile?
    /// §5c: the peer's island when this is a cross-island contact (gray flower,
    /// island shown instead of presence, no own-island fetch/visit).
    @State private var crossIslandHost: String?
    @State private var loading = true
    @State private var draft: UserProfile?
    @State private var saving = false
    @State private var showSafety = false
    @State private var identityChanged = false
    @StateObject private var visits = VisitStore.shared
    @StateObject private var contacts = ContactService.shared
    // Observed so the custom-sound picker re-renders the moment an
    // assignment changes — without this the picker label kept showing
    // the previous pack until the whole view was rebuilt.
    @StateObject private var contactSounds = ContactSoundStore.shared
    @StateObject private var aliasStore = ContactAliasStore.shared
    /// Non-nil while the rename sheet is open; holds the draft.
    @State private var aliasDraft: String?

    var body: some View {
        ZStack {
            Theme.Color.bgPrimary.ignoresSafeArea()
            if loading {
                ProgressView().tint(Theme.Color.accent)
            } else if let p = (isOwn ? draft : profile) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header(p)
                        if !isOwn, identityChanged {
                            Button {
                                openSafety()
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(Theme.Color.statusBusy)
                                    Text("profile.safety.changed".localized)
                                        .font(.footnote)
                                        .foregroundColor(Theme.Color.textPrimary)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.Color.bgSecondary)
                                .cornerRadius(8)
                            }
                        }
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
                            section("profile.section.security".localized) {
                                Button {
                                    openSafety()
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "lock.fill")
                                            .font(.caption)
                                            .foregroundColor(Theme.Color.textSecondary)
                                        Text("profile.safety.row".localized)
                                            .foregroundColor(Theme.Color.textPrimary)
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption)
                                            .foregroundColor(Theme.Color.textSecondary)
                                    }
                                }
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
        // Rename sheet. Deliberately an alert-style prompt rather than a
        // screen: it is one field and one decision.
        .alert("contact.set_name".localized, isPresented: Binding(
            get: { aliasDraft != nil },
            set: { if !$0 { aliasDraft = nil } }
        )) {
            TextField("contact.name_placeholder".localized, text: Binding(
                get: { aliasDraft ?? "" },
                set: { aliasDraft = $0 }
            ))
            Button("common.save".localized) {
                if let uin = profile?.uin ?? draft?.uin { aliasStore.setAlias(aliasDraft, for: uin) }
                aliasDraft = nil
            }
            if let uin = profile?.uin, aliasStore.alias(for: uin) != nil {
                Button("contact.clear_name".localized, role: .destructive) {
                    aliasStore.setAlias(nil, for: uin)
                    aliasDraft = nil
                }
            }
            Button("common.cancel".localized, role: .cancel) { aliasDraft = nil }
        } message: {
            Text("contact.name_hint".localized)
        }
        .sheet(isPresented: $showSafety) {
            SafetyNumberSheet(peerUIN: uin)
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
                // Open the 1:1 chat — shown only when the person is already a
                // contact (mutually exclusive with Add-to-contacts below).
                if ContactService.shared.contacts.contains(where: { $0.uin == p.uin }) {
                    Button {
                        // Set the intent BEFORE dismissing (the root NavigationStack
                        // consumes pendingOpenChatUIN; dismissing tears this sheet out).
                        AppState.shared.pendingOpenChatUIN = p.uin
                        dismiss()
                    } label: {
                        Label("profile.cta.open_chat".localized, systemImage: "bubble.left.and.bubble.right")
                    }
                    Divider()
                }
                // Add-to-contacts: shown only when target isn't the
                // viewer themselves and isn't already a confirmed
                // contact. If the user already sent the same request
                // earlier and re-taps, the server dedups (returns 400
                // "already requested") which the catch swallows.
                if !isOwn,
                   !ContactService.shared.contacts.contains(where: { $0.uin == p.uin }) {
                    Button {
                        Task {
                            try? await ContactService.shared.sendAddRequest(to: p.uin)
                            await ContactService.shared.refresh()
                        }
                    } label: {
                        Label("profile.cta.add_contact".localized, systemImage: "person.badge.plus")
                    }
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

    private func header(_ p: UserProfile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                PersonAvatarView(
                    mediaID: p.avatarMediaID, keyBase64: p.avatarMediaKey,
                    status: p.status, host: crossIslandHost, size: 64,
                    crossIsland: crossIslandHost != nil
                )
                VStack(alignment: .leading, spacing: 2) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(aliasStore.displayName(for: p.uin, fallback: p.nickname))
                            .font(.title3.bold())
                            .foregroundColor(Theme.Color.textPrimary)
                        // What THEY call themselves stays visible whenever it
                        // differs, so a rename never hides who you are talking to.
                        if let mine = aliasStore.alias(for: p.uin), mine != p.nickname {
                            Text(String(format: "contact.their_name".localized, p.nickname))
                                .font(.caption)
                                .foregroundColor(Theme.Color.textSecondary)
                        }
                    }
                    Text(verbatim: "#\(p.uin)").font(Theme.Font.mono).foregroundColor(Theme.Color.textMono)
                    // Cross-island: show the island (presence doesn't cross islands).
                    if let h = crossIslandHost {
                        Text(verbatim: h).font(Theme.Font.mono).foregroundColor(Theme.Color.textSecondary)
                    }
                    if !isOwn {
                        Button(aliasStore.alias(for: p.uin) == nil
                               ? "contact.set_name".localized
                               : "contact.change_name".localized) {
                            aliasDraft = aliasStore.alias(for: p.uin) ?? ""
                        }
                        .font(.caption)
                        .foregroundColor(Theme.Color.accent)
                    }
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
        // §5c: a cross-island contact's profile lives on ITS island — our own
        // /users/{uin}/info 404s. Render from the locally-merged card and skip
        // the fetch + visit ping (the ping would mis-route to our island).
        if !isOwn, let c = ContactService.shared.contacts.first(where: { $0.uin == uin && $0.host != nil }) {
            var dict: [String: Any] = [
                "uin": c.uin, "nickname": c.nickname, "status": "offline", "interests": [],
                "identity_key": c.identityKey, "signing_key": c.signingKey,
            ]
            if let g = c.gender { dict["gender"] = g }
            if let s = c.statusMessage { dict["status_message"] = s }
            if let sik = c.signalIdentityKey { dict["signal_identity_key"] = sik }
            if let data = try? JSONSerialization.data(withJSONObject: dict),
               let p = try? JSONDecoder().decode(UserProfile.self, from: data) {
                self.profile = p
                self.crossIslandHost = c.host
            }
            self.loading = false
            return
        }
        do {
            let p: UserProfile = try await APIClient.shared.request("GET", "/users/\(uin)/info")
            self.profile = p
            self.draft = p
            self.loading = false
            // Fire a sealed .visit envelope so the target can tally a
            // "+1 in last 7 days" tally. Throttled per (target, session)
            // inside MessageService.
            if !isOwn {
                identityChanged = SignalProtocolStores.shared.peerIdentityChanged(uin)
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

    /// Present the safety-number sheet. Opening it to re-check counts as
    /// acknowledging any pending identity-change warning, so the banner
    /// clears (matches the Android contact-info flow).
    private func openSafety() {
        if identityChanged {
            SignalProtocolStores.shared.acknowledgePeerIdentity(uin)
            identityChanged = false
        }
        showSafety = true
    }
}

/// Out-of-band key-fingerprint verification. Shows the 60-digit safety
/// number for the v=2 conversation with [peerUIN] so two users can compare
/// it over a trusted channel; a match means no key was swapped by the
/// server. The number is identical to what the Android client shows for the
/// same pair. Returns nil (and the "nothing to verify" copy) when the peer
/// is v=1-only or we aren't bootstrapped.
private struct SafetyNumberSheet: View {
    let peerUIN: Int

    @Environment(\.dismiss) private var dismiss
    @State private var number: String?
    @State private var loading = true

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 16) {
                    if loading {
                        VStack(spacing: 10) {
                            ProgressView().tint(Theme.Color.accent)
                            Text("profile.safety.computing".localized)
                                .font(.caption)
                                .foregroundColor(Theme.Color.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 32)
                    } else if let n = number {
                        Text(n)
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(Theme.Color.textPrimary)
                            .lineSpacing(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        Text("profile.safety.body".localized)
                            .font(.footnote)
                            .foregroundColor(Theme.Color.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("profile.safety.unavailable".localized)
                            .font(.footnote)
                            .foregroundColor(Theme.Color.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                .padding(20)
            }
            .navigationTitle("profile.safety.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("common.close".localized) { dismiss() }
                        .foregroundColor(Theme.Color.accent)
                }
            }
        }
        .task {
            number = await SignalCryptoService.safetyNumber(forPeerUIN: peerUIN)
            loading = false
        }
    }
}

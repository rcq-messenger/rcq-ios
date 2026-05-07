import SwiftUI

/// People Nearby surface. Opt-in TTL picker → check-in →
/// scrollable list of other users currently checked in to the same
/// 1km bucket. Refreshes every 30s while open.
///
/// Privacy posture mirrored from `NearbyService`'s comment block:
///   - Server stores opaque hash, never raw GPS
///   - Mutual visibility (must be checked in to see others)
///   - TTL bounded — 30 min / 1 h / 3 h presets, no "always on"
///   - Tap on a row offers contact-request only — no DM, no calls
///     until the request is accepted
struct NearbyView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var service = NearbyService.shared
    @StateObject private var contacts = ContactService.shared
    @State private var pickedTTL: TTLPreset = .oneHour
    @State private var sentRequests: Set<Int> = []
    @State private var showHood: Bool = false
    @State private var showRadio: Bool = false
    /// Anonymous mini-profile for a tapped person row. Same
    /// minimal sheet as Hood Chat — anonymous nick + UIN +
    /// Add-as-contact, deliberately no real-profile leakage.
    @State private var profileTarget: NearbyPerson?

    /// Label shown in the active-screen header. Anonymous mode
    /// surfaces the minted handle; non-anonymous surfaces the
    /// real account nickname so the user has visible feedback
    /// that the toggle is OFF.
    private var visibleAsLabel: String {
        if service.anonymous { return service.displayName }
        let nick = AuthService.shared.nickname
        return nick.isEmpty ? "nearby.active.you_label".localized : nick
    }

    enum TTLPreset: TimeInterval, CaseIterable, Identifiable {
        case thirtyMinutes = 1800
        case oneHour = 3600
        case threeHours = 10800

        var id: TimeInterval { rawValue }
        var label: String {
            switch self {
            case .thirtyMinutes: return "nearby.ttl.30m".localized
            case .oneHour:       return "nearby.ttl.1h".localized
            case .threeHours:    return "nearby.ttl.3h".localized
            }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                content
            }
            .navigationTitle("nearby.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".localized) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // Radio Chat lives here — both surfaces share
                    // the "find people physically near me" mental
                    // model: Nearby = people on the same geohash
                    // bucket via the server, Radio = people on the
                    // same Bluetooth/Wi-Fi mesh with no server.
                    Button {
                        showRadio = true
                    } label: {
                        // SF Symbols ships no Bluetooth runic glyph at
                        // any point in 5.x. Stick with the antenna —
                        // it reads as "wireless / radio" which is
                        // semantically what Radio Chat is.
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundColor(Theme.Color.accent)
                    }
                }
            }
            .task { await service.refreshList() }
            // NOTE: deliberately NO `onDisappear { service.stop() }`.
            // Closing this sheet shouldn't end your visibility — the
            // TTL preset is the maximum time you've opted in for
            // (e.g. "30 min visible") and it should keep ticking
            // while the app is open / backgrounded so people can
            // still see you and send Add requests. Auto-stop happens
            // when the *app* is terminated, wired in
            // `NearbyService.init` via `willTerminateNotification`.
            .sheet(isPresented: $showHood) {
                if case .active(let bucket, _) = service.state {
                    HoodChatView(bucket: bucket)
                }
            }
            .fullScreenCover(isPresented: $showRadio) {
                RadioDiscoveryView()
            }
            .sheet(item: $profileTarget) { p in
                // Always render against the live row from
                // `service.people` so a presence change while
                // the sheet is up updates the status icon
                // in-place. Falls back to the captured copy if
                // the row has aged out of the list (e.g. they
                // went offline mid-view — sheet stays open with
                // the last-known status rather than emptying).
                let live = service.people.first(where: { $0.uin == p.uin }) ?? p
                anonymousProfile(live)
                    .presentationDetents([.height(320)])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch service.state {
        case .idle:
            optInScreen
        case .pending:
            VStack(spacing: 12) {
                ProgressView().tint(Theme.Color.accent)
                Text("nearby.searching".localized)
                    .font(.caption)
                    .foregroundColor(Theme.Color.textSecondary)
            }
        case .active(_, let expiresAt):
            activeScreen(expiresAt: expiresAt)
        case .denied:
            deniedScreen
        case .error(let msg):
            errorScreen(msg)
        }
    }

    // MARK: - opt-in

    private var optInScreen: some View {
        // Roulette-style centred composition: Spacer above and
        // below pushes the cluster toward the visual middle of the
        // sheet, matching how the Random Chat entry surface feels.
        // Slight upward bias (Spacer ratio 1:1.4) so the call-to-
        // action button doesn't sink below the natural reading line.
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "location.viewfinder")
                .font(.system(size: 64))
                .foregroundColor(Theme.Color.accent)
            VStack(spacing: 6) {
                Text("nearby.optin.heading".localized)
                    .font(.title2.bold())
                    .foregroundColor(Theme.Color.textPrimary)
                Text("nearby.optin.body".localized)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundColor(Theme.Color.textSecondary)
                    .padding(.horizontal, 28)
            }
            Picker("nearby.optin.visible_for".localized, selection: $pickedTTL) {
                ForEach(TTLPreset.allCases) { p in
                    Text(p.label).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 32)
            // Anonymous-vs-real-nickname switch. ON by default —
            // the People Nearby spec is "be visible to strangers
            // without revealing who you are". The opt-out is for
            // power-users who deliberately want their real
            // nickname (and the matching real profile, if a
            // contact request comes in) on the list.
            Toggle(isOn: Binding(
                get: { service.anonymous },
                set: { service.setAnonymous($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("nearby.optin.anonymous".localized)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(Theme.Color.textPrimary)
                    Text(service.anonymous
                         ? String(format: "nearby.optin.anonymous.on".localized, service.displayName)
                         : "nearby.optin.anonymous.off".localized)
                        .font(.caption2)
                        .foregroundColor(Theme.Color.textSecondary)
                }
            }
            .tint(Theme.Color.accent)
            .padding(.horizontal, 32)
            Button {
                service.start(ttlSeconds: pickedTTL.rawValue)
            } label: {
                Text("nearby.optin.cta".localized)
                    .font(.system(.title3, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.Color.accent)
                    .cornerRadius(8)
            }
            .padding(.horizontal, 32)
            Text("nearby.optin.privacy_note".localized)
                .font(.caption2)
                .multilineTextAlignment(.center)
                .foregroundColor(Theme.Color.textSecondary)
                .padding(.horizontal, 32)
            Spacer()
            Spacer()
        }
    }

    // MARK: - active

    private func activeScreen(expiresAt: Date) -> some View {
        let bucketTag: String? = {
            if case .active(let bucket, _) = service.state { return bucket }
            return nil
        }()
        return VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundColor(Theme.Color.accent)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text("nearby.active.you_are".localized)
                            .font(.caption.weight(.semibold))
                            .foregroundColor(Theme.Color.textPrimary)
                        + Text(visibleAsLabel)
                            .font(.caption.weight(.semibold))
                            .foregroundColor(Theme.Color.accent)
                        if service.anonymous {
                            Button {
                                service.regenerateDisplayName()
                            } label: {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.caption2)
                                    .foregroundColor(Theme.Color.textSecondary)
                            }
                        }
                    }
                    HStack(spacing: 6) {
                        Text(String(format: "nearby.active.until".localized, timeLabel(expiresAt)))
                            .font(.caption2)
                            .foregroundColor(Theme.Color.textSecondary)
                        if let bucketTag {
                            // Surfaced as a debug aid: when two
                            // devices don't see each other,
                            // comparing the bucket strings tells
                            // you whether their simulated
                            // locations actually matched. Same
                            // hash = same area; should overlap.
                            Text(String(format: "nearby.active.area".localized, bucketTag))
                                .font(.caption2.monospaced())
                                .foregroundColor(Theme.Color.textMono)
                        }
                    }
                }
                Spacer()
                Button("nearby.active.stop".localized) {
                    Task { await service.stop() }
                }
                .font(.caption.weight(.semibold))
                .foregroundColor(Theme.Color.statusBusy)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Theme.Color.bgSecondary)

            // Hood Chat entry. Always visible while checked-in;
            // tap opens the bucket-local public room. Subtle
            // accent strip rather than a primary CTA — the main
            // surface here is the people list.
            Button {
                showHood = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .foregroundColor(Theme.Color.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("nearby.hood.title".localized)
                            .font(.caption.weight(.semibold))
                            .foregroundColor(Theme.Color.textPrimary)
                        Text("nearby.hood.body".localized)
                            .font(.caption2)
                            .foregroundColor(Theme.Color.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundColor(Theme.Color.textSecondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Theme.Color.accent.opacity(0.08))
            }
            .buttonStyle(.plain)

            if service.people.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "person.fill.questionmark")
                        .font(.system(size: 28))
                        .foregroundColor(Theme.Color.textSecondary)
                    Text("nearby.empty.title".localized)
                        .font(.caption)
                        .foregroundColor(Theme.Color.textSecondary)
                    Text("nearby.empty.body".localized)
                        .font(.caption2)
                        .foregroundColor(Theme.Color.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(service.people) { person in
                            personRow(person)
                            Divider().background(Theme.Color.divider)
                        }
                    }
                    .padding(.top, 4)
                }
                .refreshable {
                    await service.refreshList()
                }
            }
        }
    }

    private func personRow(_ person: NearbyPerson) -> some View {
        let alreadyContact = contacts.contacts.contains(where: { $0.uin == person.uin })
        let requestSent = sentRequests.contains(person.uin)
        return Button {
            profileTarget = person
        } label: {
            HStack(spacing: 10) {
                StatusIcon(status: person.status, size: 28).frame(width: 36)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(person.nickname)
                            .font(Theme.Font.nickname)
                            .foregroundColor(Theme.Color.textPrimary)
                        // Gender icon survives anonymous mode —
                        // server only ships it when the user has
                        // explicitly chosen `gender_visibility =
                        // "everyone"`, so showing it here is a
                        // direct echo of their own choice.
                        GenderIcon(gender: person.gender)
                    }
                    // Anonymous users get the neutral "Nearby"
                    // tag — UIN is hidden because the whole
                    // point of anonymous mode is "stranger
                    // discoverability without ID-leak". Users
                    // who explicitly opted out of anonymous mode
                    // get their UIN inline since they signed up
                    // for being identifiable.
                    if person.anonymous {
                        Text("nearby.row.tag".localized)
                            .font(.caption2)
                            .foregroundColor(Theme.Color.textSecondary)
                    } else {
                        Text(String(person.uin))
                            .font(Theme.Font.monoSmall)
                            .foregroundColor(Theme.Color.textMono)
                    }
                }
                Spacer()
                if alreadyContact {
                    Text("nearby.row.in_contacts".localized)
                        .font(.caption2)
                        .foregroundColor(Theme.Color.textSecondary)
                } else if requestSent {
                    Text("nearby.row.requested".localized)
                        .font(.caption2)
                        .foregroundColor(Theme.Color.textSecondary)
                } else {
                    // Quick-add button stays on the row so the
                    // user can fire a request without opening
                    // the mini-profile.
                    Button {
                        Task {
                            try? await ContactService.shared.sendAddRequest(to: person.uin)
                            sentRequests.insert(person.uin)
                        }
                    } label: {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.system(size: 18))
                            .foregroundColor(Theme.Color.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Theme.Color.bgPrimary)
        }
        .buttonStyle(.plain)
    }

    /// Mini-profile sheet shown when the user taps a row in the
    /// list. Fully anonymous: only the display nickname and the
    /// status icon are surfaced. UIN is *deliberately* hidden in
    /// the UI — it lives in the data model just so `Add as
    /// contact` can route through `/contacts/request`, but
    /// rendering it would defeat the point (any onlooker could
    /// punch the UIN into search and resolve the real account).
    @ViewBuilder
    private func anonymousProfile(_ person: NearbyPerson) -> some View {
        let alreadyContact = contacts.contacts.contains(where: { $0.uin == person.uin })
        let requestSent = sentRequests.contains(person.uin)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                StatusIcon(status: person.status, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(person.nickname)
                            .font(.title3.bold())
                            .foregroundColor(Theme.Color.textPrimary)
                        GenderIcon(gender: person.gender, size: 16)
                    }
                    if person.anonymous {
                        Text("nearby.profile.anonymous".localized)
                            .font(.caption2)
                            .foregroundColor(Theme.Color.textSecondary)
                    } else {
                        Text(String(person.uin))
                            .font(Theme.Font.monoSmall)
                            .foregroundColor(Theme.Color.textMono)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 36)
            .padding(.horizontal, 20)
            Text(person.anonymous
                 ? "nearby.profile.body.anon".localized
                 : "nearby.profile.body.real".localized)
                .font(.caption)
                .foregroundColor(Theme.Color.textSecondary)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 20)
            // Push the CTA all the way to the floor of the
            // sheet — same idiom as the system share sheet so
            // the primary action lands under the user's thumb.
            Spacer()
            if alreadyContact {
                Text("nearby.profile.already".localized)
                    .font(.caption)
                    .foregroundColor(Theme.Color.textSecondary)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
            } else if requestSent {
                Text("nearby.profile.sent".localized)
                    .font(.caption)
                    .foregroundColor(Theme.Color.textSecondary)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
            } else {
                Button {
                    Task {
                        try? await ContactService.shared.sendAddRequest(to: person.uin)
                        sentRequests.insert(person.uin)
                        profileTarget = nil
                    }
                } label: {
                    Text("nearby.profile.add_contact".localized)
                        .font(.system(.body, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Theme.Color.accent)
                        .cornerRadius(8)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func timeLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: date)
    }

    // MARK: - error states

    private var deniedScreen: some View {
        VStack(spacing: 14) {
            Image(systemName: "location.slash")
                .font(.system(size: 36))
                .foregroundColor(Theme.Color.statusBusy)
            Text("nearby.denied.title".localized)
                .font(.title3.bold())
                .foregroundColor(Theme.Color.textPrimary)
            Text("nearby.denied.body".localized)
                .font(.caption)
                .foregroundColor(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("nearby.denied.cta".localized) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .padding(.top, 8)
        }
        .padding(.top, 40)
    }

    private func errorScreen(_ msg: String) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundColor(Theme.Color.statusBusy)
            Text(msg)
                .font(.caption)
                .foregroundColor(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            // "Try again" alone wasn't enough — `start()` is a no-op
            // when the state machine is already in `.error` (the
            // pending guard rejects the new request). The Reset path
            // forces back to `.idle` first so the next start fires
            // a fresh location request.
            Button {
                service.forceReset()
                // Defer to the next tick so the @Published state
                // change has time to propagate before we start a
                // new request.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    service.start(ttlSeconds: pickedTTL.rawValue)
                }
            } label: {
                Text("nearby.error.cta".localized)
                    .font(.system(.body, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.Color.accent)
                    .cornerRadius(6)
            }
            .padding(.horizontal, 32)
            Spacer()
        }
    }
}

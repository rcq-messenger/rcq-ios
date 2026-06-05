import SwiftUI

/// People Nearby surface. Opt-in TTL picker, check-in, list of others in the same 1km bucket.
struct NearbyView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var service = NearbyService.shared
    @StateObject private var contacts = ContactService.shared
    @State private var pickedTTL: TTLPreset = .oneHour
    @State private var sentRequests: Set<Int> = []
    @State private var showRadio: Bool = false
    @State private var profileTarget: NearbyPerson?
    @State private var showHood: Bool = false

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
                    Button {
                        showRadio = true
                    } label: {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundColor(Theme.Color.accent)
                    }
                }
            }
            .task { await service.refreshList() }
            // No onDisappear stop: visibility is bound by TTL, not sheet lifetime.
            .fullScreenCover(isPresented: $showRadio) {
                RadioDiscoveryView()
            }
            .sheet(item: $profileTarget) { p in
                // Render against the live row so presence changes update in-place.
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

            if let bucket = bucketTag {
                hoodChatButton(bucket: bucket)
                    .sheet(isPresented: $showHood) {
                        HoodChatView(bucket: bucket)
                    }
            }

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

            // Banner carousel pinned to the bottom of the screen
            // below the people list / empty state. The Hood-Chat
            // button stays up top; banners live down here so the
            // page doesn't feel front-loaded.
            if let bucket = bucketTag {
                HoodBannerCarousel(bucket: bucket)
                    .padding(.top, 6)
                    .padding(.bottom, 8)
            }
        }
    }

    private func hoodChatButton(bucket: String) -> some View {
        Button {
            showHood = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Theme.Color.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("nearby.hood.title".localized)
                        .font(.system(.callout, weight: .semibold))
                        .foregroundColor(Theme.Color.textPrimary)
                    Text("nearby.hood.body".localized)
                        .font(.caption2)
                        .foregroundColor(Theme.Color.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Theme.Color.textSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.Color.bgSecondary)
            .cornerRadius(10)
            .padding(.horizontal, 14)
            .padding(.top, 8)
        }
        .buttonStyle(.plain)
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
                        GenderIcon(gender: person.gender)
                    }
                    if person.anonymous {
                        Text("nearby.row.tag".localized)
                            .font(.caption2)
                            .foregroundColor(Theme.Color.textSecondary)
                    } else {
                        Text("#\(person.uin)")
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
                        Text("#\(person.uin)")
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
            // forceReset before start — start() is a no-op while state is .error.
            Button {
                service.forceReset()
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

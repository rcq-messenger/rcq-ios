import SwiftUI

struct AddContactView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var groupSvc = GroupService.shared
    @State private var query: String = ""
    @State private var results: [UserProfile] = []
    @State private var loading = false
    @State private var sentTo: Set<Int> = []
    @State private var foreignGroups: [GroupService.Preview] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var joinPreview: GroupService.Preview?
    /// Pre-filled UIN from an `rcq://add/{uin}` deep link.
    var prefillUIN: Int? = nil
    var onSelectGroup: ((RCQGroup) -> Void)? = nil

    private var groupMatches: [RCQGroup] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return groupSvc.groups.filter {
            $0.name.lowercased().contains(q) || String($0.id).contains(q)
        }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundColor(Theme.Color.textSecondary)
                        TextField("add.search.placeholder".localized, text: $query)
                            .textInputAutocapitalization(.never)
                            .submitLabel(.search)
                            .onSubmit { Task { await search() } }
                            .foregroundColor(Theme.Color.textPrimary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Theme.Color.bgSecondary)
                    .cornerRadius(8)
                    .padding(12)

                    if loading {
                        ProgressView().tint(Theme.Color.accent).padding(.top, 32)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                if !foreignGroups.isEmpty {
                                    sectionHeader("add.section.join_group".localized)
                                    ForEach(foreignGroups) { preview in
                                        Button {
                                            joinPreview = preview
                                        } label: {
                                            GroupPreviewHit(preview: preview)
                                        }
                                        Divider().background(Theme.Color.divider)
                                    }
                                }
                                if !groupMatches.isEmpty {
                                    sectionHeader("add.section.groups".localized)
                                    ForEach(groupMatches) { g in
                                        Button {
                                            if let onSelectGroup {
                                                onSelectGroup(g)
                                                dismiss()
                                            }
                                        } label: {
                                            GroupHit(group: g)
                                        }
                                        Divider().background(Theme.Color.divider)
                                    }
                                }
                                if !results.isEmpty {
                                    sectionHeader("add.section.people".localized)
                                    ForEach(results, id: \.uin) { user in
                                        NavigationLink(destination: AddDetailView(user: user, alreadySent: sentTo.contains(user.uin)) {
                                            sentTo.insert(user.uin)
                                        }) {
                                            AddRow(user: user, alreadySent: sentTo.contains(user.uin))
                                        }
                                        Divider().background(Theme.Color.divider)
                                    }
                                }
                            }
                        }
                    }
                    Spacer()
                }
            }
            .navigationTitle("add.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.close".localized) { dismiss() } }
            }
            .task {
                if let uin = prefillUIN {
                    query = String(uin)
                    await search()
                }
            }
            .onChange(of: query) { _ in
                scheduleForeignGroupSearch()
            }
            .sheet(item: $joinPreview) { preview in
                JoinGroupSheet(preview: preview, onJoined: { group in
                    joinPreview = nil
                    if let onSelectGroup {
                        onSelectGroup(group)
                    }
                    dismiss()
                })
                .presentationDetents([.fraction(0.5), .large])
                .presentationDragIndicator(.visible)
            }
        }
    }

    private func scheduleForeignGroupSearch() {
        searchTask?.cancel()
        let q = trimmedQuery
        guard q.count >= 2 else {
            foreignGroups = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            let rows = await groupSvc.search(query: q)
            if !Task.isCancelled, q == trimmedQuery {
                foreignGroups = rows
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(Theme.Color.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(Theme.Color.bgSecondary.opacity(0.7))
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        loading = true
        defer { loading = false }
        do {
            let rows: [UserProfile] = try await APIClient.shared.request(
                "GET", "/users/search", query: ["q": q, "limit": "30"]
            )
            // Defensive filter; server should also exclude self.
            let me = AuthService.shared.ownUIN
            self.results = rows.filter { $0.uin != me }
        } catch { }
    }
}

private struct GroupPreviewHit: View {
    let preview: GroupService.Preview

    var body: some View {
        HStack(spacing: 10) {
            GroupAvatarView(
                mediaID: preview.avatarMediaID,
                keyBase64: preview.avatarMediaKey,
                size: 28,
                glyphSize: 14,
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(preview.name)
                    .font(Theme.Font.nickname)
                    .foregroundColor(Theme.Color.textPrimary)
                HStack(spacing: 4) {
                    Text(String(
                        format: (preview.memberCount == 1
                            ? "contact_list.members_one"
                            : "contact_list.members_many").localized,
                        preview.memberCount,
                    ))
                    .font(Theme.Font.monoSmall)
                    .foregroundColor(Theme.Color.textMono)
                    if let nick = preview.ownerNickname, !nick.isEmpty {
                        Text("·").foregroundColor(Theme.Color.textMono)
                        Image(systemName: "crown.fill")
                            .font(.system(size: 9))
                            .foregroundColor(Theme.Color.textSecondary)
                        Text(nick).font(.caption2).foregroundColor(Theme.Color.textSecondary)
                    }
                }
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundColor(Theme.Color.textSecondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

struct JoinGroupSheet: View {
    let preview: GroupService.Preview
    var onJoined: (RCQGroup) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var groups = GroupService.shared
    @State private var busy: Bool = false
    @State private var alertMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 50))
                        .foregroundColor(.white)
                        .frame(width: 96, height: 96)
                        .background(Circle().fill(Theme.Color.accent))
                        .padding(.top, 12)
                    VStack(spacing: 6) {
                        Text(preview.name).font(.title3.bold())
                            .foregroundColor(Theme.Color.textPrimary)
                            .multilineTextAlignment(.center)
                        Text(String(
                            format: (preview.memberCount == 1
                                ? "contact_list.members_one"
                                : "contact_list.members_many").localized,
                            preview.memberCount,
                        ))
                        .font(.callout)
                        .foregroundColor(Theme.Color.textSecondary)
                    }
                    Button {
                        Task { await join() }
                    } label: {
                        Text("join_group.cta.free".localized)
                            .font(.system(.body, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Theme.Color.accent)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                }
                .padding(20)
            }
            .background(Theme.Color.bgPrimary.ignoresSafeArea())
            .navigationTitle("join_group.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel".localized) { dismiss() }
                }
            }
            .alert("join_group.alert.title".localized,
                   isPresented: Binding(
                    get: { alertMessage != nil },
                    set: { if !$0 { alertMessage = nil } }
                   ),
                   actions: { Button("common.ok".localized, role: .cancel) {} },
                   message: { Text(alertMessage ?? "") })
        }
    }

    private func join() async {
        busy = true
        defer { busy = false }
        let result = await groups.join(groupID: preview.id)
        switch result {
        case .success(let g):
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onJoined(g)
        case .blocked:
            alertMessage = "join_group.error.blocked".localized
        case .closed:
            alertMessage = "group_join.closed_hint".localized
        case .other(let m):
            alertMessage = m.isEmpty ? "join_group.error.generic".localized : m
        }
    }
}

private struct GroupHit: View {
    let group: RCQGroup

    var body: some View {
        HStack(spacing: 10) {
            GroupAvatarView(
                mediaID: group.avatarMediaID,
                keyBase64: group.avatarMediaKey,
                size: 28,
                glyphSize: 14,
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(group.name).font(Theme.Font.nickname).foregroundColor(Theme.Color.textPrimary)
                Text(String(
                    format: (group.members.count == 1
                        ? "contact_list.members_one"
                        : "contact_list.members_many").localized,
                    group.members.count
                ))
                    .font(Theme.Font.monoSmall).foregroundColor(Theme.Color.textMono)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundColor(Theme.Color.textSecondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

private struct AddRow: View {
    let user: UserProfile
    let alreadySent: Bool
    @StateObject private var contacts = ContactService.shared

    private var alreadyInList: Bool {
        contacts.contacts.contains(where: { $0.uin == user.uin })
    }

    var body: some View {
        HStack(spacing: 10) {
            StatusIcon(status: user.status, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(user.nickname).font(Theme.Font.nickname).foregroundColor(Theme.Color.textPrimary)
                Text(String(user.uin)).font(Theme.Font.monoSmall).foregroundColor(Theme.Color.textMono)
                let parts = [user.city, user.country].compactMap { $0?.isEmpty == false ? $0 : nil }
                if !parts.isEmpty {
                    Text(parts.joined(separator: ", "))
                        .font(.caption2)
                        .foregroundColor(Theme.Color.textSecondary)
                }
            }
            Spacer()
            if alreadyInList {
                Text("add.row.added".localized).font(.caption2).foregroundColor(Theme.Color.statusOnline)
            } else if alreadySent {
                Text("add.row.pending".localized).font(.caption2).foregroundColor(Theme.Color.statusAway)
            } else {
                Image(systemName: "chevron.right").foregroundColor(Theme.Color.textSecondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

private struct AddDetailView: View {
    let user: UserProfile
    let alreadySent: Bool
    let onSent: () -> Void
    @StateObject private var contacts = ContactService.shared
    @State private var sending = false
    @State private var sent = false
    @State private var errorMessage: String? = nil

    private var alreadyInList: Bool {
        contacts.contacts.contains(where: { $0.uin == user.uin })
    }

    private var buttonState: (text: String, disabled: Bool, color: SwiftUI.Color) {
        if alreadyInList { return ("add.cta.in_list".localized, true, Theme.Color.textSecondary.opacity(0.5)) }
        if sending       { return ("add.cta.sending".localized, true, Theme.Color.textSecondary.opacity(0.5)) }
        if sent || alreadySent { return ("add.cta.sent".localized, true, Theme.Color.statusAway) }
        return ("add.cta.add".localized, false, Theme.Color.accent)
    }

    var body: some View {
        ZStack {
            Theme.Color.bgPrimary.ignoresSafeArea()
            VStack(spacing: 16) {
                StatusIcon(status: user.status, size: 64)
                Text(user.nickname).font(.title2.bold()).foregroundColor(Theme.Color.textPrimary)
                Text(String(user.uin)).font(Theme.Font.mono).foregroundColor(Theme.Color.textMono)
                if let about = user.about, !about.isEmpty {
                    Text(about).font(.body).foregroundColor(Theme.Color.textSecondary)
                        .multilineTextAlignment(.center).padding(.horizontal, 24)
                }
                Button {
                    Task { await sendRequest() }
                } label: {
                    Text(buttonState.text)
                        .font(.system(.body, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(buttonState.color)
                        .cornerRadius(4)
                }
                .padding(.horizontal, 24)
                .disabled(buttonState.disabled)

                if let err = errorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(Theme.Color.statusBusy)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                Spacer()
            }
            .padding(.top, 24)
        }
        .navigationTitle("add.contact_info".localized)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sendRequest() async {
        sending = true
        errorMessage = nil
        defer { sending = false }
        do {
            try await ContactService.shared.sendAddRequest(to: user.uin)
            onSent()
            sent = true
            // Server may have auto-accepted — refresh without waiting for the WS event.
            await ContactService.shared.refresh()
        } catch let APIError.http(code, _) where code == 409 {
            errorMessage = "add.error.duplicate".localized
            await ContactService.shared.refresh()
        } catch {
            errorMessage = String(format: "add.error.generic".localized, error.localizedDescription)
        }
    }
}

struct PendingRequestsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var contacts = ContactService.shared

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                if contacts.pendingRequests.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(contacts.pendingRequests) { req in
                            requestRow(req)
                                .listRowBackground(Theme.Color.bgSecondary)
                                .transition(.asymmetric(
                                    insertion: .opacity,
                                    removal: .opacity.combined(with: .move(edge: .trailing))
                                ))
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .animation(.easeInOut(duration: 0.25), value: contacts.pendingRequests.count)
                }
            }
            .navigationTitle("pending.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.close".localized) { dismiss() } }
            }
            .navigationDestination(for: Int.self) { uin in
                UserInfoView(uin: uin, isOwn: false)
            }
        }
        .presentationDetents([.fraction(0.32), .large])
        .presentationDragIndicator(.visible)
    }

    private func requestRow(_ req: ContactService.PendingRequest) -> some View {
        // `String(req.from_uin)` bypasses Text's locale-aware grouping separators.
        VStack(alignment: .leading, spacing: 8) {
            NavigationLink(value: req.from_uin) {
                Text(String(format: "pending.row.body".localized, req.nickname, String(req.from_uin)))
                    .font(.body)
                    .foregroundColor(Theme.Color.textPrimary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            HStack(spacing: 12) {
                Button("pending.cta.accept".localized) {
                    Task { try? await contacts.respond(requestID: req.id, accept: true) }
                }
                .buttonStyle(.borderedProminent).tint(Theme.Color.statusOnline)
                Button("pending.cta.decline".localized) {
                    Task { try? await contacts.respond(requestID: req.id, accept: false) }
                }
                .buttonStyle(.bordered).tint(Theme.Color.statusBusy)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 36))
                .foregroundColor(Theme.Color.textSecondary)
            Text("pending.empty.title".localized)
                .font(.headline)
                .foregroundColor(Theme.Color.textPrimary)
            Text("pending.empty.body".localized)
                .font(.caption)
                .foregroundColor(Theme.Color.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var auth = AuthService.shared

    var body: some View {
        NavigationStack {
            if let uin = auth.ownUIN {
                UserInfoView(uin: uin, isOwn: true)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("common.close".localized) { dismiss() } }
                    }
            } else {
                Text("add.no_identity".localized).foregroundColor(Theme.Color.textSecondary)
            }
        }
        
    }
}

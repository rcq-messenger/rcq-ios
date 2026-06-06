import SwiftUI

struct GroupInfoView: View {
    let group: RCQGroup

    @Environment(\.dismiss) private var dismiss
    @StateObject private var groups = GroupService.shared
    @StateObject private var contacts = ContactService.shared
    @StateObject private var sound = SoundService.shared
    @State private var showAddMember = false
    @State private var confirmLeave = false
    @State private var error: String?
    @State private var viewInfoForUIN: Int?
    @State private var actionMember: RCQGroupMember?
    @State private var showSettings = false
    @State private var showFullAvatar = false
    /// Members past the first N are folded behind a "Show all" disclosure
    /// — on big groups the info screen was unscrollable with every member
    /// rendered eagerly.
    @State private var showAllMembers = false
    private static let memberPreviewLimit: Int = 5

    private var currentGroup: RCQGroup {
        groups.find(group.id) ?? group
    }

    private var amOwner: Bool {
        AuthService.shared.ownUIN == currentGroup.ownerUIN
    }

    /// Owner OR admin. Matches the backend gate on the rename + avatar
    /// branches of PATCH /groups/{id}.
    private var canEditChrome: Bool {
        guard let me = AuthService.shared.ownUIN else { return false }
        return currentGroup.isAdmin(me)
    }

    var body: some View {
        ZStack {
            Theme.Color.bgPrimary.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    descriptionBlock
                    notificationsSection
                    // Roster hidden by the owner → everyone but the
                    // owner sees just the count, not who's in it.
                    if currentGroup.membersHidden && !amOwner {
                        section(String(format: "group.section.members".localized, currentGroup.members.count)) {
                            Text("group.members.hidden".localized)
                                .font(.callout)
                                .foregroundColor(Theme.Color.textSecondary)
                        }
                    } else {
                        membersSection
                    }
                    if true {
                        section("group.section.manage".localized) {
                            Button {
                                showAddMember = true
                            } label: {
                                Label("group.cta.add_member".localized, systemImage: "person.badge.plus")
                                    .foregroundColor(Theme.Color.textPrimary)
                            }
                        }
                    }
                    Button(role: .destructive) {
                        confirmLeave = true
                    } label: {
                        Label(
                            amOwner ? "group.cta.delete".localized : "group.cta.leave".localized,
                            systemImage: "rectangle.portrait.and.arrow.right",
                        )
                            .frame(maxWidth: .infinity)
                            .foregroundColor(.white)
                            .padding(.vertical, 12)
                            .background(Theme.Color.statusBusy)
                            .cornerRadius(4)
                    }
                    if let error {
                        Text(error).font(.caption).foregroundColor(Theme.Color.statusBusy)
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("group.title".localized)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canEditChrome {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .foregroundColor(Theme.Color.textPrimary)
                    }
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            GroupSettingsSheet(groupID: currentGroup.id)
        }
        .fullScreenCover(isPresented: $showFullAvatar) {
            FullScreenAvatarView(
                mediaID: currentGroup.avatarMediaID,
                keyBase64: currentGroup.avatarMediaKey,
            )
        }
        .sheet(isPresented: $showAddMember) {
            AddGroupMemberView(group: currentGroup)
        }
        .sheet(item: Binding(
            get: { viewInfoForUIN.map { ViewInfoUIN(uin: $0) } },
            set: { viewInfoForUIN = $0?.uin }
        )) { wrap in
            NavigationStack {
                UserInfoView(uin: wrap.uin, isOwn: false)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("common.close".localized) { viewInfoForUIN = nil }
                        }
                    }
            }
        }
        .sheet(item: $actionMember) { m in
            MemberActionSheet(
                member: m,
                // Owner can kick any non-owner member (not themselves).
                canKick: amOwner && m.uin != currentGroup.ownerUIN && m.uin != (AuthService.shared.ownUIN ?? -1),
                onKick: {
                    let uin = m.uin
                    actionMember = nil
                    Task { try? await groups.removeMember(groupID: currentGroup.id, uin: uin) }
                },
                onOpenProfile: {
                    viewInfoForUIN = m.uin
                    actionMember = nil
                },
                onDismiss: { actionMember = nil },
            )
            .presentationDetents([.height(480)])
            .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            amOwner ? "group.confirm.delete".localized : "group.confirm.leave".localized,
            isPresented: $confirmLeave,
            titleVisibility: .visible,
        ) {
            Button(amOwner ? "group.cta.delete.short".localized : "group.cta.leave.short".localized, role: .destructive) {
                Task { await leaveOrDelete() }
            }
            Button("common.cancel".localized, role: .cancel) {}
        }
    }

    /// Mute group notifications toggle. Hits the same path as the
    /// long-press menu on a chat row, but surfaces it explicitly here
    /// because testers reported they couldn't find the long-press
    /// affordance (and the in-chat header was the wrong place for it).
    private var notificationsSection: some View {
        let thread: ThreadID = .group(id: currentGroup.id)
        let muted = sound.isMuted(thread: thread)
        return section("group.section.notifications".localized) {
            Button {
                sound.toggleMute(thread: thread)
            } label: {
                HStack {
                    Image(systemName: muted ? "bell.slash.fill" : "bell.fill")
                        .foregroundColor(muted ? Theme.Color.statusBusy : Theme.Color.accent)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text((muted ? "group.notifications.unmute" : "group.notifications.mute").localized)
                            .foregroundColor(Theme.Color.textPrimary)
                        Text((muted ? "group.notifications.muted.hint" : "group.notifications.unmuted.hint").localized)
                            .font(.caption)
                            .foregroundColor(Theme.Color.textSecondary)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)
        }
    }

    /// Members section: collapses past `memberPreviewLimit` so a 200+
    /// member group doesn't make the info screen unscrollable. Hidden
    /// roster path doesn't reach here.
    private var membersSection: some View {
        // Owner first, then admins, then everyone else. Swift's sort isn't
        // stable, so tiebreak on the original index to keep server order
        // within a rank.
        func rank(_ r: String) -> Int { r == "owner" ? 0 : (r == "admin" ? 1 : 2) }
        let ordered = currentGroup.members.enumerated().sorted { a, b in
            let ra = rank(a.element.role), rb = rank(b.element.role)
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map { $0.element }
        let visible: [RCQGroupMember] = {
            if showAllMembers || ordered.count <= Self.memberPreviewLimit {
                return ordered
            }
            return Array(ordered.prefix(Self.memberPreviewLimit))
        }()
        let hidden = max(0, currentGroup.members.count - visible.count)
        return section(String(format: "group.section.members".localized, currentGroup.members.count)) {
            ForEach(visible) { m in
                memberRow(m)
            }
            if hidden > 0 && !showAllMembers {
                Button {
                    withAnimation { showAllMembers = true }
                } label: {
                    HStack {
                        Image(systemName: "ellipsis.circle")
                            .foregroundColor(Theme.Color.accent)
                            .frame(width: 22)
                        Text(String(format: "group.members.show_more".localized, hidden))
                            .foregroundColor(Theme.Color.accent)
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Read-only group description — shown to every member when the
    /// owner/admin has set one. Editing now lives in GroupSettingsSheet.
    @ViewBuilder
    private var descriptionBlock: some View {
        if let desc = currentGroup.description, !desc.isEmpty {
            section("group.section.description".localized) {
                Text(desc)
                    .font(.callout)
                    .foregroundColor(Theme.Color.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            // Avatar + name are read-only here; editing moved into
            // GroupSettingsSheet (the gear button).
            GroupAvatarView(
                mediaID: currentGroup.avatarMediaID,
                keyBase64: currentGroup.avatarMediaKey,
                size: 56,
                glyphSize: 26,
            )
            .contentShape(Circle())
            .onTapGesture {
                if currentGroup.avatarMediaID != nil {
                    showFullAvatar = true
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(currentGroup.name)
                    .font(.title3.bold())
                    .foregroundColor(Theme.Color.textPrimary)
                Text(String(
                    format: "group.created".localized,
                    DateFormatter.localizedString(
                        from: currentGroup.createdAt,
                        dateStyle: .medium,
                        timeStyle: .none
                    )
                ))
                    .font(.caption2).foregroundColor(Theme.Color.textSecondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
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


    private func memberRow(_ m: RCQGroupMember) -> some View {
        let isMe = m.uin == AuthService.shared.ownUIN
        return Button {
            if !isMe { actionMember = m }
        } label: {
            HStack(spacing: 8) {
                StatusIcon(status: m.status, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(m.nickname).font(Theme.Font.nickname).foregroundColor(Theme.Color.textPrimary)
                        if m.uin == currentGroup.ownerUIN {
                            Image(systemName: "crown.fill")
                                .font(.system(size: 10))
                                .foregroundColor(Theme.Color.textSecondary)
                        }
                    }
                    Text(verbatim: "#\(m.uin)").font(Theme.Font.monoSmall).foregroundColor(Theme.Color.textMono)
                }
                Spacer()
                if m.role != "member" && m.uin != currentGroup.ownerUIN {
                    Text(localizedRole(m.role)).font(.caption2)
                        .foregroundColor(Theme.Color.accent)
                }
                if !isMe {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundColor(Theme.Color.textSecondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !isMe && amOwner && m.uin != currentGroup.ownerUIN {
                Button("group.member.remove".localized, role: .destructive) {
                    Task { try? await groups.removeMember(groupID: currentGroup.id, uin: m.uin) }
                }
            }
        }
    }

    private func localizedRole(_ raw: String) -> String {
        switch raw.lowercased() {
        case "owner": return "group.role.owner".localized
        case "admin": return "group.role.admin".localized
        default:      return raw.capitalized
        }
    }

    private func leaveOrDelete() async {
        do {
            if amOwner { try await groups.delete(currentGroup.id) }
            else { try await groups.leave(currentGroup.id) }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct ViewInfoUIN: Identifiable, Hashable { let uin: Int; var id: Int { uin } }

// MARK: - Member action sheet

private struct MemberActionSheet: View {
    let member: RCQGroupMember
    var canKick: Bool = false
    var onKick: () -> Void = {}
    let onOpenProfile: () -> Void
    let onDismiss: () -> Void

    @StateObject private var contacts = ContactService.shared
    @State private var profile: UserProfile?
    @State private var loading = true
    @State private var loadError: String?
    @State private var addRequestSent = false
    @State private var addError: String?
    @State private var confirmKick = false

    private var isAlreadyContact: Bool {
        contacts.contacts.contains(where: { $0.uin == member.uin })
    }

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 8)
            HStack(spacing: 12) {
                StatusIcon(status: member.status, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(member.nickname)
                        .font(.title3.bold())
                        .foregroundColor(Theme.Color.textPrimary)
                    Text(verbatim: "#\(member.uin)")
                        .font(Theme.Font.monoSmall)
                        .foregroundColor(Theme.Color.textMono)
                }
                Spacer()
            }
            .padding(.horizontal, 20)

            VStack(spacing: 10) {
                if loading {
                    pillLoading
                }
                if !isAlreadyContact {
                    Button {
                        Task {
                            do {
                                try await contacts.sendAddRequest(to: member.uin)
                                addRequestSent = true
                            } catch {
                                addError = error.localizedDescription
                            }
                        }
                    } label: {
                        actionPill(
                            icon: addRequestSent ? "checkmark.circle.fill" : "person.crop.circle.badge.plus",
                            text: addRequestSent
                                ? "group.member.action.add.sent".localized
                                : "group.member.action.add".localized,
                            tint: addRequestSent ? Theme.Color.textSecondary : Theme.Color.accent,
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(addRequestSent)
                }
                Button(action: onOpenProfile) {
                    actionPill(
                        icon: "person.crop.circle",
                        text: "group.member.action.profile".localized,
                        tint: Theme.Color.textPrimary,
                        background: Theme.Color.bgSecondary,
                    )
                }
                .buttonStyle(.plain)
                if let addError {
                    Text(addError)
                        .font(.caption2)
                        .foregroundColor(Theme.Color.statusBusy)
                }
                if let loadError {
                    Text(loadError)
                        .font(.caption2)
                        .foregroundColor(Theme.Color.statusBusy)
                }
            }
            .padding(.horizontal, 20)

            Divider().background(Theme.Color.divider)
                .padding(.horizontal, 20)
                .padding(.top, 4)
            VStack(spacing: 0) {
                UserSafetyActions(
                    targetUIN: member.uin,
                    targetNickname: member.nickname,
                    context: "group",
                    style: .rows,
                )
            }

            // Owner-only: kick this member out of the group.
            if canKick {
                Button(role: .destructive) {
                    confirmKick = true
                } label: {
                    actionPill(
                        icon: "person.crop.circle.badge.xmark",
                        text: "group.member.remove".localized,
                        tint: Theme.Color.statusBusy,
                        background: Theme.Color.bgSecondary,
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
            }

            Spacer(minLength: 8)
        }
        .background(Theme.Color.bgPrimary.ignoresSafeArea())
        .confirmationDialog(
            String(format: "group.member.remove.confirm".localized, member.nickname),
            isPresented: $confirmKick,
            titleVisibility: .visible,
        ) {
            Button("group.member.remove".localized, role: .destructive) { onKick() }
            Button("common.cancel".localized, role: .cancel) {}
        }
        .task {
            await loadProfile()
        }
    }

    private var pillLoading: some View {
        HStack(spacing: 8) {
            ProgressView().scaleEffect(0.8)
            Text("group.member.action.checking".localized)
                .font(.system(.callout, weight: .semibold))
                .foregroundColor(Theme.Color.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 50)
        .background(Theme.Color.bgSecondary.opacity(0.5))
        .cornerRadius(10)
    }

    private func actionPill(
        icon: String,
        text: String,
        tint: Color,
        background: Color? = nil,
    ) -> some View {
        let bg = background ?? tint
        let fg = background == nil ? Color.white : tint
        return HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
            Text(text)
                .font(.system(.callout, weight: .semibold))
        }
        .foregroundColor(fg)
        .frame(maxWidth: .infinity, minHeight: 50)
        .background(bg)
        .cornerRadius(10)
    }

    private func loadProfile() async {
        defer { loading = false }
        do {
            let p: UserProfile = try await APIClient.shared.request(
                "GET", "/users/\(member.uin)/info"
            )
            profile = p
        } catch {
            loadError = error.localizedDescription
        }
    }
}

// MARK: - Add member sheet

private struct AddGroupMemberView: View {
    let group: RCQGroup
    @Environment(\.dismiss) private var dismiss
    @StateObject private var contacts = ContactService.shared
    @State private var query = ""
    @State private var serverResults: [UserProfile] = []
    @State private var searching = false
    @State private var addError: String?

    private var localMatches: [Contact] {
        contacts.contacts.filter { c in !group.contains(c.uin) }
            .filter {
                query.isEmpty
                    || $0.nickname.localizedCaseInsensitiveContains(query)
                    || String($0.uin).contains(query)
            }
    }

    private var serverMatches: [UserProfile] {
        serverResults.filter { u in
            !group.contains(u.uin) &&
            !contacts.contacts.contains(where: { $0.uin == u.uin })
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                VStack(spacing: 0) {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundColor(Theme.Color.textSecondary)
                        TextField("group.add.placeholder".localized, text: $query)
                            .textInputAutocapitalization(.never)
                            .submitLabel(.search)
                            .onSubmit { Task { await runServerSearch() } }
                            .foregroundColor(Theme.Color.textPrimary)
                        if searching { ProgressView().scaleEffect(0.7) }
                    }
                    .padding(10).background(Theme.Color.bgSecondary).cornerRadius(4)
                    .padding(12)

                    if let addError {
                        Text(addError)
                            .font(.caption)
                            .foregroundColor(Theme.Color.statusBusy)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 8)
                    }

                    ScrollView {
                        LazyVStack(spacing: 0) {
                            if !localMatches.isEmpty {
                                sectionHeader("group.add.section.contacts".localized)
                                ForEach(localMatches) { c in
                                    contactRow(c)
                                    Divider().background(Theme.Color.divider)
                                }
                            }
                            if !serverMatches.isEmpty {
                                sectionHeader("group.add.section.others".localized)
                                ForEach(serverMatches, id: \.uin) { u in
                                    serverRow(u)
                                    Divider().background(Theme.Color.divider)
                                }
                            }
                            if !query.isEmpty && localMatches.isEmpty && serverMatches.isEmpty && !searching {
                                Text("group.no_matches".localized)
                                    .font(.caption)
                                    .foregroundColor(Theme.Color.textSecondary)
                                    .padding(20)
                            }
                        }
                    }
                }
            }
            .navigationTitle("group.add.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.close".localized) { dismiss() } }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(Theme.Color.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(Theme.Color.bgSecondary.opacity(0.7))
    }

    private func contactRow(_ c: Contact) -> some View {
        Button {
            Task { await add(uin: c.uin) }
        } label: {
            HStack(spacing: 10) {
                StatusIcon(status: c.status, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.nickname).font(Theme.Font.nickname).foregroundColor(Theme.Color.textPrimary)
                    Text(verbatim: "#\(c.uin)").font(Theme.Font.monoSmall).foregroundColor(Theme.Color.textMono)
                }
                Spacer()
                Image(systemName: "plus.circle").foregroundColor(Theme.Color.accent)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    private func serverRow(_ u: UserProfile) -> some View {
        Button {
            Task { await add(uin: u.uin) }
        } label: {
            HStack(spacing: 10) {
                StatusIcon(status: u.status, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(u.nickname).font(Theme.Font.nickname).foregroundColor(Theme.Color.textPrimary)
                    Text(verbatim: "#\(u.uin)").font(Theme.Font.monoSmall).foregroundColor(Theme.Color.textMono)
                }
                Spacer()
                Image(systemName: "plus.circle").foregroundColor(Theme.Color.accent)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    private func runServerSearch() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { serverResults = []; return }
        searching = true
        defer { searching = false }
        do {
            let rows: [UserProfile] = try await APIClient.shared.request(
                "GET", "/users/search", query: ["q": q, "limit": "20"]
            )
            self.serverResults = rows
        } catch {
            self.serverResults = []
        }
    }

    private func add(uin: Int) async {
        addError = nil
        do {
            try await GroupService.shared.addMember(groupID: group.id, uin: uin)
            dismiss()
        } catch APIError.http(403, _) {
            addError = "group.add.error.blocked".localized
        } catch {
            addError = String(format: "group.add.error.generic".localized, error.localizedDescription)
        }
    }
}


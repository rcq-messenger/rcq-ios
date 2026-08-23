import SwiftUI
import UIKit

struct GroupInfoView: View {
    let group: RCQGroup

    @Environment(\.dismiss) private var dismiss
    @StateObject private var groups = GroupService.shared
    @StateObject private var contacts = ContactService.shared
    @StateObject private var sound = SoundService.shared
    /// Set to push the 1:1 chat with a member straight from this screen (the
    /// "Message" action). Kept LOCAL — pushing within this NavigationStack
    /// avoids the path/deep-link conflict that flashed a blank screen.
    @State private var messagePeer: Contact?
    @State private var showAddMember = false
    @State private var confirmLeave = false
    @State private var error: String?
    @State private var viewInfoForUIN: Int?
    @State private var actionMember: RCQGroupMember?
    @State private var showSettings = false
    @State private var showFullAvatar = false
    @State private var linkCopied = false
    /// Members past the first N are folded behind a "Show all" disclosure
    /// — on big groups the info screen was unscrollable with every member
    /// rendered eagerly.
    @State private var showAllMembers = false
    @State private var memberSearch = ""
    /// Who we just handed the group to, once the island confirmed it.
    ///
    /// Kept apart from `currentGroup.ownerUIN` on purpose: this drives the
    /// follow-up offer ("you can walk out now"), which only makes sense to the
    /// person who just did it and not to everyone who opens this screen
    /// afterwards. It also has to OUTLIVE the sheet it was started from, since
    /// that sheet's whole moderator block is gated on being the owner and
    /// unmounts the instant the island answers. Handing the group over and then
    /// leaving is the migration this was built for, so the second half has to
    /// survive the first.
    @State private var handedTo: HandedOverOwner?
    /// The member the long-press menu proposed handing the group to, while the
    /// confirmation is up. The member sheet runs its own copy of the same
    /// confirmation: a dialog owned by this screen cannot be seen from behind a
    /// sheet that is covering it.
    @State private var transferTarget: RCQGroupMember?
    /// Height of the member sheet's content, reported back by the sheet so its
    /// detent fits what it actually draws. Seeded at the shortest variant so
    /// the first frame is never a full-screen sheet collapsing.
    @State private var memberSheetHeight: CGFloat = 320
    private static let memberPreviewLimit: Int = 5

    private var currentGroup: RCQGroup {
        groups.find(group.id) ?? group
    }

    private var amOwner: Bool {
        AuthService.shared.ownUIN == currentGroup.ownerUIN
    }

    /// My own row in the roster, when it has arrived. Nil on a group whose
    /// roster has not been fetched yet, and every capability check below falls
    /// back to "owner only", which is the safe direction.
    private var myMembership: RCQGroupMember? {
        guard let me = AuthService.shared.ownUIN else { return nil }
        return currentGroup.members.first(where: { $0.uin == me })
    }

    /// May I edit the group's name, description, picture and pin? SPEC 6.6
    /// `info`, which is exactly the island's own gate on those branches of
    /// PATCH /groups/{id} (`_member_can(g, me, "info")`).
    ///
    /// ⚠ This used to ask `isAdmin`, i.e. the ROLE column, and the island
    /// never writes "admin" into it. There is no admin role and no ownership
    /// transfer on this protocol, only per-member capability grants, so a
    /// moderator the owner had granted `info` was refused the gear button by
    /// their own client while the island would have accepted every one of
    /// their edits. The role is still honoured for an island that does set it.
    private var canEditChrome: Bool {
        guard let me = AuthService.shared.ownUIN else { return false }
        if currentGroup.ownerUIN == me { return true }
        guard let mine = myMembership else { return false }
        return mine.role == "admin" || mine.canManageInfo(ownerUIN: currentGroup.ownerUIN)
    }

    /// May I take people OUT? SPEC 6.6 `members`. Pulling people IN is not
    /// gated at all: any member may do it, in an open group and a closed one
    /// alike (`add_member` only checks membership), which is why the add row
    /// below is not behind this.
    private var canManageMembers: Bool {
        guard let me = AuthService.shared.ownUIN else { return false }
        if currentGroup.ownerUIN == me { return true }
        guard let mine = myMembership else { return false }
        return mine.role == "admin" || mine.permissions.contains("members")
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
                        section(membersSectionTitle) {
                            Text("group.members.hidden".localized)
                                .font(.callout)
                                .foregroundColor(Theme.Color.textSecondary)
                        }
                    } else {
                        membersSection
                    }
                    if true {
                        section("group.section.manage".localized) {
                            // Any member may pull someone IN, in a closed room
                            // as much as an open one: `add_member` checks
                            // membership and nothing else, and `is_closed` is
                            // purely a self-join gate. This used to hide the
                            // row in a closed group, which locked members out
                            // of an invite the island would have accepted.
                            // Taking someone OUT is the gated half (SPEC 6.6
                            // `members`), and that lives on the member row.
                            Button {
                                showAddMember = true
                            } label: {
                                Label("group.cta.add_member".localized, systemImage: "person.badge.plus")
                                    .foregroundColor(Theme.Color.textPrimary)
                            }
                            // Copy the group's invite link — paste it into a
                            // chat, or into a group's pinned announcement to
                            // surface it as a tappable group card.
                            Button {
                                UIPasteboard.general.string = {
                                    if let h = currentGroup.host {
                                        let rid = VisitedIslandsStore.shared.refByAlias(currentGroup.id)?.remoteId ?? currentGroup.id
                                        return GroupLinkParser.canonicalURL(forGroupID: rid, host: h).absoluteString
                                    }
                                    return GroupLinkParser.canonicalURL(forGroupID: currentGroup.id, host: Multihome.ownHost()).absoluteString
                                }()
                                linkCopied = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { linkCopied = false }
                            } label: {
                                Label(
                                    linkCopied ? "group.cta.link_copied".localized : "group.cta.copy_link".localized,
                                    systemImage: linkCopied ? "checkmark" : "link",
                                )
                                .foregroundColor(linkCopied ? Theme.Color.accent : Theme.Color.textPrimary)
                            }
                        }
                    }
                    handoverDoneSection
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
        .task {
            // The chat list is fetched without rosters, so this screen — the one
            // place that actually shows the members — asks for it on arrival.
            await groups.ensureRoster(group.id)
        }
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
            // The roster row as it stands NOW, not the snapshot the tap
            // captured: the caps the sheet draws change while it is open (that
            // is what its own toggles do), and the picture arrives with the
            // roster refresh that `ensureRoster` kicked off on this screen.
            let live = currentGroup.members.first(where: { $0.uin == m.uin }) ?? m
            MemberActionSheet(
                member: live,
                // Cross-island group: resolve the member from the group's island.
                groupHost: currentGroup.host,
                // SPEC 6.6 `members`: owner, or a member granted the cap.
                // Never the owner themselves (the island refuses with a 400)
                // and never me (that is Leave, not a kick).
                canKick: canManageMembers && m.uin != currentGroup.ownerUIN && m.uin != (AuthService.shared.ownUIN ?? -1),
                onKick: {
                    let uin = m.uin
                    actionMember = nil
                    Task { try? await groups.removeMember(groupID: currentGroup.id, uin: uin) }
                },
                // Granting caps is OWNER-ONLY on the island on purpose: a
                // moderator may use its caps but may not hand them on, so
                // there is no escalation chain.
                canModerate: amOwner && m.uin != currentGroup.ownerUIN && m.uin != (AuthService.shared.ownUIN ?? -1),
                onSetPermissions: { perms in
                    Task { try? await groups.setMemberPermissions(groupID: currentGroup.id, uin: m.uin, permissions: perms) }
                },
                // Handing the room over sits with the grants because that is
                // where a member is managed, but it is not one of them: a
                // capability is lent, ownership is given away.
                canTransferOwner: canTransferOwner(to: m),
                onTransferOwner: { await performTransfer(to: live) },
                onOpenProfile: {
                    viewInfoForUIN = m.uin
                    actionMember = nil
                },
                // Open the 1:1 chat by pushing it within THIS NavigationStack
                // (clean back stack: chat → back → group info). Avoids the
                // path/deep-link conflict that flashed a blank screen.
                onMessage: {
                    let uin = m.uin
                    actionMember = nil
                    messagePeer = contacts.contacts.first(where: { $0.uin == uin })
                },
                onDismiss: { actionMember = nil },
                height: $memberSheetHeight,
            )
            // Sized to what is actually in it. The fixed 540pt detent had to
            // fit the tallest variant (a moderator block plus a kick button),
            // so every shorter one (the common case, a member you can only
            // message) opened with a band of empty sheet above and below the
            // content ("много пустого места сверху и снизу").
            .presentationDetents([.height(memberSheetHeight)])
            .presentationDragIndicator(.visible)
        }
        .navigationDestination(
            isPresented: Binding(get: { messagePeer != nil }, set: { if !$0 { messagePeer = nil } })
        ) {
            if let messagePeer {
                ChatView(target: .peer(messagePeer))
            }
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
        // Irreversible from this side, so it is named and spelled out before it
        // is sent: who gets the room, and what the caller is left holding.
        .confirmationDialog(
            "group.transfer.title".localized,
            isPresented: Binding(
                get: { transferTarget != nil },
                set: { if !$0 { transferTarget = nil } }
            ),
            titleVisibility: .visible,
            presenting: transferTarget,
        ) { target in
            Button("group.transfer.cta".localized, role: .destructive) {
                Task {
                    if let message = await performTransfer(to: target) { self.error = message }
                }
            }
            Button("common.cancel".localized, role: .cancel) {}
        } message: { target in
            Text("group.transfer.confirm".localized(target.nickname))
        }
    }

    /// The second half of a handover, offered right where it leads: directly
    /// above the leave button, which by now says "leave" and no longer "delete
    /// group" because the island has already answered and `amOwner` is false.
    ///
    /// Deliberately NOT inside the member sheet the handover was started from.
    /// That sheet's moderator block is gated on ownership, and on a group with
    /// `membersHidden` the entire roster is gated on it too, so both are gone
    /// by the time there is anything to offer.
    @ViewBuilder
    private var handoverDoneSection: some View {
        if let handedTo {
            section("group.transfer.done.title".localized) {
                Text("group.transfer.done".localized(handedTo.name))
                    .font(.callout)
                    .foregroundColor(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button {
                        self.handedTo = nil
                    } label: {
                        Text("group.transfer.stay".localized)
                            .font(.system(.callout, weight: .semibold))
                            .foregroundColor(Theme.Color.textPrimary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(Theme.Color.bgPrimary)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    Button(role: .destructive) {
                        Task { await leaveNow() }
                    } label: {
                        Text("group.cta.leave.short".localized)
                            .font(.system(.callout, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(Theme.Color.statusBusy)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Per-group notification mode: All / Mentions only / None. A busy group
    /// (e.g. a 1000+ member beta) is the main source of push noise; "None"
    /// is the server-backed mute (silent everywhere), "Mentions only" stays
    /// quiet for ordinary messages but still surfaces an @mention in-app.
    private var notificationsSection: some View {
        let thread: ThreadID = .group(id: currentGroup.id)
        let mode = sound.notifyMode(thread: thread)
        return section("group.section.notifications".localized) {
            VStack(spacing: 0) {
                notifyModeRow(.all, current: mode, thread: thread,
                              icon: "bell.fill", title: "group.notify.all", hint: "group.notify.all.hint")
                Divider()
                notifyModeRow(.mentions, current: mode, thread: thread,
                              icon: "at", title: "group.notify.mentions", hint: "group.notify.mentions.hint")
                Divider()
                notifyModeRow(.none, current: mode, thread: thread,
                              icon: "bell.slash.fill", title: "group.notify.none", hint: "group.notify.none.hint")
            }
        }
    }

    private func notifyModeRow(
        _ rowMode: SoundService.NotifyMode, current: SoundService.NotifyMode,
        thread: ThreadID, icon: String, title: String, hint: String
    ) -> some View {
        Button {
            sound.setNotifyMode(rowMode, thread: thread)
        } label: {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(rowMode == .none ? Theme.Color.statusBusy : Theme.Color.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title.localized)
                        .foregroundColor(Theme.Color.textPrimary)
                    Text(hint.localized)
                        .font(.caption)
                        .foregroundColor(Theme.Color.textSecondary)
                }
                Spacer()
                if current == rowMode {
                    Image(systemName: "checkmark")
                        .foregroundColor(Theme.Color.accent)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    /// "MEMBERS (12.5K)". Compact rather than the full integer (founder item
    /// 27), because the section title is a header and nine digits in it push
    /// the word out of the line on a narrow phone. The shortening rules are
    /// `Int.compactCount`, which mirrors `web-chat/src/lib/format-count.ts`
    /// exactly so the same room never reads "12,480" in a browser and "12.5K"
    /// here. Below a thousand it is still the exact number.
    private var membersSectionTitle: String {
        String(format: "group.section.members.compact".localized, currentGroup.memberCount.compactCount)
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
        let q = memberSearch.trimmingCharacters(in: .whitespaces).lowercased()
        let searching = !q.isEmpty
        let filtered = searching
            ? ordered.filter { $0.nickname.lowercased().contains(q) || "\($0.uin)".contains(q) }
            : ordered
        // While searching, show every match; otherwise fold past the preview limit.
        let visible: [RCQGroupMember] = {
            if searching || showAllMembers || filtered.count <= Self.memberPreviewLimit {
                return filtered
            }
            return Array(filtered.prefix(Self.memberPreviewLimit))
        }()
        let hidden = searching ? 0 : max(0, ordered.count - visible.count)
        let canCollapse = showAllMembers && !searching && ordered.count > Self.memberPreviewLimit
        let bigGroup = currentGroup.members.count > Self.memberPreviewLimit
        return section(membersSectionTitle) {
            // Search field — only worth showing on a group big enough to scroll.
            if bigGroup {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundColor(Theme.Color.textSecondary).font(.system(size: 13))
                    TextField("group.members.search".localized, text: $memberSearch)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.callout)
                    if !memberSearch.isEmpty {
                        Button { memberSearch = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundColor(Theme.Color.textSecondary).font(.system(size: 14))
                        }.buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
            // Collapse control lives at the TOP of the list (right under the
            // search) so you never have to scroll to the bottom to fold it.
            if canCollapse {
                Button {
                    withAnimation { showAllMembers = false }
                } label: {
                    HStack {
                        Image(systemName: "chevron.up.circle").foregroundColor(Theme.Color.accent).frame(width: 22)
                        Text("group.members.collapse".localized).foregroundColor(Theme.Color.accent)
                        Spacer()
                    }.padding(.vertical, 6)
                }.buttonStyle(.plain)
            }
            ForEach(visible) { m in
                memberRow(m)
            }
            if searching && filtered.isEmpty {
                Text("group.members.no_matches".localized)
                    .font(.callout).foregroundColor(Theme.Color.textSecondary)
                    .padding(.vertical, 6)
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
                host: currentGroup.host,
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
                PersonAvatarView(
                    mediaID: m.avatarMediaID, keyBase64: m.avatarMediaKey,
                    status: m.status, size: 28
                )
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
                if let tag = roleTag(m) {
                    Text(tag).font(.caption2)
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
        .contextMenu { memberMenu(m, isMe: isMe) }
    }

    /// Long-press on a member. It used to offer one thing, "remove from
    /// group", which is why the founder read the app as having no admin
    /// functions at all. The grants live here now as well: one item hands
    /// over every capability at once (the common case, "сделать админом"),
    /// and the three checkmarks below it are the individual caps of SPEC 6.6
    /// for an owner who wants to give out less than all of them.
    @ViewBuilder
    private func memberMenu(_ m: RCQGroupMember, isMe: Bool) -> some View {
        let isOwnerRow = m.uin == currentGroup.ownerUIN
        if !isMe && !isOwnerRow {
            if amOwner {
                let caps = Set(m.permissions)
                if caps.count < GroupService.allPermissions.count {
                    Button {
                        setPermissions(m, GroupService.allPermissions)
                    } label: {
                        Label("group.member.promote".localized, systemImage: "star.circle")
                    }
                }
                if !caps.isEmpty {
                    Button {
                        setPermissions(m, [])
                    } label: {
                        Label("group.member.demote".localized, systemImage: "star.slash")
                    }
                }
                Divider()
                ForEach(GroupService.allPermissions, id: \.self) { cap in
                    Toggle(isOn: Binding(
                        get: { m.permissions.contains(cap) },
                        set: { on in
                            var next = Set(m.permissions)
                            if on { next.insert(cap) } else { next.remove(cap) }
                            setPermissions(m, Array(next))
                        }
                    )) {
                        Text(Self.permissionLabel(cap))
                    }
                }
            }
            if canTransferOwner(to: m) {
                Divider()
                // Not a capability, which is exactly why it is separated from
                // them by a rule: the three above are things the owner lends
                // out, this is the owner seat itself.
                Button(role: .destructive) {
                    error = nil
                    transferTarget = m
                } label: {
                    Label("group.transfer.title".localized, systemImage: "crown")
                }
            }
            if canManageMembers {
                Divider()
                Button("group.member.remove".localized, role: .destructive) {
                    Task { try? await groups.removeMember(groupID: currentGroup.id, uin: m.uin) }
                }
            }
        }
    }

    /// May I hand this room to this person? Owner-only like the grants, plus
    /// own-island only: see `GroupService.transferOwner`.
    private func canTransferOwner(to m: RCQGroupMember) -> Bool {
        amOwner && currentGroup.host == nil
            && m.uin != currentGroup.ownerUIN
            && m.uin != (AuthService.shared.ownUIN ?? -1)
    }

    /// The one door to the endpoint from this screen, so both places a member
    /// is managed (the sheet and the long-press menu) confirm the same way and
    /// land on the same follow-up offer. Returns nil when the island accepted
    /// it, or the sentence to show when it refused.
    ///
    /// The island answers with the whole group and `GroupService` upserts it,
    /// so `amOwner` and everything gated on it flip on the line below rather
    /// than on the next poll: the gear button, the kick buttons, the grants,
    /// and "delete group" turning back into "leave group".
    @discardableResult
    private func performTransfer(to m: RCQGroupMember) async -> String? {
        do {
            try await groups.transferOwner(groupID: currentGroup.id, toUIN: m.uin)
            actionMember = nil
            handedTo = HandedOverOwner(uin: m.uin, name: m.nickname)
            return nil
        } catch {
            return GroupService.transferFailureMessage(error)
        }
    }

    private func setPermissions(_ m: RCQGroupMember, _ permissions: [String]) {
        Task {
            try? await groups.setMemberPermissions(
                groupID: currentGroup.id, uin: m.uin, permissions: permissions
            )
        }
    }

    static func permissionLabel(_ cap: String) -> String {
        switch cap {
        case "delete":  return "group.perm.delete".localized
        case "members": return "group.perm.members".localized
        case "info":    return "group.perm.info".localized
        default:        return cap
        }
    }

    /// What to print beside a member's name. The owner already has the crown,
    /// so this is only about moderators, and a moderator is made of granted
    /// CAPS, not of a role: the island never writes "admin" into the role
    /// column, so reading the role alone (as this row used to) meant every
    /// moderator the owner had appointed still read as a plain member.
    private func roleTag(_ m: RCQGroupMember) -> String? {
        if m.uin == currentGroup.ownerUIN { return nil }
        if m.role == "admin" { return "group.role.admin".localized }
        let caps = Set(m.permissions).intersection(GroupService.allPermissions)
        if caps.isEmpty { return nil }
        return caps.count == GroupService.allPermissions.count
            ? "group.role.admin".localized
            : "group.role.moderator".localized
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

    /// Walk out. ALWAYS a removal of myself, never the owner's delete, and that
    /// is the whole reason it is its own function: the handover card's button
    /// sits where the same person's "delete the group for everyone" sat seconds
    /// earlier, and routing it through `leaveOrDelete` would put the room one
    /// stale `amOwner` read away from being destroyed instead of left.
    private func leaveNow() async {
        do {
            try await groups.leave(currentGroup.id)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct ViewInfoUIN: Identifiable, Hashable { let uin: Int; var id: Int { uin } }

/// The member the group was just handed to, for the follow-up offer.
private struct HandedOverOwner: Identifiable, Hashable {
    let uin: Int
    let name: String
    var id: Int { uin }
}

/// How tall the member sheet's content actually is, reported up so the sheet's
/// detent can be that and not a guess.
private struct MemberSheetHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Member action sheet

private struct MemberActionSheet: View {
    let member: RCQGroupMember
    /// Host of a CROSS-ISLAND group — the member lives on that island, not ours,
    /// so profile-resolution + add must go there. nil for a same-island group.
    var groupHost: String? = nil
    var canKick: Bool = false
    var onKick: () -> Void = {}
    /// Owner viewing a non-owner, non-self member: may grant/revoke caps.
    var canModerate: Bool = false
    var onSetPermissions: ([String]) -> Void = { _ in }
    /// Owner viewing a non-owner, non-self member of an OWN-ISLAND group: may
    /// hand the whole room to them.
    var canTransferOwner: Bool = false
    /// Runs the handover. Returns nil once the island has accepted it (the
    /// presenter closes this sheet and takes over from there), or the sentence
    /// to print under the button when it refused.
    var onTransferOwner: (() async -> String?)? = nil
    let onOpenProfile: () -> Void
    /// Open the 1:1 chat with this member. Only offered when they're already a
    /// contact (you can't message someone you haven't added).
    var onMessage: (() -> Void)? = nil
    let onDismiss: () -> Void
    /// Reported back to the presenter so the sheet's detent is the height of
    /// what it draws. See the `.presentationDetents` call site.
    @Binding var height: CGFloat

    @StateObject private var contacts = ContactService.shared
    @State private var profile: UserProfile?
    @State private var loading = true
    @State private var loadError: String?
    @State private var addRequestSent = false
    @State private var addError: String?
    @State private var confirmKick = false
    @State private var perms: Set<String> = []
    @State private var permsSeeded = false
    @State private var confirmTransfer = false
    @State private var transferring = false
    @State private var transferError: String?

    /// May this sheet offer the card at all?
    ///
    /// ⚠ A member list is the FIRST surface `settings.privacy.profile_card`
    /// names, and it was the one surface that never asked: the reactions sheet
    /// and the album header both call this gate, the roster did not. Only the
    /// card pill is gated, not the sheet: messaging, kicking and the safety
    /// actions have nothing to do with who may read a card.
    ///
    /// The roster row carries the island's per-viewer verdict, so this is the
    /// one surface that needs no lookup. ⚠ Still fails OPEN on a nil, which is
    /// what an island older than the field sends, and what the membership
    /// fan-out frames carry: one payload goes to many recipients, so there is
    /// no single viewer to answer for. The next roster read repaints it.
    private var canOpenCard: Bool {
        ProfileCardPrivacy.canOpenCard(
            uin: member.uin,
            openable: member.profileOpenable,
            myUIN: AuthService.shared.ownUIN,
            isContact: contacts.contacts.contains { $0.uin == member.uin }
        )
    }

    @ViewBuilder
    private func permChip(_ label: String, cap: String) -> some View {
        let on = perms.contains(cap)
        Button {
            if on { perms.remove(cap) } else { perms.insert(cap) }
            onSetPermissions(Array(perms))
        } label: {
            Text(label)
                .font(.caption)
                .foregroundColor(on ? Theme.Color.bgPrimary : Theme.Color.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(on ? Theme.Color.accent : Theme.Color.bgSecondary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var isAlreadyContact: Bool {
        contacts.contacts.contains(where: { $0.uin == member.uin })
    }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.Color.bgPrimary.ignoresSafeArea()
            content
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: MemberSheetHeightKey.self, value: geo.size.height)
                    }
                )
        }
        .onPreferenceChange(MemberSheetHeightKey.self) { measured in
            guard measured > 0 else { return }
            // A floor so a half-laid-out first frame never collapses the sheet
            // to nothing, and a ceiling so the tallest variant still leaves the
            // screen behind it visible.
            let wanted = min(max(measured, 260), UIScreen.main.bounds.height * 0.92)
            if abs(wanted - height) > 1 { height = wanted }
        }
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
        .onAppear {
            if !permsSeeded { perms = Set(member.permissions); permsSeeded = true }
        }
        // The roster refreshes under this sheet (the parent hands it the live
        // row), so a grant made from the long-press menu, or one the owner
        // made on another device, lands on the chips instead of leaving them
        // showing whatever was true when the sheet opened.
        .onChange(of: member.permissions) { latest in perms = Set(latest) }
    }

    private var content: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                // Their picture, not just their flower. The roster carries
                // `avatar_media_id` + the blob's key for every member, gated by
                // MEMBERSHIP and not by the contact list: sharing a group is
                // the relationship. With no picture this draws the same plain
                // flower the row used to draw.
                PersonAvatarView(
                    mediaID: member.avatarMediaID,
                    keyBase64: member.avatarMediaKey,
                    status: member.status,
                    host: groupHost,
                    size: 44,
                )
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
                // Primary action (Message for a contact, Add for a non-contact)
                // sits on the SAME row as Open Profile — side by side, not stacked.
                HStack(spacing: 10) {
                    if isAlreadyContact, let onMessage {
                        Button(action: onMessage) {
                            actionPill(
                                icon: "bubble.left.fill",
                                text: "group.member.action.message".localized,
                                tint: Color.white,
                                background: Theme.Color.accent,
                            )
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            Task {
                                if let groupHost {
                                    // Cross-island member: add directly (works even
                                    // though they're on another server).
                                    if await contacts.addCrossIslandContact(uin: member.uin, host: groupHost) {
                                        addRequestSent = true
                                    } else {
                                        addError = "common.error".localized
                                    }
                                } else {
                                    do {
                                        try await contacts.sendAddRequest(to: member.uin)
                                        addRequestSent = true
                                    } catch {
                                        addError = error.localizedDescription
                                    }
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
                    if canOpenCard {
                        Button(action: onOpenProfile) {
                            actionPill(
                                icon: "person.crop.circle",
                                text: "group.member.action.profile".localized,
                                tint: Theme.Color.textPrimary,
                                background: Theme.Color.bgSecondary,
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
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

            // Owner-only: grant/revoke this member's moderator caps. The owner
            // decides which rights each moderator gets. Toggles are optimistic;
            // the parent persists via POST /permissions.
            //
            // ⚠ "Full rights" is every capability the protocol has, and it is
            // still not ownership: `owner_uin` is what every owner-only lever
            // reads, and no cap moves it. Handing the group over before moving
            // to a new number is what an owner used to reach for this control
            // to do, which is why the seat itself is offered right below it.
            if canModerate {
                Divider().background(Theme.Color.divider)
                    .padding(.horizontal, 20)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("group.perm.title".localized)
                            .font(.caption)
                            .foregroundColor(Theme.Color.textSecondary)
                        Spacer()
                        Button {
                            let next: Set<String> = hasAllPerms ? [] : Set(GroupService.allPermissions)
                            perms = next
                            onSetPermissions(Array(next))
                        } label: {
                            Text((hasAllPerms ? "group.perm.revoke_all" : "group.perm.grant_all").localized)
                                .font(.caption.weight(.semibold))
                                .foregroundColor(Theme.Color.accent)
                        }
                        .buttonStyle(.plain)
                    }
                    HStack(spacing: 8) {
                        ForEach(GroupService.allPermissions, id: \.self) { cap in
                            permChip(GroupInfoView.permissionLabel(cap), cap: cap)
                        }
                    }
                    Text("group.perm.hint".localized)
                        .font(.caption2)
                        .foregroundColor(Theme.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
            }

            // The last and largest thing an owner can give this person, so it
            // sits at the bottom of what they may be given rather than as a
            // third button crowding the row above.
            if canTransferOwner, let onTransferOwner {
                Divider().background(Theme.Color.divider)
                    .padding(.horizontal, 20)
                VStack(alignment: .leading, spacing: 8) {
                    Button(role: .destructive) {
                        transferError = nil
                        confirmTransfer = true
                    } label: {
                        actionPill(
                            icon: transferring ? "hourglass" : "crown",
                            text: (transferring ? "group.transfer.working" : "group.transfer.title").localized,
                            tint: Theme.Color.statusBusy,
                            background: Theme.Color.bgSecondary,
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(transferring)
                    if let transferError {
                        Text(transferError)
                            .font(.caption2)
                            .foregroundColor(Theme.Color.statusBusy)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 20)
                // Attached HERE and not beside the kick dialog on the root: two
                // confirmation dialogs on one view is one presentation slot
                // fought over by two callers.
                .confirmationDialog(
                    "group.transfer.title".localized,
                    isPresented: $confirmTransfer,
                    titleVisibility: .visible,
                ) {
                    Button("group.transfer.cta".localized, role: .destructive) {
                        Task {
                            transferring = true
                            transferError = await onTransferOwner()
                            transferring = false
                        }
                    }
                    Button("common.cancel".localized, role: .cancel) {}
                } message: {
                    Text("group.transfer.confirm".localized(member.nickname))
                }
            }

            // Owner, or a member granted the `members` capability.
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
        }
        // Clears the drag indicator at the top and gives the last control room
        // to breathe at the bottom. What used to be here was a pair of
        // `Spacer`s inside a sheet pinned to a fixed 540pt detent, which is
        // where the empty bands above and below the content came from.
        .padding(.top, 20)
        .padding(.bottom, 24)
    }

    private var hasAllPerms: Bool {
        perms.intersection(GroupService.allPermissions).count == GroupService.allPermissions.count
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
        // Cross-island member: their profile lives on the GROUP's island and our
        // own /users/{uin}/info would 404 ("no such user" — the founder's report).
        // The sheet already shows their name + status from the roster, so skip the
        // own-island load entirely rather than surface a misleading error.
        if groupHost != nil { return }
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
            // §5c: a contact on another island can't be added by their foreign
            // uin (the group's island has no such account). Route them through
            // the owner-initiated cross-island add (resolve/register + invite).
            if c.host != nil {
                Task { await addCrossIsland(c) }
            } else {
                Task { await add(uin: c.uin) }
            }
        } label: {
            HStack(spacing: 10) {
                StatusIcon(status: c.status, size: 24, crossIsland: c.host != nil)
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.nickname).font(Theme.Font.nickname).foregroundColor(Theme.Color.textPrimary)
                    if let h = c.host {
                        Text(verbatim: "#\(c.uin) · \(h)").font(Theme.Font.monoSmall).foregroundColor(Theme.Color.textMono)
                    } else {
                        Text(verbatim: "#\(c.uin)").font(Theme.Font.monoSmall).foregroundColor(Theme.Color.textMono)
                    }
                }
                Spacer()
                Image(systemName: "plus.circle").foregroundColor(Theme.Color.accent)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    private func addCrossIsland(_ c: Contact) async {
        addError = nil
        do {
            try await GroupService.shared.addCrossIslandMember(group: group, contact: c)
            dismiss()
        } catch {
            addError = String(format: "group.add.error.generic".localized, error.localizedDescription)
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
        } catch APIError.http(403, let body) {
            // The add-member endpoint returns 403 for THREE different reasons:
            // the owner blocked the user, OR the invitee's own group-invite
            // policy ("contacts"/"nobody") refuses the invite. Only the first is
            // a real block — don't mislabel a policy refusal as "the creator
            // blocked this user" (which sent the user hunting for a phantom block).
            let detail = (body ?? "").lowercased()
            if detail.contains("blocked this user") {
                addError = "group.add.error.blocked".localized
            } else if detail.contains("group invites") {
                addError = "group.add.error.invite_policy".localized
            } else {
                addError = "group.add.error.forbidden".localized
            }
        } catch {
            addError = String(format: "group.add.error.generic".localized, error.localizedDescription)
        }
    }
}


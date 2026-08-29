import SwiftUI

/// Presented when a recipient taps a shared-group card. Pulls the
/// preview (name + member count + entry price + closed flag), then
/// offers Join (free), Pay+Join (priced group), or a disabled
/// "Closed by owner" affordance. On success the user navigates
/// straight into the group chat.
struct GroupJoinSheet: View {
    let groupID: Int
    /// §5c: the group's host island when the invite carried one. nil/own =
    /// a normal local group. When foreign, `groupID` is the SERVER-side id on
    /// that island (the alias is allocated on join).
    var host: String? = nil
    let onJoined: (RCQGroup) -> Void
    /// Tapping the owner row opens their profile preview. The
    /// caller hands back a UIN to surface via the global preview
    /// path (same as a tap on any user nickname elsewhere).
    var onOpenOwner: ((Int) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @StateObject private var groups = GroupService.shared

    @State private var preview: GroupService.GroupPreview?
    @State private var loading: Bool = true
    @State private var error: String?
    @State private var joining: Bool = false

    /// Foreign = an island that isn't ours (§5c).
    private var foreignHost: String? {
        guard let host, !Multihome.isOwnHost(host) else { return nil }
        return host
    }

    /// True when the caller is already in this group. For a foreign group the
    /// local roster holds it under its ALIAS id; match by (host, remoteId)
    /// without allocating a new alias.
    private var alreadyMember: Bool {
        if let h = foreignHost {
            return groups.groups.contains { g in
                g.host == h && VisitedIslandsStore.shared.refByAlias(g.id)?.remoteId == groupID
            }
        }
        return groups.groups.contains(where: { $0.id == groupID })
    }

    private var cachedForeignGroup: RCQGroup? {
        guard let h = foreignHost else { return nil }
        return groups.groups.first { g in
            g.host == h && VisitedIslandsStore.shared.refByAlias(g.id)?.remoteId == groupID
        }
    }

    /// Local cache snapshot so a room I am ALREADY in renders its real
    /// avatar: the preview serves the avatar pair to members only (stage 6),
    /// and my own roster has it anyway. Strangers get the generic glyph.
    private var cachedGroup: RCQGroup? {
        groups.groups.first(where: { $0.id == groupID })
    }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    loadingView
                } else if let preview {
                    content(preview)
                } else if foreignHost != nil {
                    // Foreign island we haven't visited (no preview by design —
                    // seeing a link must not touch it). Minimal join surface.
                    islandView
                } else {
                    errorView
                }
            }
            .background(Theme.Color.bgPrimary.ignoresSafeArea())
            .navigationTitle("group_join.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".localized) { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView().tint(Theme.Color.accent)
            Text("group_join.loading".localized)
                .font(.caption)
                .foregroundColor(Theme.Color.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var islandView: some View {
        VStack(spacing: 18) {
            Image(systemName: "person.3.fill")
                .font(.system(size: 44))
                .foregroundColor(.white)
                .frame(width: 96, height: 96)
                .background(Circle().fill(Theme.Color.accent))
                .padding(.top, 24)
            VStack(spacing: 6) {
                Text("group_join.island".localized)
                    .font(.title3.weight(.semibold))
                    .foregroundColor(Theme.Color.textPrimary)
                Text(foreignHost ?? "")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundColor(Theme.Color.textSecondary)
            }
            Text(String(format: "group_join.island_hint".localized, foreignHost ?? ""))
                .font(.callout)
                .foregroundColor(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            if let error {
                Text(error).font(.caption).foregroundColor(.red.opacity(0.85)).padding(.horizontal, 32)
            }
            Button { Task { await join() } } label: {
                Group {
                    if joining { ProgressView().tint(.white) }
                    else { Text("group_join.button".localized).font(.body.weight(.semibold)).foregroundColor(.white) }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 14)
            }
            .background(Theme.Color.accent)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .disabled(joining)
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
    }

    private var errorView: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundColor(.red.opacity(0.7))
            Text(error ?? "group_join.error.generic".localized)
                .font(.callout)
                .foregroundColor(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func content(_ p: GroupService.GroupPreview) -> some View {
        VStack(spacing: 18) {
            // The island serves the avatar pair to MEMBERS only now (the key
            // is the blob's cleartext AES key and /media has no auth, so the
            // pair is the picture - stage 6). A link to a room I am in still
            // shows its picture via my own roster; a stranger's link shows
            // the generic glyph, which is the point.
            ZStack(alignment: .bottomTrailing) {
                GroupAvatarView(
                    mediaID: p.avatarMediaID ?? (cachedForeignGroup ?? cachedGroup)?.avatarMediaID,
                    keyBase64: p.avatarMediaKey ?? (cachedForeignGroup ?? cachedGroup)?.avatarMediaKey,
                    size: 67,
                )
                .frame(width: 67, height: 67)
                if p.isClosed {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .padding(5)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                }
            }
            .frame(width: 77, height: 77)
            .padding(.top, 24)
            VStack(spacing: 6) {
                Text(p.name)
                    .font(.title3.weight(.semibold))
                    .foregroundColor(Theme.Color.textPrimary)
                Text(String(format: "group_share.members".localized, p.memberCount))
                    .font(.caption)
                    .foregroundColor(Theme.Color.textSecondary)
            }
            if let desc = p.description, !desc.isEmpty {
                Text(desc)
                    .font(.callout)
                    .foregroundColor(Theme.Color.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 32)
            }
            ownerRow(p)
            if p.isClosed && !alreadyMember {
                Text("group_join.closed_hint".localized)
                    .font(.callout)
                    .foregroundColor(Theme.Color.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Spacer()
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red.opacity(0.85))
                    .padding(.horizontal, 32)
            }
            primaryButton(p)
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
        }
    }

    @ViewBuilder
    private func ownerRow(_ p: GroupService.GroupPreview) -> some View {
        // Owner identity row. Live status + pet overlay come from
        // the cached group member list when we have it; otherwise
        // fall back to a plain nickname. Tappable so the user can
        // peek at the owner before committing to join.
        let ownerMember = cachedGroup?.members.first(where: { $0.uin == p.ownerUIN })
        Button {
            onOpenOwner?(p.ownerUIN)
        } label: {
            HStack(spacing: 10) {
                StatusIcon(status: ownerMember?.status ?? .offline, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("group_join.owner_label".localized)
                        .font(.caption2)
                        .foregroundColor(Theme.Color.textSecondary)
                    Text(p.ownerNickname ?? "#\(p.ownerUIN)")
                        .font(.callout.weight(.semibold))
                        .foregroundColor(Theme.Color.textPrimary)
                }
                Spacer()
                if onOpenOwner != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(Theme.Color.textSecondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.Color.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 24)
        }
        .buttonStyle(.plain)
        .disabled(onOpenOwner == nil)
    }

    @ViewBuilder
    private func primaryButton(_ p: GroupService.GroupPreview) -> some View {
        let label: String = {
            if alreadyMember { return "group_join.open_button".localized }
            if p.isClosed { return "group_join.closed_button".localized }
            return "group_join.button".localized
        }()
        let bg: Color = {
            if alreadyMember { return Theme.Color.accent }
            if p.isClosed { return Theme.Color.divider }
            return Theme.Color.accent
        }()
        Button {
            if alreadyMember {
                // Foreign groups live in the roster under an ALIAS id, so the
                // bare-id `cachedGroup` lookup misses them — use the (host,
                // remoteId) cache so "Open" actually navigates a cross-island
                // group the caller already belongs to (was a silent no-op).
                if let g = foreignHost != nil ? cachedForeignGroup : cachedGroup {
                    onJoined(g)
                }
                dismiss()
            } else {
                Task { await join() }
            }
        } label: {
            if joining {
                ProgressView().tint(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            } else {
                Text(label)
                    .font(.body.weight(.semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
        }
        .background(bg)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .disabled((p.isClosed && !alreadyMember) || joining)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        if let h = foreignHost {
            // Only a VISITED island can be previewed (privacy). An unvisited
            // one falls through to `islandView` — no network, no error.
            preview = await CrossIslandGroups.previewForeign(host: h, remoteId: groupID)
            error = nil
            return
        }
        if let snap = await GroupService.shared.fetchPreview(groupID: groupID) {
            preview = snap
            error = nil
        } else {
            error = "group_join.error.generic".localized
        }
    }

    private func join() async {
        joining = true
        defer { joining = false }
        error = nil
        if let h = foreignHost {
            // §5c: guest-register on the group's island (explicit user action),
            // join there, hand back the alias-stamped group.
            let nick = AuthService.shared.nickname.isEmpty ? "user-\(AuthService.shared.ownUIN ?? 0)" : AuthService.shared.nickname
            if let g = await CrossIslandGroups.joinForeign(host: h, remoteId: groupID, nickname: nick) {
                onJoined(g)
                dismiss()
            } else {
                error = "group_join.error.generic".localized
            }
            return
        }
        let result = await GroupService.shared.join(groupID: groupID)
        switch result {
        case .success(let g):
            onJoined(g)
            dismiss()
        case .blocked:
            error = "group_join.error.blocked".localized
        case .closed:
            error = "group_join.closed_hint".localized
        case .other(let msg):
            error = msg
        }
    }
}

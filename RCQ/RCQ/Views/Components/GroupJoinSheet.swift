import SwiftUI

/// Presented when a recipient taps a shared-group card. Pulls the
/// preview (name + member count + entry price + closed flag), then
/// offers Join (free), Pay+Join (priced group), or a disabled
/// "Closed by owner" affordance. On success the user navigates
/// straight into the group chat.
struct GroupJoinSheet: View {
    let groupID: Int
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

    /// True when the caller is already in this group. Skips the
    /// join button entirely and offers "Open" instead — the
    /// previous Join UI on a self-owned group was confusing.
    private var alreadyMember: Bool {
        groups.groups.contains(where: { $0.id == groupID })
    }

    /// Local cache snapshot so we can render the real avatar (the
    /// preview endpoint doesn't include avatar fields — privacy).
    /// Falls back to a generic glyph when the caller isn't a member.
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
            // Avatar from the preview payload (server now ships
            // `avatar_media_id` + `avatar_media_key` to non-members
            // for share-card rendering). `GroupAvatarView` falls
            // back to the generic glyph for groups without an
            // uploaded avatar.
            ZStack(alignment: .bottomTrailing) {
                GroupAvatarView(
                    mediaID: p.avatarMediaID,
                    keyBase64: p.avatarMediaKey,
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
                if let g = cachedGroup {
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

import SwiftUI

/// Lets the user pick one of their groups to share into the current
/// chat. Result is a `https://rcq.app/g/<id>` URL the chat composer
/// sends as plain text; the receiving client's `GroupLinkParser`
/// upgrades the bubble into a card-style preview.
struct ShareGroupPickerSheet: View {
    let onPicked: (RCQGroup) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var groups = GroupService.shared

    var body: some View {
        NavigationStack {
            Group {
                if groups.groups.isEmpty {
                    empty
                } else {
                    list
                }
            }
            .background(Theme.Color.bgPrimary.ignoresSafeArea())
            .navigationTitle("share_group.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel".localized) { dismiss() }
                }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.3")
                .font(.system(size: 36))
                .foregroundColor(Theme.Color.textSecondary)
            Text("share_group.empty".localized)
                .font(.callout)
                .foregroundColor(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(groups.groups) { group in
                    Button {
                        onPicked(group)
                        dismiss()
                    } label: {
                        row(group)
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading, 72)
                }
            }
        }
    }

    private func row(_ g: RCQGroup) -> some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                // Real avatar via the shared `GroupAvatarView` —
                // matches the rendering used in ContactListView,
                // ForwardPickerSheet, GroupInfoView, etc. Falls back
                // to the generic person.3 glyph for legacy groups
                // without an uploaded image.
                GroupAvatarView(
                    mediaID: g.avatarMediaID,
                    keyBase64: g.avatarMediaKey,
                    size: 44,
                )
                .frame(width: 44, height: 44)
                if g.isClosed {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .padding(3)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                }
            }
            .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(g.name)
                    .font(.callout.weight(.semibold))
                    .foregroundColor(Theme.Color.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(String(format: "group_share.members".localized, g.members.count))
                        .font(.caption2)
                        .foregroundColor(Theme.Color.textSecondary)
                    if let price = g.entryPriceTokens, price > 0 {
                        Text("·")
                            .foregroundColor(Theme.Color.textSecondary)
                        HStack(spacing: 3) {
                            ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                                .frame(width: 10, height: 10)
                            Text("\(price)")
                                .font(.caption2.monospacedDigit())
                                .foregroundColor(Theme.Color.textPrimary)
                        }
                    }
                    if g.isClosed {
                        Text("·")
                            .foregroundColor(Theme.Color.textSecondary)
                        Text("share_group.closed_tag".localized)
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(.red.opacity(0.7))
                    }
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundColor(Theme.Color.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

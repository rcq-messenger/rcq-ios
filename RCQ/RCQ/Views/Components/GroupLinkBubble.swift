import SwiftUI

/// Chat bubble rendering for a shared group invite link. Mirrors
/// `UinLinkBubble` shape — `https://rcq.app/g/<id>` (or
/// `rcq://group/<id>`) inside a chat body parses into a card with
/// the group name + member count + entry price + closed indicator.
/// Tap → `AppState.pendingJoinGroupID = id`, which the root view
/// observes to present `GroupJoinSheet`.
struct GroupLinkBubble: View {
    let groupID: Int
    let rawURL: URL

    @EnvironmentObject private var appState: AppState
    @State private var preview: GroupService.GroupPreview?
    @State private var loadFailed: Bool = false

    private static let cardWidth: CGFloat = 260
    private static let cardHeight: CGFloat = 96

    var body: some View {
        Group {
            if let preview {
                card(preview)
            } else if loadFailed {
                fallback
            } else {
                placeholder
            }
        }
        .task(id: groupID) { await load() }
    }

    @ViewBuilder
    private func card(_ p: GroupService.GroupPreview) -> some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                // Real avatar when uploaded — `GroupAvatarView` falls
                // back to the generic glyph for groups without one,
                // so this single branch covers both cases.
                GroupAvatarView(
                    mediaID: p.avatarMediaID,
                    keyBase64: p.avatarMediaKey,
                    size: 56,
                )
                .frame(width: 56, height: 56)
                if p.isClosed {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(3)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                }
            }
            .frame(width: 72, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(p.name)
                    .font(.callout.weight(.semibold))
                    .foregroundColor(Theme.Color.textPrimary)
                    .lineLimit(1)
                Text(String(format: "group_share.members".localized, p.memberCount))
                    .font(.caption2)
                    .foregroundColor(Theme.Color.textSecondary)
                if let price = p.entryPriceTokens, price > 0 {
                    HStack(spacing: 4) {
                        ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                            .frame(width: 12, height: 12)
                        Text("\(price)")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(Theme.Color.textPrimary)
                    }
                } else if p.isClosed {
                    Text("group_share.closed_badge".localized)
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.red.opacity(0.7))
                } else {
                    Text("group_share.free".localized)
                        .font(.caption2)
                        .foregroundColor(Theme.Color.accent)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: Self.cardWidth, height: Self.cardHeight)
        .background(Theme.Color.bgSecondary.opacity(0.7))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.Color.divider, lineWidth: 0.5),
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture {
            appState.pendingJoinGroupID = groupID
        }
    }

    private var placeholder: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Theme.Color.bgSecondary)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Theme.Color.bgSecondary)
                    .frame(width: 100, height: 12)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Theme.Color.bgSecondary)
                    .frame(width: 60, height: 10)
                ProgressView().scaleEffect(0.6)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: Self.cardWidth, height: Self.cardHeight)
        .background(Theme.Color.bgSecondary.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var fallback: some View {
        Button {
            appState.pendingJoinGroupID = groupID
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "person.3.fill")
                    .foregroundColor(Theme.Color.accent)
                Text(rawURL.absoluteString)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(Theme.Color.accent)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(8)
            .background(Theme.Color.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        if preview != nil { return }
        if let snap = await GroupService.shared.fetchPreview(groupID: groupID) {
            preview = snap
        } else {
            loadFailed = true
        }
    }
}

/// Parse a chat body for a single group-share URL.
enum GroupLinkParser {
    static func parse(_ body: String) -> (groupID: Int, url: URL)? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let url = URL(string: trimmed) else { return nil }
        if url.scheme == "rcq" && url.host == "group" {
            if let last = url.pathComponents.last, let gid = Int(last), gid > 0 {
                return (gid, url)
            }
        }
        if (url.scheme == "https" || url.scheme == "http"),
           url.host == "rcq.app",
           url.pathComponents.count >= 3,
           url.pathComponents[1] == "g",
           let gid = Int(url.pathComponents[2]),
           gid > 0 {
            return (gid, url)
        }
        return nil
    }

    /// Canonical URL shape for a fresh share — keeps the `https://`
    /// path in sync with the deep-link parser above. iOS clients
    /// produce this when the user picks a group from the share sheet.
    static func canonicalURL(forGroupID gid: Int) -> URL {
        URL(string: "https://rcq.app/g/\(gid)")!
    }
}

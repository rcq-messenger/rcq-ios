import SwiftUI

/// Top-of-screen overlay that renders whatever `MessageBannerService`
/// currently has live. Mounted in a dedicated UIWindow via
/// `BannerWindowController` so it floats above fullScreenCovers and
/// sheets in the main scene.
struct MessageBannerHost: View {
    @StateObject private var service = MessageBannerService.shared

    var body: some View {
        VStack {
            if let banner = service.current {
                BannerCard(banner: banner) {
                    routeTap(banner: banner)
                } onDismiss: {
                    service.dismiss(banner.id)
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
                .id(banner.id)
            }
            Spacer(minLength: 0)
        }
        .allowsHitTesting(service.current != nil)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: service.current?.id)
    }

    private func routeTap(banner: MessageBannerService.Banner) {
        // Apply the navigation intent BEFORE dismissing — dismissing
        // tears BannerCard out of the hierarchy, which can cancel any
        // state mutation that runs after. Also reach AppState.shared
        // directly: this view lives in a separate UIWindow, so the
        // env-object chain is independent of the main scene and using
        // the singleton dodges any environment-lookup ambiguity.
        let app = AppState.shared
        switch banner.target {
        case .thread(let t):
            switch t {
            case .peer(let uin):
                app.pendingOpenChatUIN = uin
            case .group(let id):
                app.pendingOpenGroupID = id
            }
        case .auction:
            app.pendingOpenUinAuction = true
        case .reputation:
            // No routing — informational banner. Tap = dismiss.
            break
        }
        service.dismiss(banner.id)
    }
}

private struct BannerCard: View {
    let banner: MessageBannerService.Banner
    let onTap: () -> Void
    let onDismiss: () -> Void

    @State private var dragOffset: CGFloat = 0

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            avatar
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundColor(Theme.Color.textPrimary)
                    .lineLimit(1)
                // EmoticonText so emoticon-only bodies render the
                // glyph instead of `:shortcode:`.
                EmoticonText(
                    text: banner.body,
                    font: .caption,
                    color: Theme.Color.textSecondary,
                    emoticonSize: 15
                )
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.Color.bgSecondary)
                .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Theme.Color.divider, lineWidth: 0.5)
        )
        .offset(y: dragOffset)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        // `simultaneousGesture` so the drag doesn't shadow the tap —
        // a plain `.gesture(...)` after `.onTapGesture` makes SwiftUI
        // run the gestures exclusively and the tap loses, which is
        // why "tapping the in-app banner did nothing".
        .simultaneousGesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    // Only react to upward drags — pulling down would
                    // collide with the navigation-bar pan-to-back gesture
                    // on the chat list.
                    dragOffset = min(0, value.translation.height)
                }
                .onEnded { value in
                    if value.translation.height < -28 {
                        onDismiss()
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            dragOffset = 0
                        }
                    }
                }
        )
    }

    @ViewBuilder
    private var avatar: some View {
        switch banner.target {
        case .thread(.group(let id)):
            // Use the group's own avatar when available; falls back
            // to the generic person.3 glyph inside GroupAvatarView.
            let snapshot = GroupService.shared.find(id)
            GroupAvatarView(
                mediaID: snapshot?.avatarMediaID,
                keyBase64: snapshot?.avatarMediaKey,
                size: 32,
            )
        case .reputation:
            // Reputation banners use the rep.png asset, not an SF
            // Symbol — same icon as the profile counter + leaderboard.
            ItemAssetImage(bundleSubdir: "Items", filename: "rep", ext: "gif")
                .frame(width: 20, height: 20)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Theme.Color.accent.opacity(0.15)))
        default:
            Image(systemName: bubbleGlyph)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Theme.Color.accent))
        }
    }

    private var bubbleGlyph: String {
        switch banner.target {
        case .thread(let t):
            switch t {
            case .peer:  return "bubble.left.fill"
            case .group: return "person.3.fill"
            }
        case .auction:
            return "hammer.fill"
        case .reputation:
            return "star.fill"
        }
    }
}

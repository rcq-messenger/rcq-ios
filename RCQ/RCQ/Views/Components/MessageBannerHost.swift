import SwiftUI

/// Top-of-screen overlay that renders whatever `MessageBannerService`
/// currently has live. Mounted into RootView's ZStack so it floats
/// above the NavigationStack and any sheet that isn't fullScreenCover.
struct MessageBannerHost: View {
    @StateObject private var service = MessageBannerService.shared
    @EnvironmentObject private var appState: AppState

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
        service.dismiss(banner.id)
        switch banner.target {
        case .thread(let t):
            switch t {
            case .peer(let uin):
                appState.pendingOpenChatUIN = uin
            case .group(let id):
                appState.pendingOpenGroupID = id
            }
        case .auction:
            appState.pendingOpenUinAuction = true
        }
    }
}

private struct BannerCard: View {
    let banner: MessageBannerService.Banner
    let onTap: () -> Void
    let onDismiss: () -> Void

    @State private var dragOffset: CGFloat = 0

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: bubbleGlyph)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Theme.Color.accent))
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundColor(Theme.Color.textPrimary)
                    .lineLimit(1)
                Text(banner.body)
                    .font(.caption)
                    .foregroundColor(Theme.Color.textSecondary)
                    .lineLimit(2)
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
        .gesture(
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

    private var bubbleGlyph: String {
        switch banner.target {
        case .thread(let t):
            switch t {
            case .peer:  return "bubble.left.fill"
            case .group: return "person.3.fill"
            }
        case .auction:
            return "hammer.fill"
        }
    }
}

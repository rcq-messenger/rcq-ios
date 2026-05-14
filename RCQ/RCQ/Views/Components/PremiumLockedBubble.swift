import CryptoKit
import SwiftUI

/// Paywalled photo/video bubble; one view handles locked + unlocked so unlock can blur-dissolve.
struct PremiumLockedBubble: View {
    let message: Message
    let onUnlock: () -> Void
    var size: CGSize = CGSize(width: 240, height: 240)

    private static let lockedBlur: CGFloat = 28
    private static let dissolve: Double = 0.55

    @State private var thumbnailImage: UIImage?
    @State private var fullImage: UIImage?
    @State private var currentBlur: CGFloat
    @State private var overlayOpacity: Double

    init(message: Message, onUnlock: @escaping () -> Void, size: CGSize = CGSize(width: 240, height: 240)) {
        self.message = message
        self.onUnlock = onUnlock
        self.size = size
        // Resolve the locked state at init so already-unlocked sender bubbles never paint a blur frame.
        let unlocked = message.premiumUnlocked
        _currentBlur = State(initialValue: unlocked ? 0 : Self.lockedBlur)
        _overlayOpacity = State(initialValue: unlocked ? 0 : 1)
    }

    private var price: Int { message.premiumPriceTokens ?? 0 }
    private var isVideo: Bool { message.kind == .premiumVideo }
    private var isUnlocked: Bool { message.premiumUnlocked }

    var body: some View {
        ZStack {
            mainImage
                .frame(width: size.width, height: size.height)
                .clipped()
                .blur(radius: currentBlur)
            // Play badge so video is visually distinct from photo
            // even after unlock — without this both kinds collapse
            // to the same still-frame look.
            if isVideo, isUnlocked {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 38))
                    .foregroundColor(.white.opacity(0.9))
                    .shadow(color: .black.opacity(0.45), radius: 6)
            }
        }
        .frame(width: size.width, height: size.height)
        .cornerRadius(Theme.Metrics.bubbleRadius)
        .clipped()
        .overlay(alignment: .topTrailing) {
            // Keep recipient aware that this bubble was paid content
            // even after the unlock blur dissolves.
            if isUnlocked {
                Image(systemName: "dollarsign.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white, Color.black.opacity(0.55))
                    .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
                    .padding(8)
            }
        }
        .overlay(lockedOverlay.opacity(overlayOpacity).allowsHitTesting(overlayOpacity > 0.05))
        .contentShape(Rectangle())
        .onTapGesture {
            guard isUnlocked else { return }
            // Same viewer for premium photo and video — keeps close /
            // save icons and swipe-down dismiss consistent with the
            // rest of the app instead of forking into the old
            // FullscreenPhotoViewer.
            AlbumViewerPresenter.present(items: [message], initialIndex: 0)
        }
        .task(id: message.id) { decodeThumbnail() }
        .task(id: cacheKey) { await syncWithUnlockState() }
    }

    // Recomputes when unlock flips OR the mediaID gets the AES key spliced in by unlockPremium.
    private var cacheKey: String {
        "\(message.id.uuidString)|\(isUnlocked ? 1 : 0)|\(message.mediaID ?? "")"
    }

    @ViewBuilder
    private var mainImage: some View {
        if let img = fullImage ?? thumbnailImage {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
        } else {
            LinearGradient(
                colors: [Theme.Color.accent.opacity(0.45), Theme.Color.bubbleOther],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
    }

    @ViewBuilder
    private var lockedOverlay: some View {
        ZStack {
            Color.black.opacity(0.25)
            VStack(spacing: 12) {
                // Same `lock.fill` for both kinds — the previous
                // `lock.rectangle.stack.fill` looked like a "stack of
                // media" badge and read as if multiple items were
                // hidden, even though premium content is always one.
                Image(systemName: "lock.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
                Button(action: onUnlock) {
                    HStack(spacing: 6) {
                        Text("chat.premium.unlock_for".localized)
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundColor(.white)
                        ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                            .frame(width: 16, height: 16)
                        Text("\(price)")
                            .font(.system(.subheadline, weight: .bold).monospacedDigit())
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: size.width, height: size.height)
        .cornerRadius(Theme.Metrics.bubbleRadius)
        .clipped()
    }

    // MARK: - state pipeline

    private func decodeThumbnail() {
        guard thumbnailImage == nil,
              let b64 = message.thumbnailB64,
              !b64.isEmpty,
              let data = Data(base64Encoded: b64),
              let img = UIImage(data: data)
        else { return }
        thumbnailImage = img
    }

    // Wrapping state mutations in MainActor.run fragments the withAnimation transaction
    // across two runloop ticks, which makes the blur snap instead of dissolve.
    @MainActor
    private func syncWithUnlockState() async {
        if isUnlocked {
            if message.kind == .premiumPhoto, fullImage == nil {
                await loadFullImage()
            }
            withAnimation(.easeOut(duration: Self.dissolve)) {
                currentBlur = 0
                overlayOpacity = 0
            }
        } else {
            // Warm encrypted-blob cache so unlock decrypt is local-only.
            currentBlur = Self.lockedBlur
            overlayOpacity = 1
            if let raw = message.mediaID,
               let serverID = raw.components(separatedBy: "|").first,
               !serverID.isEmpty {
                await MediaService.shared.prefetchEncrypted(mediaID: serverID)
            }
        }
    }

    @MainActor
    private func loadFullImage() async {
        guard let raw = message.mediaID else { return }
        let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[1].isEmpty else { return }
        let img = await MediaService.shared.loadImage(
            mediaID: parts[0], keyBase64: parts[1]
        )
        self.fullImage = img
    }
}

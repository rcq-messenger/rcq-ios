import CryptoKit
import SwiftUI

/// Unified bubble for paywalled photo / video — handles BOTH the
/// locked and unlocked render in one view so the unlock transition
/// is a smooth blur dissolve in place rather than a hard swap to a
/// different component. Telegram-style: blur radius animates 28 → 0
/// while the lock + price overlay fades out, and the underlying
/// image swaps from the small thumbnail to the full decrypted photo
/// without changing dimensions.
///
/// Render layers (back to front):
///   1. Image — full decrypted photo if available, otherwise the
///      sender-supplied tiny thumbnail. Blurred per `currentBlur`.
///   2. Lock overlay — dark wash + lock glyph + "Unlock for N" pill.
///      Faded per `overlayOpacity`. `allowsHitTesting(false)` once
///      faded out so the unlocked photo's tap target works.
///   3. Tap surface for fullscreen on unlocked photos.
struct PremiumLockedBubble: View {
    let message: Message
    let onUnlock: () -> Void
    /// Frame the bubble paints into. Computed by the caller from the
    /// thumbnail's aspect ratio so the locked + unlocked states share
    /// dimensions to the pixel.
    var size: CGSize = CGSize(width: 240, height: 240)

    /// Heavy blur radius — the source thumbnail is downscaled to
    /// ~64px so this radius reduces it to a smear of dominant colors
    /// with no recognizable shapes. Animates to 0 on unlock.
    private static let lockedBlur: CGFloat = 28
    /// Smooth dissolve duration on unlock — long enough to read as
    /// "the gate is opening", short enough not to feel slow.
    private static let dissolve: Double = 0.55

    /// Decoded thumbnail (the small preview shipped inside the
    /// envelope). Always-on backdrop while the full photo loads.
    @State private var thumbnailImage: UIImage?
    /// Decrypted full-resolution photo, populated after the user
    /// pays + the AES key is unwrapped + the encrypted blob (often
    /// already in `MediaService.encryptedBlobCache` thanks to the
    /// pre-unlock prefetch) decrypts. Nil for the locked state and
    /// for premium VIDEO bubbles (videos play on tap, not inline).
    @State private var fullImage: UIImage?
    /// Animated blur radius. Initial value is `init`-driven from
    /// `message.premiumUnlocked` so a SENDER (whose bubble is born
    /// already-unlocked) never sees the blur frame at all — the
    /// previous fixed-init default fired a brief locked-then-dissolve
    /// flash on the sender's own bubble.
    @State private var currentBlur: CGFloat
    /// Lock overlay alpha — fades in lockstep with the blur. Same
    /// init-time initialization as `currentBlur` for the same reason.
    @State private var overlayOpacity: Double
    /// Drives the fullscreen photo viewer when the user taps an
    /// unlocked premium photo. Nil for the locked state.
    @State private var fullscreen: Bool = false

    init(message: Message, onUnlock: @escaping () -> Void, size: CGSize = CGSize(width: 240, height: 240)) {
        self.message = message
        self.onUnlock = onUnlock
        self.size = size
        // Bake the locked-vs-unlocked starting state into @State so
        // the very first render matches reality. Sender bubbles
        // (premiumUnlocked == true from creation) skip the blur
        // entirely; receiver bubbles start fully blurred and dissolve
        // via `syncWithUnlockState` once the unlock completes.
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
        }
        .frame(width: size.width, height: size.height)
        .cornerRadius(Theme.Metrics.bubbleRadius)
        .clipped()
        .overlay(lockedOverlay.opacity(overlayOpacity).allowsHitTesting(overlayOpacity > 0.05))
        .contentShape(Rectangle())
        .onTapGesture {
            // Fullscreen only when the photo is fully revealed —
            // taps on the locked bubble belong to the in-overlay
            // unlock pill (which sits in lockedOverlay, taking its
            // own tap target via the Button there).
            if isUnlocked, fullImage != nil {
                fullscreen = true
            }
        }
        .task(id: message.id) { decodeThumbnail() }
        .task(id: cacheKey) { await syncWithUnlockState() }
        .fullScreenCover(isPresented: $fullscreen) {
            if let img = fullImage {
                FullscreenPhotoViewer(image: img) { fullscreen = false }
            }
        }
    }

    /// Combined cache key that triggers the load/unlock pipeline whenever
    /// either the unlock flag or the message's mediaID changes — the
    /// latter is how `MessageStore.unlockPremium` patches the AES key
    /// into the row, so re-running the task on its change is what
    /// actually grabs the freshly-unwrapped key.
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
            // No preview shipped AND no full image yet — tinted
            // gradient so the bubble has presence even before the
            // thumbnail decode resolves.
            LinearGradient(
                colors: [Theme.Color.accent.opacity(0.45), Theme.Color.bubbleOther],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
    }

    /// Lock + price pill — the locked-state chrome that fades to 0
    /// on unlock. Sits in `.overlay`, matching the bubble's rounded
    /// corners via the parent's `cornerRadius`.
    @ViewBuilder
    private var lockedOverlay: some View {
        ZStack {
            // Dark wash so the white lock + pill stay readable
            // regardless of underlying photo color.
            Color.black.opacity(0.25)
            VStack(spacing: 12) {
                Image(systemName: isVideo ? "lock.rectangle.stack.fill" : "lock.fill")
                    // Smaller than the previous 34pt — reads as a
                    // status icon over the photo, not a giant slab.
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

    /// Single entry point for everything that reacts to the unlock
    /// flag. Called on first appear AND any time `cacheKey` changes
    /// (i.e. unlock flips OR the mediaID gets the AES key spliced in
    /// via `MessageStore.unlockPremium`).
    ///
    /// Runs on MainActor — `.task` for a View runs on the view's
    /// isolation context, which is MainActor for SwiftUI views.
    /// We deliberately do NOT wrap state mutations in `MainActor.run`:
    /// that hop fragments the `withAnimation` transaction across two
    /// runloop ticks, which is exactly how the buyer's blur ended up
    /// snapping to clear instead of dissolving.
    @MainActor
    private func syncWithUnlockState() async {
        if isUnlocked {
            // Unlocked path: load the full photo (videos play on tap;
            // we never decode the video file inline). Once the image
            // is in hand, animate blur + overlay out together.
            if message.kind == .premiumPhoto, fullImage == nil {
                await loadFullImage()
            }
            // Animate AFTER the image is on screen so the user sees
            // the dissolve over the actual photo, not a flash of
            // unblurred thumbnail. `withAnimation` runs synchronously
            // on the same MainActor context the State lives on, so
            // the transaction propagates cleanly.
            withAnimation(.easeOut(duration: Self.dissolve)) {
                currentBlur = 0
                overlayOpacity = 0
            }
        } else {
            // Locked path: keep blur + overlay at locked values + warm
            // the encrypted-blob cache so the eventual unlock decrypt
            // is a free local op (no new network round-trip).
            currentBlur = Self.lockedBlur
            overlayOpacity = 1
            if let raw = message.mediaID,
               let serverID = raw.components(separatedBy: "|").first,
               !serverID.isEmpty {
                await MediaService.shared.prefetchEncrypted(mediaID: serverID)
            }
        }
    }

    /// Pull the full photo via the regular `MediaService.loadImage`
    /// path. The encrypted-blob cache (warmed by `prefetchEncrypted`
    /// while locked) means the network is rarely touched here — the
    /// decrypt is essentially free, the dissolve sees the real photo
    /// almost immediately.
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

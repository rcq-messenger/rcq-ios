import SwiftUI

/// Photo message bubble. Loads encrypted bytes, decrypts via MediaService, tap → fullscreen viewer.
struct PhotoBubble: View {
    let message: Message
    var maxWidth: CGFloat = 240
    /// Pin frame to this size and `.scaledToFill` — used by premium flow so locked/unlocked render at matching dimensions.
    var forcedSize: CGSize? = nil
    /// Skip both the built-in tap-to-fullscreen and the fullScreenCover.
    /// Album tiles set this so their parent owns the tap (and routes
    /// it to the album-wide viewer with paging).
    var disableTap: Bool = false

    @State private var image: UIImage?
    /// Decrypted bytes — populated alongside `image` so we can detect
    /// `"GIF8"` magic and render via `AnimatedGIFView` while still
    /// using `image` as the first-frame fallback for the layout.
    @State private var gifData: Data?
    /// True only after a load with a real mediaID genuinely failed to
    /// decrypt. Kept distinct from "still loading" so the window
    /// between mediaID arriving (upload done) and the decrypt
    /// finishing does not flash the error triangle.
    @State private var loadFailed = false
    @State private var fullscreen = false
    @StateObject private var progress = MediaProgressStore.shared

    init(message: Message, maxWidth: CGFloat = 240, forcedSize: CGSize? = nil, disableTap: Bool = false) {
        self.message = message
        self.maxWidth = maxWidth
        self.forcedSize = forcedSize
        self.disableTap = disableTap
        // Warm-cache seed: if this photo is already decrypted+decoded, show it
        // on the FIRST frame — skips the `.task` actor hop, the nil->image
        // placeholder flash, and a redundant re-decode every time the cell
        // recycles into view while scrolling a media-heavy thread. Seed only
        // when BOTH image+data are cached so a GIF never sticks on a static
        // frame; otherwise fall through to the normal async load().
        if let raw = message.mediaID {
            let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
            if parts.count == 2,
               let img = MediaService.shared.cachedImage(mediaID: parts[0], keyBase64: parts[1]),
               let data = MediaService.shared.cachedData(mediaID: parts[0], keyBase64: parts[1]) {
                _image = State(initialValue: img)
                _gifData = State(initialValue: AnimatedGIFView.isGIF(data) ? data : nil)
            }
        }
    }

    private var didFailUpload: Bool {
        message.mediaID == nil && message.deliveryState == .failed
    }

    var body: some View {
        Group {
            if let image {
                let frameSize: CGSize = forcedSize ?? CGSize(width: maxWidth, height: maxWidth * 0.75)
                Group {
                    if let gifData, AnimatedGIFView.isGIF(gifData) {
                        // GIF path — animated frames from the
                        // decrypted bytes. UIImage layout is preserved
                        // so the bubble doesn't reflow when the GIF
                        // bundle is being decoded.
                        AnimatedGIFView(data: gifData, contentMode: .fill)
                    } else {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    }
                }
                .frame(width: frameSize.width, height: frameSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
                .modifier(TapToFullscreen(enabled: !disableTap, message: message))
            } else if didFailUpload {
                failedPlaceholder
            } else if isUploading {
                uploadingPlaceholder
            } else if loadFailed {
                placeholder(systemName: "exclamationmark.triangle")
            } else {
                placeholder(systemName: "photo")
            }
        }
        // Re-run on mediaID change so the placeholder flips to the real photo post-upload.
        .task(id: message.mediaID ?? "") { await load() }
    }

    private var isUploading: Bool {
        message.mediaID == nil && message.deliveryState == .sending
    }

    private var failedPlaceholder: some View {
        ZStack {
            Theme.Color.bgSecondary
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(Theme.Color.statusBusy)
                Text("media.bubble.failed".localized)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.Color.textSecondary)
            }
        }
        .frame(width: maxWidth, height: maxWidth * 0.75)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func placeholder(systemName: String) -> some View {
        ZStack {
            Theme.Color.bgSecondary
            Image(systemName: systemName)
                .foregroundColor(Theme.Color.textSecondary)
                .font(.system(size: 26))
        }
        .frame(width: forcedSize?.width ?? maxWidth,
               height: forcedSize?.height ?? maxWidth * 0.75)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var uploadingPlaceholder: some View {
        ZStack {
            Theme.Color.bgSecondary
            if let p = progress.value(for: message.id) {
                ZStack {
                    Circle()
                        .stroke(Theme.Color.textSecondary.opacity(0.25), lineWidth: 3)
                        .frame(width: 40, height: 40)
                    Circle()
                        .trim(from: 0, to: max(0.02, CGFloat(p)))
                        .stroke(Theme.Color.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 40, height: 40)
                        .animation(.easeOut(duration: 0.2), value: p)
                    Text("\(Int(p * 100))%")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(Theme.Color.textSecondary)
                }
            } else {
                ProgressView()
                    .tint(Theme.Color.textSecondary)
            }
        }
        .frame(width: maxWidth, height: maxWidth * 0.75)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func load() async {
        // The warm-cache seed (init) already populated `image` — don't re-hop
        // the actor or re-decode.
        if image != nil { return }
        loadFailed = false
        guard let raw = message.mediaID else { return }
        let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { loadFailed = true; return }
        if let (img, data) = await MediaService.shared.loadImageWithData(
            mediaID: parts[0], keyBase64: parts[1],
        ) {
            self.image = img
            self.gifData = AnimatedGIFView.isGIF(data) ? data : nil
        } else {
            loadFailed = true
        }
    }

}

struct FullscreenPhotoViewer: View {
    let image: UIImage
    var onClose: () -> Void

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var saveState: PhotoSaveDelegate.State = .idle

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .gesture(
                    MagnificationGesture()
                        .onChanged { v in scale = max(1, lastScale * v) }
                        .onEnded { _ in lastScale = scale }
                )
                .gesture(
                    TapGesture(count: 2).onEnded {
                        scale = scale > 1 ? 1 : 2.5
                        lastScale = scale
                    }
                )
            VStack {
                HStack {
                    Button {
                        savePhoto()
                    } label: {
                        Image(systemName: saveStateIcon)
                            .font(.system(size: 24))
                            .foregroundColor(.white.opacity(0.85))
                            .padding()
                    }
                    .disabled(saveState == .saving || saveState == .done)
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.white.opacity(0.85))
                            .padding()
                    }
                }
                Spacer()
            }
        }
        .onTapGesture(perform: onClose)
    }

    private var saveStateIcon: String {
        switch saveState {
        case .idle:    return "square.and.arrow.down"
        case .saving:  return "ellipsis.circle"
        case .done:    return "checkmark.circle.fill"
        case .failed:  return "exclamationmark.triangle.fill"
        }
    }

    private func savePhoto() {
        saveState = .saving
        let delegate = PhotoSaveDelegate { result in
            saveState = result
            if result == .done {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    await MainActor.run { saveState = .idle }
                }
            }
        }
        // passRetained — UIKit selector callback fires after closure scope otherwise.
        UIImageWriteToSavedPhotosAlbum(image, delegate, #selector(PhotoSaveDelegate.didFinish(image:error:contextInfo:)), Unmanaged.passRetained(delegate).toOpaque())
    }
}

final class PhotoSaveDelegate: NSObject {
    enum State { case idle, saving, done, failed }
    let onComplete: (State) -> Void
    init(onComplete: @escaping (State) -> Void) { self.onComplete = onComplete }

    @objc func didFinish(image: UIImage, error: Error?, contextInfo: UnsafeMutableRawPointer?) {
        let state: State = (error == nil) ? .done : .failed
        DispatchQueue.main.async { self.onComplete(state) }
        if let contextInfo {
            Unmanaged<PhotoSaveDelegate>.fromOpaque(contextInfo).release()
        }
    }
}

/// Conditionally routes a tap into `AlbumViewerPresenter` (single-
/// item album) so standalone photos use the same viewer as albums —
/// same swipe-down dismiss, same close + save chrome. When
/// `enabled = false`, taps fall through to the parent (album tiles
/// own the routing themselves).
private struct TapToFullscreen: ViewModifier {
    let enabled: Bool
    let message: Message

    func body(content: Content) -> some View {
        if enabled {
            content.onTapGesture {
                AlbumViewerPresenter.present(items: [message], initialIndex: 0)
            }
        } else {
            content
        }
    }
}

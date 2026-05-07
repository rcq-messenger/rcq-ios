import SwiftUI

/// Photo message bubble. Loads encrypted bytes from the server, decrypts via
/// MediaService, displays the result. Tap to open the fullscreen viewer.
struct PhotoBubble: View {
    let message: Message
    var maxWidth: CGFloat = 240
    /// When set, the bubble locks its frame to exactly this size and
    /// fills it with `.scaledToFill` (cropping if needed). Used by the
    /// premium-content flow so the locked + unlocked states render at
    /// matching dimensions — without this, the locked blur sat at one
    /// size and the unlocked photo popped to its natural aspect, which
    /// looked like an ugly resize on unlock.
    var forcedSize: CGSize? = nil

    @State private var image: UIImage?
    @State private var loading = true
    @State private var fullscreen = false
    /// Live upload progress for outbound bubbles. Subscribes to
    /// `MediaProgressStore` so the placeholder can show a real
    /// percentage instead of a generic spinner. Source: KVO on the
    /// underlying `URLSessionUploadTask.progress.fractionCompleted`.
    @StateObject private var progress = MediaProgressStore.shared

    /// Outbound photo whose upload finished but failed (size cap,
    /// network drop, server error). Distinct from `loading == false`
    /// failure (which means a successful upload but a download
    /// failure on a third-party device): for failed uploads we have
    /// no `mediaID` and `deliveryState == .failed`.
    private var didFailUpload: Bool {
        message.mediaID == nil && message.deliveryState == .failed
    }

    var body: some View {
        Group {
            if let image {
                if let size = forcedSize {
                    // Premium-flow rendering: pinned dimensions so the
                    // unlocked photo fills the same frame the locked
                    // blur was sitting in.
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size.width, height: size.height)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .onTapGesture { fullscreen = true }
                } else {
                    // FIXED 4:3 frame — same shape `VideoBubble` uses,
                    // and the same shape the placeholder + uploading
                    // states render at. Identical width/height across
                    // sender and receiver from frame zero (no envelope
                    // round-trip needed for aspect data) AND no
                    // bubble-resize when the image data lands later
                    // (which used to push every later message down by
                    // ΔH and yank the chat scroll position with it —
                    // the "chat jumps when entering a thread with
                    // media" symptom). Tap → fullscreen viewer renders
                    // the full uncropped photo via `scaledToFit`.
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: maxWidth, height: maxWidth * 0.75)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                        .onTapGesture { fullscreen = true }
                }
            } else if didFailUpload {
                failedPlaceholder
            } else if isUploading {
                // Upload still in flight on our own outbound
                // bubble — show a spinner instead of the
                // failure-triangle so the user can see "this is
                // sending, not broken". Random chat surfaced this
                // most visibly: media bubble appears immediately
                // with `mediaID == nil`, and only flips real once
                // the upload completes a beat later.
                uploadingPlaceholder
            } else if loading {
                placeholder(systemName: "photo")
            } else {
                placeholder(systemName: "exclamationmark.triangle")
            }
        }
        // Re-run when the message's mediaID changes (e.g. local row gets patched
        // post-upload), so the placeholder flips to the real photo immediately.
        .task(id: message.mediaID ?? "") { await load() }
        .fullScreenCover(isPresented: $fullscreen) {
            if let image { FullscreenPhotoViewer(image: image) { fullscreen = false } }
        }
    }

    /// True while we *expect* a `mediaID` to land shortly. Outbound
    /// bubbles are appended optimistically with `mediaID = nil`
    /// and `deliveryState = .sending`; the failure-triangle only
    /// makes sense once delivery itself failed.
    private var isUploading: Bool {
        message.mediaID == nil && message.deliveryState == .sending
    }

    /// Visible "this didn't go through" marker — replaces the
    /// generic photo icon for outbound bubbles whose upload threw
    /// (size cap, network, server). Without it the user sees a
    /// stale placeholder + the regular row's red bang somewhere off
    /// to the side and can't tell what went wrong.
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
        // Honour `forcedSize` for the placeholder too — premium flow
        // shouldn't see a 240×180 spinner sitting over what was a
        // 240×320 blur. Match the eventual photo's frame from frame 0.
        .frame(width: forcedSize?.width ?? maxWidth,
               height: forcedSize?.height ?? maxWidth * 0.75)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var uploadingPlaceholder: some View {
        // Determinate ring whenever we have a real fraction from
        // the upload-progress store; falls back to the system
        // spinner if the store doesn't have an entry yet (very
        // first frame, before `MediaProgressStore.begin` runs)
        // OR for legacy code paths that didn't wire the
        // progress callback.
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
        guard let raw = message.mediaID else { loading = false; return }
        let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { loading = false; return }
        let img = await MediaService.shared.loadImage(mediaID: parts[0], keyBase64: parts[1])
        self.image = img
        self.loading = false
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
        // Retain the delegate via the associated object pattern — UIKit's selector
        // callback fires after the closure goes out of scope otherwise.
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

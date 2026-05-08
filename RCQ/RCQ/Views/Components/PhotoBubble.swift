import SwiftUI

/// Photo message bubble. Loads encrypted bytes, decrypts via MediaService, tap → fullscreen viewer.
struct PhotoBubble: View {
    let message: Message
    var maxWidth: CGFloat = 240
    /// Pin frame to this size and `.scaledToFill` — used by premium flow so locked/unlocked render at matching dimensions.
    var forcedSize: CGSize? = nil

    @State private var image: UIImage?
    @State private var loading = true
    @State private var fullscreen = false
    @StateObject private var progress = MediaProgressStore.shared

    private var didFailUpload: Bool {
        message.mediaID == nil && message.deliveryState == .failed
    }

    var body: some View {
        Group {
            if let image {
                if let size = forcedSize {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size.width, height: size.height)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .onTapGesture { fullscreen = true }
                } else {
                    // Fixed 4:3 frame across all states avoids bubble-resize when image lands.
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
                uploadingPlaceholder
            } else if loading {
                placeholder(systemName: "photo")
            } else {
                placeholder(systemName: "exclamationmark.triangle")
            }
        }
        // Re-run on mediaID change so the placeholder flips to the real photo post-upload.
        .task(id: message.mediaID ?? "") { await load() }
        .fullScreenCover(isPresented: $fullscreen) {
            if let image { FullscreenPhotoViewer(image: image) { fullscreen = false } }
        }
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

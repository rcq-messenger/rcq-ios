import AVKit
import SwiftUI
import UIKit

/// Video message bubble. Inline thumbnail + play overlay + duration badge.
/// Tap → downloads encrypted blob, decrypts to temp file, plays via AVPlayerViewController.
struct VideoBubble: View {
    let message: Message
    var maxWidth: CGFloat = 240

    @State private var thumb: UIImage?
    @State private var preparing = false
    @State private var playerURL: URL?
    /// Spoiler video renders a blurred thumbnail until the first tap
    /// (which reveals; the second tap plays). Session-only state.
    @State private var spoilerRevealed = false
    @StateObject private var progress = MediaProgressStore.shared

    private var isUploading: Bool {
        message.mediaID == nil && message.deliveryState == .sending
    }

    private var didFailUpload: Bool {
        message.mediaID == nil && message.deliveryState == .failed
    }

    private var spoilerCovered: Bool {
        message.isSpoiler && !spoilerRevealed
    }

    var body: some View {
        ZStack {
            if let thumb {
                Image(uiImage: thumb)
                    .resizable()
                    .scaledToFill()
                    .frame(width: maxWidth, height: maxWidth * 0.75)
                    .blur(radius: spoilerCovered ? 18 : 0, opaque: true)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                placeholderFill
            }
            if !isUploading && !didFailUpload, !spoilerCovered, message.durationSec > 0 {
                VStack {
                    HStack {
                        Text(durationLabel(message.durationSec))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.black.opacity(0.6)))
                            .padding(8)
                        Spacer()
                    }
                    Spacer()
                }
                .frame(width: maxWidth, height: maxWidth * 0.75)
            }
            if isUploading {
                uploadRing
            } else if didFailUpload {
                uploadFailed
            } else if preparing {
                ProgressView().tint(.white).scaleEffect(1.2)
            } else if spoilerCovered {
                Image(systemName: "eye.slash.fill")
                    .font(.system(size: 26))
                    .foregroundColor(.white.opacity(0.92))
                    .shadow(color: .black.opacity(0.5), radius: 4)
            } else if thumb != nil {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 56))
                    .foregroundColor(.white.opacity(0.95))
                    .shadow(radius: 4)
            }
        }
        .frame(width: maxWidth, height: maxWidth * 0.75)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            if spoilerCovered {
                withAnimation(.easeOut(duration: 0.25)) { spoilerRevealed = true }
                return
            }
            guard !isUploading, !didFailUpload, thumb != nil else { return }
            // Route through the album viewer (single-item album) so
            // standalone video shares the same chrome and gestures
            // as multi-item albums — same close + save buttons,
            // swipe-down dismiss, swipe-paging stub.
            AlbumViewerPresenter.present(items: [message], initialIndex: 0)
        }
        .onAppear { decodeThumb() }
    }

    private var uploadRing: some View {
        ZStack {
            Color.black.opacity(0.35)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Circle()
                .stroke(Color.white.opacity(0.25), lineWidth: 3)
                .frame(width: 48, height: 48)
            Circle()
                .trim(from: 0, to: max(0.02, CGFloat(progress.value(for: message.id) ?? 0)))
                .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 48, height: 48)
                .animation(.easeOut(duration: 0.2), value: progress.value(for: message.id))
            Text("\(Int((progress.value(for: message.id) ?? 0) * 100))%")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
        }
    }

    private var placeholderFill: some View {
        Theme.Color.bgSecondary
    }

    private var uploadFailed: some View {
        ZStack {
            Color.black.opacity(0.55)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(Theme.Color.statusBusy)
                Text("media.bubble.failed".localized)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
            }
        }
    }

    private func decodeThumb() {
        guard thumb == nil,
              let b64 = message.thumbnailB64,
              let data = Data(base64Encoded: b64),
              let image = UIImage(data: data) else { return }
        thumb = image
    }

    private func play() async {
        guard !preparing else { return }
        guard let raw = message.mediaID else { return }
        let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        preparing = true
        defer { preparing = false }
        if let url = await MediaService.shared.decryptToFile(mediaID: parts[0], keyBase64: parts[1]) {
            self.playerURL = url
        }
    }

    private func durationLabel(_ sec: Double) -> String {
        let s = Int(sec.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct PlayableURL: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
}

struct VideoPlayerSheet: View {
    let url: URL
    let onClose: () -> Void

    @State private var player: AVPlayer?
    @State private var saveState: VideoSaveDelegate.State = .idle

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .onAppear { player.play() }
                    .onDisappear { player.pause() }
            }
            VStack {
                HStack {
                    Button(action: saveVideo) {
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
        .onAppear { player = AVPlayer(url: url) }
    }

    private var saveStateIcon: String {
        switch saveState {
        case .idle:    return "square.and.arrow.down"
        case .saving:  return "ellipsis.circle"
        case .done:    return "checkmark.circle.fill"
        case .failed:  return "exclamationmark.triangle.fill"
        }
    }

    private func saveVideo() {
        let path = url.path
        guard UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(path) else {
            saveState = .failed
            return
        }
        saveState = .saving
        let delegate = VideoSaveDelegate { result in
            saveState = result
            if result == .done {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    await MainActor.run { saveState = .idle }
                }
            }
        }
        UISaveVideoAtPathToSavedPhotosAlbum(
            path, delegate,
            #selector(VideoSaveDelegate.didFinish(videoPath:error:contextInfo:)),
            Unmanaged.passRetained(delegate).toOpaque()
        )
    }
}

final class VideoSaveDelegate: NSObject {
    enum State { case idle, saving, done, failed }
    let onComplete: (State) -> Void
    init(onComplete: @escaping (State) -> Void) { self.onComplete = onComplete }

    @objc func didFinish(videoPath: String, error: Error?, contextInfo: UnsafeMutableRawPointer?) {
        let state: State = (error == nil) ? .done : .failed
        DispatchQueue.main.async { self.onComplete(state) }
        if let contextInfo {
            Unmanaged<VideoSaveDelegate>.fromOpaque(contextInfo).release()
        }
    }
}

import AVKit
import SwiftUI
import UIKit

/// Video message bubble. Shows the inline thumbnail (decoded from the envelope's
/// embedded base64), a play button overlay, and the duration badge. Tapping
/// downloads the encrypted blob, decrypts to a temp file, and plays in
/// fullscreen via AVPlayerViewController.
struct VideoBubble: View {
    let message: Message
    var maxWidth: CGFloat = 240

    @State private var thumb: UIImage?
    @State private var preparing = false
    @State private var playerURL: URL?
    @StateObject private var progress = MediaProgressStore.shared

    /// True while we're still uploading the encrypted blob — bubble
    /// has thumbnail (baked from local source) but no `mediaID`
    /// yet, and `deliveryState` is still `sending`. Drives the
    /// progress-ring overlay instead of the play button.
    private var isUploading: Bool {
        message.mediaID == nil && message.deliveryState == .sending
    }

    /// Upload finished but failed (size cap, network, server error).
    /// Visually distinct from "still uploading" so the user knows
    /// to re-pick the file rather than wait. Currently no in-row
    /// retry — user has to delete the bubble and re-attach (matching
    /// the photo path; retry-button is a polish-tier item).
    private var didFailUpload: Bool {
        message.mediaID == nil && message.deliveryState == .failed
    }

    var body: some View {
        ZStack {
            // Background layer: thumbnail when decoded, secondary
            // fill otherwise. Decoupling the overlays from the
            // thumb-availability branch fixes the "first-frame
            // placeholder shows nothing" symptom — the ring (or
            // failure marker) appears the instant the bubble paints,
            // regardless of how long the base64 → UIImage decode
            // takes.
            if let thumb {
                Image(uiImage: thumb)
                    .resizable()
                    .scaledToFill()
                    .frame(width: maxWidth, height: maxWidth * 0.75)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                placeholderFill
            }
            // Duration badge — only meaningful once we know the
            // bubble is "real video" (mediaID landed or thumb
            // decoded). Hide during upload to give the ring full
            // visual weight.
            if !isUploading && !didFailUpload, message.durationSec > 0 {
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
            // Foreground state overlay — exactly one of (uploading
            // ring, upload-failed marker, preparing spinner, play
            // button) is rendered.
            if isUploading {
                uploadRing
            } else if didFailUpload {
                uploadFailed
            } else if preparing {
                ProgressView().tint(.white).scaleEffect(1.2)
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
            guard !isUploading, !didFailUpload, thumb != nil else { return }
            Task { await play() }
        }
        .onAppear { decodeThumb() }
        .fullScreenCover(item: Binding(
            get: { playerURL.map { PlayableURL(url: $0) } },
            set: { playerURL = $0?.url }
        )) { wrap in
            VideoPlayerSheet(url: wrap.url, onClose: {
                playerURL = nil
                try? FileManager.default.removeItem(at: wrap.url)
            })
        }
    }

    /// Determinate progress ring drawn over the video thumbnail
    /// while the encrypted blob is uploading. Shares the visual
    /// language of `PhotoBubble.uploadingPlaceholder` — circle +
    /// arc + percentage — but layers over the live thumbnail
    /// rather than a flat secondary background, since video bubbles
    /// always have a poster frame.
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

    /// Background fill used when the thumbnail isn't decoded yet.
    /// No icon — the foreground state overlay (ring / failure /
    /// play) provides all the visual content the user needs.
    private var placeholderFill: some View {
        Theme.Color.bgSecondary
    }

    /// Failed-upload marker — explicit "X" + small caption so the
    /// user sees that this bubble didn't go anywhere instead of
    /// staring at a play button that does nothing.
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

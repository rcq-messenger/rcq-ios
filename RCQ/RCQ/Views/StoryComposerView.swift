import AVFoundation
import AVKit
import SwiftUI
import UIKit

/// Composer for posting a 24h story.
///
/// Flow:
/// 1. User picks media (camera or library, photo or video).
/// 2. Preview fills the screen with caption field overlaid at the
///    bottom and an "Anonymous" toggle above it.
/// 3. Tap Post → `StoryService.postPhoto/postVideo` → uploads,
///    writes the row, dismisses.
///
/// Anonymous toggle is per-story (so the user can post most things
/// under their nickname and slip in the occasional anonymous post).
/// Server enforces a per-user cap (18 active stories) so the post
/// can fail loudly with a friendly error.
struct StoryComposerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var stories = StoryService.shared

    @State private var pickedPhoto: UIImage?
    @State private var pickedVideoURL: URL?
    @State private var caption: String = ""
    @State private var sourceMenuShown: Bool = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
        }
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                }
            }
            ToolbarItem(placement: .principal) {
                Text("story.composer.title".localized)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundColor(.white)
            }
            ToolbarItem(placement: .topBarTrailing) {
                if pickedPhoto != nil || pickedVideoURL != nil {
                    Button {
                        Task { await post() }
                    } label: {
                        if stories.isPosting {
                            ProgressView().tint(.white)
                        } else {
                            Text("story.composer.post".localized)
                                .font(.system(.body, weight: .semibold))
                                .foregroundColor(Theme.Color.accent)
                        }
                    }
                    .disabled(stories.isPosting)
                }
            }
        }
        .toolbarBackground(.black, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task {
            // Auto-open source picker on appear so the composer
            // doesn't show an empty black screen.
            if pickedPhoto == nil && pickedVideoURL == nil {
                presentSourceMenu()
            }
        }
        .alert("common.error".localized,
               isPresented: Binding(
                get: { stories.lastError != nil },
                set: { if !$0 { /* StoryService doesn't expose a clear path; user redoes */ } }
               )
        ) {
            Button("common.ok".localized, role: .cancel) {}
        } message: {
            Text(stories.lastError ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let photo = pickedPhoto {
            preview(image: photo)
        } else if let videoURL = pickedVideoURL {
            preview(video: videoURL)
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        VStack(spacing: 18) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(Theme.Color.accent)
            Text("story.composer.empty".localized)
                .font(.callout)
                .foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.center)
            Button {
                presentSourceMenu()
            } label: {
                Text("story.composer.choose".localized)
                    .font(.system(.body, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .background(Theme.Color.accent)
                    .cornerRadius(10)
            }
        }
        .padding(40)
    }

    private func preview(image: UIImage) -> some View {
        ZStack {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack {
                Spacer()
                composerOverlay
            }
        }
    }

    private func preview(video url: URL) -> some View {
        ZStack {
            VideoPlayerView(url: url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack {
                Spacer()
                composerOverlay
            }
        }
    }

    private var composerOverlay: some View {
        HStack(spacing: 8) {
            TextField(
                "story.composer.caption".localized,
                text: $caption,
                axis: .vertical
            )
            .lineLimit(1...3)
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.55))
            .cornerRadius(10)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    // MARK: - Source picker

    private func presentSourceMenu() {
        let alert = UIAlertController(
            title: "story.composer.source_title".localized,
            message: nil,
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(
            title: "story.composer.camera".localized,
            style: .default,
            handler: { _ in
                ImperativePicker.captureFromCamera(mode: .both) { media in
                    Task { @MainActor in
                        switch media {
                        case .photo(let img): pickedPhoto = img; pickedVideoURL = nil
                        case .video(let url): pickedVideoURL = url; pickedPhoto = nil
                        case .none:
                            if pickedPhoto == nil && pickedVideoURL == nil { dismiss() }
                        }
                    }
                }
            }
        ))
        alert.addAction(UIAlertAction(
            title: "story.composer.photo_library".localized,
            style: .default,
            handler: { _ in
                ImperativePicker.pickImages(limit: 1) { images in
                    Task { @MainActor in
                        if let first = images.first {
                            pickedPhoto = first
                            pickedVideoURL = nil
                        } else if pickedPhoto == nil && pickedVideoURL == nil {
                            dismiss()
                        }
                    }
                }
            }
        ))
        alert.addAction(UIAlertAction(
            title: "story.composer.video_library".localized,
            style: .default,
            handler: { _ in
                ImperativePicker.pickVideo { url in
                    Task { @MainActor in
                        if let url {
                            pickedVideoURL = url
                            pickedPhoto = nil
                        } else if pickedPhoto == nil && pickedVideoURL == nil {
                            dismiss()
                        }
                    }
                }
            }
        ))
        alert.addAction(UIAlertAction(
            title: "common.cancel".localized,
            style: .cancel,
            handler: { _ in
                if pickedPhoto == nil && pickedVideoURL == nil { dismiss() }
            }
        ))
        // Present from top VC so the action sheet appears above
        // any modal cover this composer is inside of.
        if let top = topVC() {
            // iPad popover anchor — required, otherwise crashes on iPad.
            alert.popoverPresentationController?.sourceView = top.view
            alert.popoverPresentationController?.sourceRect = CGRect(
                x: top.view.bounds.midX, y: top.view.bounds.midY,
                width: 0, height: 0
            )
            alert.popoverPresentationController?.permittedArrowDirections = []
            top.present(alert, animated: true)
        }
    }

    private func topVC() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
        let active = scenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })
        var vc = active?.windows.first(where: \.isKeyWindow)?.rootViewController
        while let presented = vc?.presentedViewController { vc = presented }
        return vc
    }

    // MARK: - Post

    private func post() async {
        let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        if let img = pickedPhoto {
            await stories.postPhoto(img, caption: trimmed.isEmpty ? nil : trimmed, anonymous: false)
        } else if let url = pickedVideoURL {
            await stories.postVideo(url, caption: trimmed.isEmpty ? nil : trimmed, anonymous: false)
        }
        if stories.lastError == nil {
            dismiss()
        }
    }
}

/// Minimal AVPlayer wrapper for the composer preview. Loops + muted
/// so the preview doesn't ambush the user with audio.
private struct VideoPlayerView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let player = AVPlayer(url: url)
        player.isMuted = true
        let vc = AVPlayerViewController()
        vc.player = player
        vc.videoGravity = .resizeAspect
        vc.showsPlaybackControls = false
        player.play()
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { _ in
            player.seek(to: .zero)
            player.play()
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}
}

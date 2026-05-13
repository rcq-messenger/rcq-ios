import AVKit
import SwiftUI
import UIKit

/// Fullscreen Instagram-style stories viewer. Tap left/right to step,
/// hold to pause, swipe down to dismiss. Photos auto-advance after
/// 5s; videos drive progress from playback time.
struct StoryViewerView: View {
    @Environment(\.dismiss) private var dismiss
    let groups: [StoryGroup]
    let initialGroupIndex: Int
    let myUIN: Int

    @StateObject private var stories = StoryService.shared
    @State private var groupIndex: Int
    @State private var storyIndex: Int = 0
    @State private var progress: Double = 0
    @State private var isPaused: Bool = false
    @State private var dragOffset: CGFloat = 0
    @State private var photoDuration: Double = 5.0
    @State private var viewersSheetID: String?
    @State private var deleteConfirmID: String?
    @State private var videoPlayer: AVPlayer?

    init(groups: [StoryGroup], initialGroupIndex: Int, myUIN: Int) {
        self.groups = groups
        self.initialGroupIndex = max(0, min(initialGroupIndex, groups.count - 1))
        self.myUIN = myUIN
        _groupIndex = State(initialValue: max(0, min(initialGroupIndex, groups.count - 1)))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                if let story = currentStory {
                    media(for: story, in: geo)
                    // Tap zones below chrome in z-order so chrome
                    // Buttons (X, ⋯) hit-test first.
                    tapZones(width: geo.size.width, topInset: 84)
                    chrome(for: story)
                }
            }
            .offset(y: dragOffset)
            .opacity(1.0 - min(1.0, Double(abs(dragOffset)) / 400.0))
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { v in
                        if v.translation.height > 0 {
                            dragOffset = v.translation.height
                        }
                    }
                    .onEnded { v in
                        if v.translation.height > 120 || v.predictedEndTranslation.height > 200 {
                            dismiss()
                        } else {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                dragOffset = 0
                            }
                        }
                    }
            )
            .onAppear {
                Task { await markCurrentViewed() }
                schedulePhotoTick()
            }
            .onChange(of: groupIndex) { _ in
                storyIndex = 0
                progress = 0
                Task { await markCurrentViewed() }
                schedulePhotoTick()
            }
            .onChange(of: storyIndex) { _ in
                progress = 0
                Task { await markCurrentViewed() }
                schedulePhotoTick()
            }
            .sheet(item: Binding(
                get: { viewersSheetID.map { IdentifiedString(value: $0) } },
                set: { viewersSheetID = $0?.value }
            )) { wrapper in
                ViewersSheet(storyID: wrapper.value)
            }
            .confirmationDialog(
                "story.viewer.delete_confirm".localized,
                isPresented: Binding(
                    get: { deleteConfirmID != nil },
                    set: { if !$0 { deleteConfirmID = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("story.viewer.delete".localized, role: .destructive) {
                    if let id = deleteConfirmID {
                        Task {
                            await stories.delete(id)
                            handleDeletedCurrentStory()
                        }
                    }
                }
                Button("common.cancel".localized, role: .cancel) {}
            }
        }
        .statusBarHidden()
    }

    // MARK: - Computed

    private var currentGroup: StoryGroup? {
        guard groups.indices.contains(groupIndex) else { return nil }
        return groups[groupIndex]
    }

    private var currentStory: Story? {
        guard let g = currentGroup, g.stories.indices.contains(storyIndex) else { return nil }
        return g.stories[storyIndex]
    }

    private var isOwnStory: Bool {
        currentStory?.ownerUIN == myUIN
    }

    // MARK: - Media

    @ViewBuilder
    private func media(for story: Story, in geo: GeometryProxy) -> some View {
        switch story.mediaKind {
        case .photo:
            StoryPhotoView(mediaID: story.mediaID, keyB64: story.mediaKeyB64)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .video:
            StoryVideoPlayer(
                mediaID: story.mediaID,
                keyB64: story.mediaKeyB64,
                paused: isPaused,
                onProgress: { current, total in
                    guard total > 0 else { return }
                    progress = min(1, current / total)
                    if current >= total { advance() }
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(story.id)
        }
    }

    // MARK: - Chrome (progress + byline + caption + actions)

    private func chrome(for story: Story) -> some View {
        VStack(spacing: 0) {
            progressBar
                .padding(.horizontal, 12)
                .padding(.top, 8)
            byline(for: story)
                .padding(.horizontal, 16)
                .padding(.top, 8)
            Spacer()
            if let caption = story.caption, !caption.isEmpty {
                captionBlock(caption)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 24)
            }
        }
        .opacity(isPaused ? 0 : 1)
        .animation(.easeInOut(duration: 0.15), value: isPaused)
    }

    private var progressBar: some View {
        HStack(spacing: 4) {
            if let g = currentGroup {
                ForEach(Array(g.stories.enumerated()), id: \.element.id) { idx, _ in
                    GeometryReader { gp in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.3))
                            Capsule()
                                .fill(Color.white)
                                .frame(width: gp.size.width * fillFraction(idx: idx))
                        }
                    }
                    .frame(height: 2.5)
                }
            }
        }
    }

    private func fillFraction(idx: Int) -> Double {
        if idx < storyIndex { return 1.0 }
        if idx == storyIndex { return progress }
        return 0.0
    }

    @ViewBuilder
    private func byline(for story: Story) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(displayedName(for: story))
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundColor(.white)
                    Text(relativePostedAt(story.postedAt))
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                }
                if isOwnStory {
                    HStack(spacing: 4) {
                        Image(systemName: "eye.fill").font(.system(size: 11))
                        Text(viewerCountText(story.viewCount))
                            .font(.caption2)
                    }
                    .foregroundColor(.white.opacity(0.85))
                }
            }
            Spacer()
            if isOwnStory {
                Menu {
                    Button {
                        viewersSheetID = story.id
                    } label: {
                        Label("story.viewer.show_viewers".localized, systemImage: "eye")
                    }
                    Button(role: .destructive) {
                        deleteConfirmID = story.id
                    } label: {
                        Label("story.viewer.delete".localized, systemImage: "trash")
                    }
                    .tint(.red)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(8)
                }
            } else if !story.isAnonymous, let ownerUIN = story.ownerUIN {
                // Anonymous stories hide the menu since the author is
                // not exposed.
                Menu {
                    UserSafetyActions(
                        targetUIN: ownerUIN,
                        targetNickname: story.ownerNickname ?? "#\(ownerUIN)",
                        context: "story",
                        style: .menu,
                    )
                    .tint(.red)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(8)
                }
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(8)
            }
        }
    }

    private func captionBlock(_ caption: String) -> some View {
        Text(caption)
            .font(.body)
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.45))
            .cornerRadius(10)
    }

    // MARK: - Tap zones

    private func tapZones(width: CGFloat, topInset: CGFloat) -> some View {
        VStack(spacing: 0) {
            // Reserve top strip for chrome (progress / byline / buttons).
            Color.clear
                .frame(height: topInset)
                .allowsHitTesting(false)
            HStack(spacing: 0) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { goBack() }
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { advance() }
            }
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.18)
                .sequenced(before: DragGesture(minimumDistance: 0))
                .onChanged { v in
                    switch v {
                    case .first: isPaused = false
                    case .second(true, _): isPaused = true
                    default: break
                    }
                }
                .onEnded { _ in isPaused = false }
        )
    }

    // MARK: - Navigation

    private func advance() {
        guard let g = currentGroup else { dismiss(); return }
        if storyIndex + 1 < g.stories.count {
            storyIndex += 1
        } else if groupIndex + 1 < groups.count {
            groupIndex += 1
        } else {
            dismiss()
        }
    }

    private func goBack() {
        if storyIndex > 0 {
            storyIndex -= 1
            progress = 0
        } else if groupIndex > 0 {
            groupIndex -= 1
            let prevCount = groups[groupIndex].stories.count
            storyIndex = max(0, prevCount - 1)
            progress = 0
        } else {
            progress = 0
        }
    }

    private func handleDeletedCurrentStory() {
        Task { await stories.refresh() }
        dismiss()
    }

    // MARK: - Photo tick

    // 5s auto-advance for photo stories; video stories are driven by
    // the player's onProgress callback.
    private func schedulePhotoTick() {
        guard let s = currentStory, s.mediaKind == .photo else { return }
        let total = photoDuration
        let started = Date()
        Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 33_000_000)
                guard let still = currentStory, still.id == s.id else { return }
                if isPaused { continue }
                let elapsed = Date().timeIntervalSince(started)
                let p = min(1, elapsed / total)
                progress = p
                if p >= 1 {
                    advance()
                    return
                }
            }
        }
    }

    // MARK: - View tracking

    private func markCurrentViewed() async {
        guard let s = currentStory else { return }
        if !s.viewed && s.ownerUIN != myUIN {
            stories.markViewed(s.id)
        }
    }

    // MARK: - Display helpers

    private func displayedName(for story: Story) -> String {
        if story.isAnonymous && story.ownerUIN != myUIN {
            return "story.viewer.anonymous_byline".localized
        }
        return story.ownerNickname ?? "story.viewer.unknown".localized
    }

    private func relativePostedAt(_ date: Date) -> String {
        let mins = Int(Date().timeIntervalSince(date) / 60)
        if mins < 1 { return "story.time.now".localized }
        if mins < 60 {
            return String(format: "story.time.minutes_ago".localized, mins)
        }
        let hours = mins / 60
        return String(format: "story.time.hours_ago".localized, hours)
    }

    private func viewerCountText(_ n: Int) -> String {
        String(format: "story.viewer.view_count".localized, n)
    }
}

// MARK: - Photo loader

private struct StoryPhotoView: View {
    let mediaID: String
    let keyB64: String
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: mediaID) {
            let img = await MediaService.shared.loadImage(mediaID: mediaID, keyBase64: keyB64)
            await MainActor.run { self.image = img }
        }
    }
}

// MARK: - Video loader

private struct StoryVideoPlayer: UIViewControllerRepresentable {
    let mediaID: String
    let keyB64: String
    let paused: Bool
    let onProgress: (Double, Double) -> Void

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.showsPlaybackControls = false
        vc.videoGravity = .resizeAspect
        Task { @MainActor in
            guard let url = await MediaService.shared.decryptToFile(
                mediaID: mediaID, keyBase64: keyB64
            ) else { return }
            let player = AVPlayer(url: url)
            player.isMuted = false
            vc.player = player
            let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
            player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
                let dur = player.currentItem?.duration ?? .zero
                let total = dur.isNumeric ? CMTimeGetSeconds(dur) : 0
                onProgress(CMTimeGetSeconds(time), total)
            }
            player.play()
        }
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        guard let player = vc.player else { return }
        if paused {
            player.pause()
        } else if player.timeControlStatus != .playing {
            player.play()
        }
    }
}

// MARK: - Viewers sheet

private struct ViewersSheet: View {
    let storyID: String
    @State private var viewers: [StoryViewer] = []
    @State private var loaded: Bool = false

    var body: some View {
        NavigationStack {
            List {
                if !loaded {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if viewers.isEmpty {
                    Text("story.viewer.no_views".localized)
                        .foregroundColor(Theme.Color.textSecondary)
                } else {
                    ForEach(viewers) { v in
                        HStack {
                            Text(v.viewerNickname)
                                .font(.body)
                            Spacer()
                            Text(v.viewedAt, style: .relative)
                                .font(.caption)
                                .foregroundColor(Theme.Color.textSecondary)
                        }
                    }
                }
            }
            .navigationTitle("story.viewer.viewers_title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .task {
                let result = await StoryService.shared.loadViewers(for: storyID)
                viewers = result
                loaded = true
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct IdentifiedString: Identifiable {
    var id: String { value }
    let value: String
}

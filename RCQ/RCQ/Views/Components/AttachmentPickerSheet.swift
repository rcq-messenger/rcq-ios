import Photos
import SwiftUI
import UIKit

/// Telegram-style attachment sheet for the chat composer. Photo +
/// video grid lives in the upper detent; a horizontal action row
/// (camera / file / location / premium / poll) sits below the grid
/// so the user picks media WITHOUT a second tap, and falls back to
/// the long-tail actions in the same sheet.
///
/// Replaces the prior vertical menu, which forced one extra tap
/// (paperclip → Gallery → grid) for the dominant flow (sending a
/// photo) and crowded the row list when groups added Poll on top of
/// Document + Location + Premium.
struct AttachmentPickerSheet: View {
    let isRandom: Bool
    /// This room's `files_allowed` rule as it applies to THIS viewer (the
    /// owner, an admin and any member with a granted cap stay exempt). False
    /// removes the Document chip outright rather than leaving a dead button:
    /// the send would be refused anyway, and a disabled control that never
    /// explains itself is worse than an entry that is simply not there. The
    /// send path guards too, for a menu that was already open when the owner
    /// flipped the switch. Web: `filesAllowed` in Chat.tsx.
    var filesAllowed: Bool = true
    /// Sender called this when the user finishes picking media. Caller
    /// dismisses the sheet and routes selected media into the send
    /// pipeline. Empty array on cancel.
    let onMedia: ([CapturedMedia]) -> Void
    /// Open the camera UI.
    let onCamera: () -> Void
    let onDocument: () -> Void
    let onLocation: () -> Void
    /// Share a group invite to this chat. Non-nil only when the
    /// caller is a group OWNER (so others' membership stays a
    /// privacy choice); nil hides the action.
    var onShareGroup: (() -> Void)? = nil
    // Two chips used to live here: `onPoll` (create a group poll) and
    // `onShareConnection` (hand the chat a relay out of your pool). Both
    // features are cut - polls because the ballots were never end-to-end
    // encrypted (14a), relay sharing as a product decision (14b). Removed
    // rather than left as permanently-nil parameters, so the next reader does
    // not go looking for the caller that passes them.

    @State private var assets: [PHAsset] = []
    @State private var authStatus: PHAuthorizationStatus = .notDetermined
    @State private var selected: [String] = []   // localIdentifier in pick order
    @State private var loadingResult = false

    private let imageManager = PHCachingImageManager()
    private static let pickLimit: Int = 10

    var body: some View {
        VStack(spacing: 0) {
            actionRow
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            Divider()
                .background(Theme.Color.divider)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !selected.isEmpty {
                Divider().background(Theme.Color.divider)
                sendBar
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
        .background(Theme.Color.bgPrimary.ignoresSafeArea())
        .task { await load() }
    }

    // MARK: - actions row

    private var actionRow: some View {
        // Compact icon-only row keeps the heavy lifting (media grid)
        // visible above. Each chip is 64×60 — large enough to read
        // and tap, narrow enough to fit 5+ across a 320pt screen.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                actionChip(icon: "camera", labelKey: "chat.attach.camera", action: onCamera)
                if !isRandom {
                    if filesAllowed {
                        actionChip(icon: "doc.fill", labelKey: "chat.attach.document", action: onDocument)
                    }
                    actionChip(icon: "mappin.and.ellipse", labelKey: "chat.attach.location", action: onLocation)
                }
                if let onShareGroup {
                    actionChip(icon: "person.3.fill", labelKey: "chat.attach.share_group", action: onShareGroup)
                }
            }
        }
    }

    private func actionChip(icon: String, labelKey: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(Theme.Color.accent)
                    .frame(width: 44, height: 44)
                    .background(Theme.Color.accent.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                Text(labelKey.localized)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Theme.Color.textSecondary)
                    .lineLimit(1)
            }
            .frame(width: 64)
        }
        .buttonStyle(.plain)
    }

    // MARK: - grid

    @ViewBuilder
    private var content: some View {
        switch authStatus {
        case .authorized, .limited:
            grid
        case .denied, .restricted:
            denied
        case .notDetermined:
            ProgressView().tint(Theme.Color.accent)
        @unknown default:
            denied
        }
    }

    private var grid: some View {
        let cols = [
            GridItem(.flexible(), spacing: 2),
            GridItem(.flexible(), spacing: 2),
            GridItem(.flexible(), spacing: 2),
        ]
        return ScrollView {
            LazyVGrid(columns: cols, spacing: 2) {
                ForEach(assets, id: \.localIdentifier) { asset in
                    InlineMediaThumb(
                        asset: asset,
                        selectionIndex: selected.firstIndex(of: asset.localIdentifier),
                        cachingManager: imageManager,
                        onTap: { toggle(asset) }
                    )
                }
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 24)
        }
    }

    private var denied: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 36))
                .foregroundColor(Theme.Color.textSecondary)
            Text("media_picker.denied".localized)
                .font(.callout)
                .foregroundColor(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("media_picker.open_settings".localized) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - send bar

    private var sendBar: some View {
        HStack(spacing: 12) {
            Spacer()
            Button {
                Task { await emit() }
            } label: {
                if loadingResult {
                    ProgressView().tint(.white)
                } else {
                    // `media_picker.send` already formats the count as
                    // "Add (N)" — no separate selection-count caption
                    // (the missing `media_picker.selected_count` key
                    // was rendering its raw lookup string in TF).
                    Text(String(format: "media_picker.send".localized, selected.count))
                        .font(.system(.body).weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .background(Theme.Color.accent)
                        .clipShape(Capsule())
                }
            }
            .buttonStyle(.plain)
            .disabled(loadingResult)
        }
    }

    // MARK: - state

    private func toggle(_ asset: PHAsset) {
        let id = asset.localIdentifier
        if let idx = selected.firstIndex(of: id) {
            selected.remove(at: idx)
        } else {
            guard selected.count < Self.pickLimit else {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                return
            }
            selected.append(id)
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }

    // MARK: - load / emit

    private func load() async {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            let granted = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            await MainActor.run { authStatus = granted }
            if granted == .authorized || granted == .limited {
                await fetch()
            }
        } else {
            await MainActor.run { authStatus = status }
            if status == .authorized || status == .limited {
                await fetch()
            }
        }
    }

    private func fetch() async {
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.predicate = NSPredicate(
            format: "mediaType == %d || mediaType == %d",
            PHAssetMediaType.image.rawValue,
            PHAssetMediaType.video.rawValue
        )
        let result = PHAsset.fetchAssets(with: opts)
        var collected: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in collected.append(asset) }
        await MainActor.run { self.assets = collected }
    }

    private func emit() async {
        guard !selected.isEmpty else { return }
        await MainActor.run { loadingResult = true }
        let order = selected
        let lookup = Dictionary(uniqueKeysWithValues: assets.map { ($0.localIdentifier, $0) })
        var output: [CapturedMedia] = []
        for id in order {
            guard let asset = lookup[id] else { continue }
            if asset.mediaType == .image {
                if Self.isGIFAsset(asset),
                   let (data, preview) = await Self.requestGIFData(asset: asset) {
                    output.append(.gif(data: data, preview: preview))
                } else if let img = await Self.requestImage(asset: asset) {
                    output.append(.photo(img))
                }
            } else if asset.mediaType == .video {
                if let url = await Self.requestVideoURL(asset: asset) {
                    output.append(.video(url))
                }
            }
        }
        await MainActor.run {
            loadingResult = false
            onMedia(output)
        }
    }

    private static func isGIFAsset(_ asset: PHAsset) -> Bool {
        return PHAssetResource.assetResources(for: asset).contains {
            $0.uniformTypeIdentifier == "com.compuserve.gif"
        }
    }

    private static func requestGIFData(asset: PHAsset) async -> (Data, UIImage)? {
        await withCheckedContinuation { (cont: CheckedContinuation<(Data, UIImage)?, Never>) in
            let opts = PHImageRequestOptions()
            opts.isNetworkAccessAllowed = true
            opts.deliveryMode = .highQualityFormat
            opts.resizeMode = .none
            opts.version = .current
            PHImageManager.default().requestImageDataAndOrientation(
                for: asset, options: opts
            ) { data, _, _, _ in
                guard let data, let preview = UIImage(data: data) else {
                    cont.resume(returning: nil)
                    return
                }
                cont.resume(returning: (data, preview))
            }
        }
    }

    private static func requestImage(asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
            let opts = PHImageRequestOptions()
            opts.isNetworkAccessAllowed = true
            opts.deliveryMode = .highQualityFormat
            opts.resizeMode = .none
            opts.isSynchronous = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: PHImageManagerMaximumSize,
                contentMode: .default,
                options: opts
            ) { img, _ in
                cont.resume(returning: img)
            }
        }
    }

    private static func requestVideoURL(asset: PHAsset) async -> URL? {
        await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            let opts = PHVideoRequestOptions()
            opts.isNetworkAccessAllowed = true
            opts.version = .current
            opts.deliveryMode = .highQualityFormat
            PHImageManager.default().requestAVAsset(forVideo: asset, options: opts) { avAsset, _, _ in
                guard let urlAsset = avAsset as? AVURLAsset else {
                    cont.resume(returning: nil)
                    return
                }
                let copy = FileManager.default.temporaryDirectory
                    .appendingPathComponent("rcq-pick-\(UUID().uuidString).\(urlAsset.url.pathExtension.isEmpty ? "mov" : urlAsset.url.pathExtension)")
                do {
                    try FileManager.default.copyItem(at: urlAsset.url, to: copy)
                    cont.resume(returning: copy)
                } catch {
                    cont.resume(returning: nil)
                }
            }
        }
    }
}

/// Grid cell — same shape as `UnifiedMediaPicker.MediaThumb` but
/// kept private so the sheet stays standalone (the picker file owns
/// its own copy for the older callers).
private struct InlineMediaThumb: View {
    let asset: PHAsset
    let selectionIndex: Int?
    let cachingManager: PHCachingImageManager
    let onTap: () -> Void

    @State private var thumb: UIImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            GeometryReader { geo in
                ZStack {
                    Theme.Color.bgSecondary
                    if let thumb {
                        Image(uiImage: thumb)
                            .resizable()
                            .scaledToFill()
                    }
                }
                .frame(width: geo.size.width, height: geo.size.width)
                .clipped()
                .overlay(alignment: .bottomLeading) {
                    if asset.mediaType == .video {
                        Text(durationLabel(asset.duration))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.black.opacity(0.55)))
                            .padding(4)
                    }
                }
                .overlay {
                    if selectionIndex != nil {
                        Rectangle().fill(Theme.Color.accent.opacity(0.25))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { onTap() }
                .task(id: asset.localIdentifier) {
                    await loadThumb(targetSize: CGSize(width: geo.size.width * 2, height: geo.size.width * 2))
                }
            }
            .aspectRatio(1, contentMode: .fit)
            ZStack {
                Circle()
                    .strokeBorder(Color.white.opacity(0.85), lineWidth: 1.5)
                    .background(
                        Circle().fill(selectionIndex != nil ? Theme.Color.accent : Color.black.opacity(0.25))
                    )
                if let idx = selectionIndex {
                    Text("\(idx + 1)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            .frame(width: 22, height: 22)
            .padding(6)
        }
    }

    private func loadThumb(targetSize: CGSize) async {
        let opts = PHImageRequestOptions()
        opts.isNetworkAccessAllowed = true
        opts.deliveryMode = .opportunistic
        opts.resizeMode = .fast
        cachingManager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: opts
        ) { img, _ in
            if let img { Task { @MainActor in self.thumb = img } }
        }
    }

    private func durationLabel(_ dur: TimeInterval) -> String {
        let total = Int(dur.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

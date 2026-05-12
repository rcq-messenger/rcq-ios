import Photos
import SwiftUI
import UIKit

/// Presents `UnifiedMediaPicker` via UIKit to avoid SwiftUI's
/// sheet-after-sheet bug on iOS 26 where a `.sheet` flipped on right
/// after another sheet dismisses is silently dropped. Mirrors
/// `ImperativePicker`'s pattern: walk to the top VC and call
/// `present(_:animated:)` directly.
@MainActor
enum UnifiedMediaPickerPresenter {
    static func present(
        limit: Int,
        onDone: @escaping ([CapturedMedia]) -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        guard let top = topViewController() else {
            onCancel()
            return
        }
        var hostRef: UIViewController?
        let view = UnifiedMediaPicker(
            limit: limit,
            onDone: { items in
                hostRef?.dismiss(animated: true) { onDone(items) }
            },
            onCancel: {
                hostRef?.dismiss(animated: true) { onCancel() }
            }
        )
        let host = UIHostingController(rootView: view)
        host.modalPresentationStyle = .pageSheet
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 16
        }
        hostRef = host
        top.present(host, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        let window = scenes.flatMap { $0.windows }.first(where: { $0.isKeyWindow })
            ?? scenes.flatMap { $0.windows }.first
        guard var vc = window?.rootViewController else { return nil }
        while let presented = vc.presentedViewController { vc = presented }
        return vc
    }
}

/// Custom photos+videos picker rendered as a single chronological grid
/// instead of the system PHPicker's separate tabs. Built directly on
/// `PHFetchResult<PHAsset>` so we can guarantee mixed-kind ordering
/// (PHPicker on iOS 17+ sometimes lands on a "Recents" filter that
/// hides one kind, and there's no API to force the unified Library
/// view).
///
/// Multi-select up to `limit`. On Done, requests each asset's binary
/// representation and returns `[CapturedMedia]` to the caller.
struct UnifiedMediaPicker: View {
    let limit: Int
    let onDone: ([CapturedMedia]) -> Void
    let onCancel: () -> Void

    @State private var assets: [PHAsset] = []
    @State private var selected: [String] = []  // localIdentifier order = pick order
    @State private var authStatus: PHAuthorizationStatus = .notDetermined
    @State private var loadingResult = false

    private let imageManager = PHCachingImageManager()

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                content
            }
            .navigationTitle("media_picker.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel".localized) { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await emit() }
                    } label: {
                        if loadingResult {
                            ProgressView().tint(Theme.Color.accent)
                        } else if selected.isEmpty {
                            Text("common.done".localized)
                                .foregroundColor(Theme.Color.textSecondary)
                        } else {
                            Text(String(format: "media_picker.send".localized, selected.count))
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(selected.isEmpty || loadingResult)
                }
            }
        }
        .task { await load() }
    }

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
                    MediaThumb(
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

    // MARK: - state

    private func toggle(_ asset: PHAsset) {
        let id = asset.localIdentifier
        if let idx = selected.firstIndex(of: id) {
            selected.remove(at: idx)
        } else {
            guard selected.count < limit else {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                return
            }
            selected.append(id)
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }

    // MARK: - load

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

    // MARK: - emit

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
                    // Preserve animation by routing raw bytes through
                    // the send pipeline. JPEG-recompressing here used
                    // to drop the frames and the receiver got a static
                    // first-frame bubble.
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
            onDone(output)
        }
    }

    private static func isGIFAsset(_ asset: PHAsset) -> Bool {
        // UTI lives on `PHAssetResource`, not on `PHAsset` — an asset
        // can have several resources (original / edited / adjustments)
        // and any one of them being a GIF means the asset's bytes
        // round-trip animated.
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
                // Copy off the system URL — the upload pipeline deletes
                // its source, and the AVURLAsset's URL points into a
                // shared library location we don't own.
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

/// Single grid cell — thumbnail + duration badge for video + a
/// numbered selection indicator that mirrors the user's pick order.
private struct MediaThumb: View {
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
                        Rectangle()
                            .fill(Theme.Color.accent.opacity(0.25))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    onTap()
                }
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

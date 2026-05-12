import AVKit
import SwiftUI
import UIKit

/// Fullscreen viewer for an album of media. Uses a UIKit-backed
/// horizontal pager (`UIScrollView` with `isPagingEnabled = true`)
/// instead of SwiftUI's TabView/HStack constructs because:
/// - SwiftUI's `TabView(.page)` wraps `UIPageViewController` which
///   monopolises pan gestures, so we can't add a vertical-dismiss.
/// - A custom SwiftUI HStack with `.gesture` competes with child
///   gestures (VideoPlayer, ZoomableImage) and loses on iOS 26.
/// UIKit gestures cooperate via `UIGestureRecognizerDelegate`, so
/// horizontal paging and vertical-drag-to-dismiss can coexist.
/// Direct-UIKit presenter for `AlbumViewerVC`. SwiftUI's
/// `.fullScreenCover` wraps the presented view in its own host
/// controller, which silently competes with the inner UIScrollView
/// paging + dismiss-pan recognisers. Walking to the top VC and
/// calling `present(_:animated:)` ourselves keeps the gesture stack
/// flat — same pattern `UnifiedMediaPickerPresenter` uses.
@MainActor
enum AlbumViewerPresenter {
    static func present(items: [Message], initialIndex: Int, onClose: @escaping () -> Void = {}) {
        guard let top = topViewController() else {
            onClose()
            return
        }
        var hostRef: AlbumViewerVC?
        let vc = AlbumViewerVC(
            items: items,
            initialIndex: initialIndex,
            onDismiss: {
                hostRef?.dismiss(animated: false) { onClose() }
            }
        )
        vc.modalPresentationStyle = .overFullScreen
        vc.modalTransitionStyle = .crossDissolve
        hostRef = vc
        top.present(vc, animated: true)
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

/// UIKit pager. Each page hosts a SwiftUI `AlbumPage` (zoomable image
/// or AVPlayer) inside a UIHostingController.
final class AlbumViewerVC: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let items: [Message]
    private let initialIndex: Int
    private let onDismiss: () -> Void

    private let scrollView = UIScrollView()
    private var pageHosts: [UIHostingController<AlbumPage>] = []
    private var currentIndex: Int
    private let counterLabel = UILabel()
    private let backgroundView = UIView()
    private let closeButton = UIButton(type: .system)
    private let saveButton = UIButton(type: .system)
    private var saveInFlight: Bool = false

    private var dismissPan: UIPanGestureRecognizer?
    /// Locked-in axis for the current pan gesture. Set on the first
    /// `.changed` sample whose translation is large enough to read
    /// direction; reset on `.ended`. While `nil`, the dismiss gesture
    /// stays inert so a slight horizontal drag (page swipe) doesn't
    /// also nudge the dismiss transform.
    private var dismissAxis: DismissAxis?
    private enum DismissAxis { case vertical, horizontal }

    init(items: [Message], initialIndex: Int, onDismiss: @escaping () -> Void) {
        self.items = items
        self.initialIndex = max(0, min(initialIndex, items.count - 1))
        self.currentIndex = self.initialIndex
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        backgroundView.backgroundColor = .black
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backgroundView)
        NSLayoutConstraint.activate([
            backgroundView.topAnchor.constraint(equalTo: view.topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backgroundView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.isPagingEnabled = true
        scrollView.bounces = true
        scrollView.alwaysBounceHorizontal = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delegate = self
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        // Vertical-drag dismiss on the VC's view, recognised
        // simultaneously with the scroll view's horizontal pan thanks
        // to the delegate below.
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleDismissPan(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)
        dismissPan = pan

        closeButton.setImage(
            UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)),
            for: .normal
        )
        closeButton.tintColor = .white
        closeButton.backgroundColor = UIColor.white.withAlphaComponent(0.22)
        closeButton.layer.cornerRadius = 18
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        view.addSubview(closeButton)
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            closeButton.widthAnchor.constraint(equalToConstant: 36),
            closeButton.heightAnchor.constraint(equalToConstant: 36),
        ])

        saveButton.setImage(
            UIImage(systemName: "square.and.arrow.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)),
            for: .normal
        )
        saveButton.tintColor = .white
        saveButton.backgroundColor = UIColor.white.withAlphaComponent(0.22)
        saveButton.layer.cornerRadius = 18
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.addTarget(self, action: #selector(saveCurrent), for: .touchUpInside)
        view.addSubview(saveButton)
        NSLayoutConstraint.activate([
            saveButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            saveButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            saveButton.widthAnchor.constraint(equalToConstant: 36),
            saveButton.heightAnchor.constraint(equalToConstant: 36),
        ])

        if items.count > 1 {
            counterLabel.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
            counterLabel.textColor = .white.withAlphaComponent(0.92)
            counterLabel.textAlignment = .center
            counterLabel.backgroundColor = UIColor.black.withAlphaComponent(0.5)
            counterLabel.layer.cornerRadius = 13
            counterLabel.layer.masksToBounds = true
            counterLabel.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(counterLabel)
            NSLayoutConstraint.activate([
                counterLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
                counterLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                counterLabel.heightAnchor.constraint(equalToConstant: 26),
                counterLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
            ])
            updateCounter()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let w = scrollView.bounds.width
        let h = scrollView.bounds.height
        guard w > 0, h > 0 else { return }
        scrollView.contentSize = CGSize(width: w * CGFloat(items.count), height: h)
        if pageHosts.isEmpty {
            buildPages(width: w, height: h)
            scrollView.setContentOffset(CGPoint(x: w * CGFloat(initialIndex), y: 0), animated: false)
            // Mark the initial page as current so its video starts.
            updateCurrentFromOffset(animated: false)
        } else {
            for (i, host) in pageHosts.enumerated() {
                host.view.frame = CGRect(x: w * CGFloat(i), y: 0, width: w, height: h)
            }
        }
    }

    private func buildPages(width w: CGFloat, height h: CGFloat) {
        for (i, m) in items.enumerated() {
            let host = UIHostingController(
                rootView: AlbumPage(message: m, isCurrent: i == currentIndex)
            )
            host.view.backgroundColor = .clear
            host.view.frame = CGRect(x: w * CGFloat(i), y: 0, width: w, height: h)
            addChild(host)
            scrollView.addSubview(host.view)
            host.didMove(toParent: self)
            pageHosts.append(host)
        }
    }

    private func updateCounter() {
        counterLabel.text = " \(currentIndex + 1) / \(items.count) "
    }

    private func updateCurrentFromOffset(animated: Bool) {
        let w = scrollView.bounds.width
        guard w > 0 else { return }
        let idx = max(0, min(items.count - 1, Int((scrollView.contentOffset.x + w / 2) / w)))
        if idx != currentIndex {
            currentIndex = idx
            updateCounter()
            // Refresh `isCurrent` on every page so off-screen videos
            // pause and the new visible video starts.
            for (i, host) in pageHosts.enumerated() {
                host.rootView = AlbumPage(message: items[i], isCurrent: i == idx)
            }
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        updateCurrentFromOffset(animated: true)
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        updateCurrentFromOffset(animated: true)
    }

    // MARK: - dismiss pan

    @objc private func handleDismissPan(_ gr: UIPanGestureRecognizer) {
        let translation = gr.translation(in: view)
        let velocity = gr.velocity(in: view)
        switch gr.state {
        case .began:
            dismissAxis = nil
        case .changed:
            if dismissAxis == nil {
                // Lock axis once movement is decisive enough to read.
                let absX = abs(translation.x)
                let absY = abs(translation.y)
                if max(absX, absY) > 12 {
                    dismissAxis = absY > absX ? .vertical : .horizontal
                }
            }
            guard dismissAxis == .vertical else { return }
            let progress = min(1.0, abs(translation.y) / 240)
            scrollView.transform = CGAffineTransform(translationX: 0, y: translation.y)
                .scaledBy(x: 1.0 - progress * 0.2, y: 1.0 - progress * 0.2)
            backgroundView.alpha = 1.0 - progress * 0.85
            counterLabel.alpha = 1.0 - progress
            closeButton.alpha = 1.0 - progress
            saveButton.alpha = 1.0 - progress
        case .ended, .cancelled:
            defer { dismissAxis = nil }
            guard dismissAxis == .vertical else {
                // Horizontal drag — paging handled by scroll view, no
                // transform to roll back.
                return
            }
            let shouldDismiss = abs(translation.y) > 120 || abs(velocity.y) > 700
            if shouldDismiss {
                let direction: CGFloat = translation.y > 0 ? 1 : -1
                UIView.animate(withDuration: 0.2, animations: {
                    self.scrollView.transform = CGAffineTransform(translationX: 0, y: direction * 1000)
                        .scaledBy(x: 0.7, y: 0.7)
                    self.backgroundView.alpha = 0
                    self.counterLabel.alpha = 0
                    self.closeButton.alpha = 0
                    self.saveButton.alpha = 0
                }, completion: { _ in
                    self.onDismiss()
                })
            } else {
                UIView.animate(withDuration: 0.32, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
                    self.scrollView.transform = .identity
                    self.backgroundView.alpha = 1.0
                    self.counterLabel.alpha = 1.0
                    self.closeButton.alpha = 1.0
                    self.saveButton.alpha = 1.0
                }
            }
        default:
            break
        }
    }

    @objc private func saveCurrent() {
        guard !saveInFlight else { return }
        let m = items[currentIndex]
        guard let combined = m.mediaID,
              let pipe = combined.firstIndex(of: "|"),
              !combined[..<pipe].isEmpty,
              !combined[combined.index(after: pipe)...].isEmpty
        else {
            flashSaveResult(success: false)
            return
        }
        let mediaID = String(combined[..<pipe])
        let key = String(combined[combined.index(after: pipe)...])
        saveInFlight = true
        setSaveButtonIcon("ellipsis.circle")
        Task {
            switch m.kind {
            case .photo, .premiumPhoto:
                if let img = await MediaService.shared.loadImage(mediaID: mediaID, keyBase64: key) {
                    let delegate = PhotoSaveDelegate { [weak self] result in
                        DispatchQueue.main.async {
                            self?.handleSaveCompletion(success: result == .done)
                        }
                    }
                    UIImageWriteToSavedPhotosAlbum(
                        img, delegate,
                        #selector(PhotoSaveDelegate.didFinish(image:error:contextInfo:)),
                        Unmanaged.passRetained(delegate).toOpaque()
                    )
                } else {
                    await MainActor.run { self.handleSaveCompletion(success: false) }
                }
            case .video, .premiumVideo:
                if let url = await MediaService.shared.decryptToFile(mediaID: mediaID, keyBase64: key),
                   UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(url.path) {
                    let delegate = VideoSaveDelegate { [weak self] result in
                        DispatchQueue.main.async {
                            self?.handleSaveCompletion(success: result == .done)
                            try? FileManager.default.removeItem(at: url)
                        }
                    }
                    UISaveVideoAtPathToSavedPhotosAlbum(
                        url.path, delegate,
                        #selector(VideoSaveDelegate.didFinish(videoPath:error:contextInfo:)),
                        Unmanaged.passRetained(delegate).toOpaque()
                    )
                } else {
                    await MainActor.run { self.handleSaveCompletion(success: false) }
                }
            default:
                await MainActor.run { self.handleSaveCompletion(success: false) }
            }
        }
    }

    private func handleSaveCompletion(success: Bool) {
        saveInFlight = false
        flashSaveResult(success: success)
    }

    private func flashSaveResult(success: Bool) {
        let icon = success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        setSaveButtonIcon(icon)
        if success {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.setSaveButtonIcon("square.and.arrow.down")
        }
    }

    private func setSaveButtonIcon(_ name: String) {
        saveButton.setImage(
            UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)),
            for: .normal
        )
    }

    @objc private func close() {
        UIView.animate(withDuration: 0.2, animations: {
            self.scrollView.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
            self.scrollView.alpha = 0
            self.backgroundView.alpha = 0
            self.counterLabel.alpha = 0
            self.closeButton.alpha = 0
        }, completion: { _ in self.onDismiss() })
    }

    // MARK: - UIGestureRecognizerDelegate

    func gestureRecognizer(
        _ gr: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        // Allow the dismiss-pan to coexist with the scroll view's
        // pan — they look at orthogonal axes (axis lock in
        // `handleDismissPan` keeps them from stomping each other).
        // Without simultaneous recognition iOS fires only one per
        // touch sequence and the user's vertical drags would never
        // reach the dismiss handler.
        return true
    }
}

/// Per-page content. Photo → zoomable image, video → AVPlayer.
private struct AlbumPage: View {
    let message: Message
    let isCurrent: Bool

    var body: some View {
        switch message.kind {
        case .photo, .premiumPhoto:
            ZoomableImage(message: message)
        case .video, .premiumVideo:
            AlbumVideoPage(message: message, isCurrent: isCurrent)
        default:
            Color.black
        }
    }
}

/// Pinch-zoom + double-tap photo page. Self-loads the encrypted
/// blob and decrypts via MediaService.
private struct ZoomableImage: View {
    let message: Message

    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .offset(offset)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .gesture(
                            MagnificationGesture()
                                .onChanged { v in scale = max(1, lastScale * v) }
                                .onEnded { _ in lastScale = scale }
                        )
                        .onTapGesture(count: 2) {
                            withAnimation(.easeInOut(duration: 0.22)) {
                                if scale > 1 {
                                    scale = 1; lastScale = 1
                                    offset = .zero; lastOffset = .zero
                                } else {
                                    scale = 2.5; lastScale = 2.5
                                }
                            }
                        }
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .task(id: message.mediaID ?? "") { await load() }
    }

    private func load() async {
        guard let combined = message.mediaID else { return }
        let parts = combined.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return }
        let mediaID = String(parts[0])
        let key = String(parts[1])
        guard !mediaID.isEmpty, !key.isEmpty else { return }
        if let img = await MediaService.shared.loadImage(mediaID: mediaID, keyBase64: key) {
            await MainActor.run { self.image = img }
        }
    }
}

/// Video page — downloads + decrypts to a temp file, then plays via
/// AVPlayer. Pauses when not the current page.
private struct AlbumVideoPage: View {
    let message: Message
    let isCurrent: Bool

    @State private var url: URL?
    @State private var player: AVPlayer?
    @State private var preparing = false
    @State private var error = false

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else if preparing {
                ProgressView().tint(.white)
            } else if error {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 28)).foregroundColor(.white)
                    Text("media.bubble.failed".localized)
                        .foregroundColor(.white)
                }
            } else {
                Color.black
            }
        }
        .task(id: message.mediaID ?? "") { await prepare() }
        .onChange(of: isCurrent) { current in
            if current { player?.play() } else { player?.pause() }
        }
        .onDisappear {
            player?.pause()
            if let url { try? FileManager.default.removeItem(at: url) }
        }
    }

    private func prepare() async {
        guard let combined = message.mediaID else {
            await MainActor.run { error = true }
            return
        }
        let parts = combined.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            await MainActor.run { error = true }
            return
        }
        let mediaID = String(parts[0])
        let key = String(parts[1])
        guard !mediaID.isEmpty, !key.isEmpty else {
            await MainActor.run { error = true }
            return
        }
        await MainActor.run { preparing = true }
        if let local = await MediaService.shared.decryptToFile(mediaID: mediaID, keyBase64: key) {
            let p = AVPlayer(url: local)
            await MainActor.run {
                self.url = local
                self.player = p
                self.preparing = false
                if isCurrent { p.play() }
            }
        } else {
            await MainActor.run {
                self.error = true
                self.preparing = false
            }
        }
    }
}

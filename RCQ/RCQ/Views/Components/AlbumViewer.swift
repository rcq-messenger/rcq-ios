import AVKit
import ImageIO
import Photos
import SwiftUI
import UIKit

/// Fullscreen album viewer. UIKit horizontal pager; each photo page is
/// a nested `UIScrollView` for native pinch-zoom. Vertical drag
/// dismisses (suppressed while zoomed).
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

final class AlbumViewerVC: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let items: [Message]
    private let initialIndex: Int
    private let onDismiss: () -> Void

    private let scrollView = UIScrollView()
    private var pageHosts: [UIHostingController<AlbumPage>] = []
    private var currentIndex: Int
    private let counterLabel = UILabel()
    private let captionLabel = UILabel()
    private let backgroundView = UIView()
    private var closeBlur = UIVisualEffectView()
    private var saveBlur = UIVisualEffectView()
    private let saveButton = UIButton(type: .system)
    private var headerHost: UIHostingController<AlbumSenderHeader>!
    private var saveInFlight = false
    private var chromeHidden = false
    /// True while the current photo page is zoomed; dismiss-pan is
    /// suppressed.
    private var currentPageZoomed = false

    private var dismissPan: UIPanGestureRecognizer?
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

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleDismissPan(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)
        dismissPan = pan

        closeBlur = makeBlurButton(symbol: "xmark", action: #selector(close)).blur
        saveBlur = makeBlurButton(symbol: "square.and.arrow.down", action: #selector(saveCurrent), button: saveButton).blur
        view.addSubview(closeBlur)
        view.addSubview(saveBlur)
        NSLayoutConstraint.activate([
            closeBlur.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            closeBlur.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            closeBlur.widthAnchor.constraint(equalToConstant: 36),
            closeBlur.heightAnchor.constraint(equalToConstant: 36),
            saveBlur.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            saveBlur.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            saveBlur.widthAnchor.constraint(equalToConstant: 36),
            saveBlur.heightAnchor.constraint(equalToConstant: 36),
        ])

        headerHost = UIHostingController(rootView: AlbumSenderHeader(uin: items[currentIndex].senderUIN))
        headerHost.view.backgroundColor = .clear
        addChild(headerHost)
        view.addSubview(headerHost.view)
        headerHost.didMove(toParent: self)
        headerHost.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            headerHost.view.centerYAnchor.constraint(equalTo: closeBlur.centerYAnchor),
            headerHost.view.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            headerHost.view.leadingAnchor.constraint(greaterThanOrEqualTo: saveBlur.trailingAnchor, constant: 8),
            headerHost.view.trailingAnchor.constraint(lessThanOrEqualTo: closeBlur.leadingAnchor, constant: -8),
        ])

        captionLabel.font = .systemFont(ofSize: 14)
        captionLabel.textColor = .white
        captionLabel.numberOfLines = 3
        captionLabel.textAlignment = .center
        captionLabel.layer.shadowColor = UIColor.black.cgColor
        captionLabel.layer.shadowOpacity = 0.9
        captionLabel.layer.shadowRadius = 3
        captionLabel.layer.shadowOffset = .zero
        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(captionLabel)

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
                counterLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -14),
                counterLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                counterLabel.heightAnchor.constraint(equalToConstant: 26),
                counterLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
                captionLabel.bottomAnchor.constraint(equalTo: counterLabel.topAnchor, constant: -8),
            ])
            updateCounter()
        } else {
            captionLabel.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -14
            ).isActive = true
        }
        NSLayoutConstraint.activate([
            captionLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            captionLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
        ])
        updateCaption()
    }

    /// Circular material-blur button.
    private func makeBlurButton(
        symbol: String, action: Selector, button: UIButton = UIButton(type: .system)
    ) -> (blur: UIVisualEffectView, button: UIButton) {
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.layer.cornerRadius = 18
        blur.clipsToBounds = true
        button.setImage(
            UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)),
            for: .normal
        )
        button.tintColor = .white
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: action, for: .touchUpInside)
        blur.contentView.addSubview(button)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: blur.contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor),
            button.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor),
        ])
        return (blur, button)
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
            updateCurrentFromOffset()
        } else {
            for (i, host) in pageHosts.enumerated() {
                host.view.frame = CGRect(x: w * CGFloat(i), y: 0, width: w, height: h)
            }
        }
    }

    private func buildPages(width w: CGFloat, height h: CGFloat) {
        for (i, m) in items.enumerated() {
            let host = UIHostingController(rootView: makePage(message: m, index: i))
            host.view.backgroundColor = .clear
            host.view.frame = CGRect(x: w * CGFloat(i), y: 0, width: w, height: h)
            addChild(host)
            scrollView.addSubview(host.view)
            host.didMove(toParent: self)
            pageHosts.append(host)
        }
    }

    private func makePage(message: Message, index: Int) -> AlbumPage {
        AlbumPage(
            message: message,
            isCurrent: index == currentIndex,
            onTap: { [weak self] in self?.toggleChrome() },
            onZoomChanged: { [weak self] zoomed in
                guard let self, index == self.currentIndex else { return }
                self.currentPageZoomed = zoomed
            }
        )
    }

    private func updateCounter() {
        counterLabel.text = " \(currentIndex + 1) / \(items.count) "
    }

    private func updateCaption() {
        let text = items[currentIndex].text.trimmingCharacters(in: .whitespacesAndNewlines)
        captionLabel.text = text
        captionLabel.isHidden = text.isEmpty || chromeHidden
    }

    private func updateCurrentFromOffset() {
        let w = scrollView.bounds.width
        guard w > 0 else { return }
        let idx = max(0, min(items.count - 1, Int((scrollView.contentOffset.x + w / 2) / w)))
        if idx != currentIndex {
            currentIndex = idx
            currentPageZoomed = false
            updateCounter()
            updateCaption()
            headerHost.rootView = AlbumSenderHeader(uin: items[idx].senderUIN)
            for (i, host) in pageHosts.enumerated() {
                host.rootView = makePage(message: items[i], index: i)
            }
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        updateCurrentFromOffset()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        updateCurrentFromOffset()
    }

    // MARK: - chrome

    private func toggleChrome() {
        chromeHidden.toggle()
        let a: CGFloat = chromeHidden ? 0 : 1
        let hasCaption = !(captionLabel.text ?? "").isEmpty
        UIView.animate(withDuration: 0.22) {
            self.closeBlur.alpha = a
            self.saveBlur.alpha = a
            self.headerHost.view.alpha = a
            self.counterLabel.alpha = a
            self.captionLabel.alpha = (self.chromeHidden || !hasCaption) ? 0 : 1
        }
    }

    private var chromeAlpha: CGFloat { chromeHidden ? 0 : 1 }

    // MARK: - dismiss pan

    @objc private func handleDismissPan(_ gr: UIPanGestureRecognizer) {
        let translation = gr.translation(in: view)
        let velocity = gr.velocity(in: view)
        switch gr.state {
        case .began:
            dismissAxis = nil
        case .changed:
            if dismissAxis == nil {
                let absX = abs(translation.x)
                let absY = abs(translation.y)
                if max(absX, absY) > 12 {
                    dismissAxis = absY > absX ? .vertical : .horizontal
                }
            }
            guard dismissAxis == .vertical, !currentPageZoomed else { return }
            let progress = min(1.0, abs(translation.y) / 240)
            scrollView.transform = CGAffineTransform(translationX: 0, y: translation.y)
                .scaledBy(x: 1.0 - progress * 0.2, y: 1.0 - progress * 0.2)
            backgroundView.alpha = 1.0 - progress * 0.85
            let chrome = chromeAlpha * (1.0 - progress)
            counterLabel.alpha = chrome
            closeBlur.alpha = chrome
            saveBlur.alpha = chrome
            headerHost.view.alpha = chrome
            captionLabel.alpha = chrome
        case .ended, .cancelled:
            defer { dismissAxis = nil }
            guard dismissAxis == .vertical, !currentPageZoomed else { return }
            let shouldDismiss = abs(translation.y) > 120 || abs(velocity.y) > 700
            if shouldDismiss {
                let direction: CGFloat = translation.y > 0 ? 1 : -1
                UIView.animate(withDuration: 0.2, animations: {
                    self.scrollView.transform = CGAffineTransform(translationX: 0, y: direction * 1000)
                        .scaledBy(x: 0.7, y: 0.7)
                    self.backgroundView.alpha = 0
                    self.counterLabel.alpha = 0
                    self.closeBlur.alpha = 0
                    self.saveBlur.alpha = 0
                    self.headerHost.view.alpha = 0
                    self.captionLabel.alpha = 0
                }, completion: { _ in
                    self.onDismiss()
                })
            } else {
                UIView.animate(withDuration: 0.32, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
                    self.scrollView.transform = .identity
                    self.backgroundView.alpha = 1.0
                    self.counterLabel.alpha = self.chromeAlpha
                    self.closeBlur.alpha = self.chromeAlpha
                    self.saveBlur.alpha = self.chromeAlpha
                    self.headerHost.view.alpha = self.chromeAlpha
                    let hasCaption = !(self.captionLabel.text ?? "").isEmpty
                    self.captionLabel.alpha = (self.chromeHidden || !hasCaption) ? 0 : 1
                }
            }
        default:
            break
        }
    }

    // MARK: - save

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
            case .photo:
                if let (img, data) = await MediaService.shared.loadImageWithData(mediaID: mediaID, keyBase64: key) {
                    if AnimatedGIFView.isGIF(data) {
                        self.saveGIFData(data)
                    } else {
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
                    }
                } else {
                    await MainActor.run { self.handleSaveCompletion(success: false) }
                }
            case .video:
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

    /// Save raw GIF bytes via PhotoKit so frames survive.
    private func saveGIFData(_ data: Data) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { self?.handleSaveCompletion(success: false) }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                let req = PHAssetCreationRequest.forAsset()
                req.addResource(with: .photo, data: data, options: nil)
            } completionHandler: { success, _ in
                DispatchQueue.main.async { self?.handleSaveCompletion(success: success) }
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
        UINotificationFeedbackGenerator().notificationOccurred(success ? .success : .error)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.setSaveButtonIcon("square.and.arrow.down")
        }
    }

    private func setSaveButtonIcon(_ name: String) {
        saveButton.setImage(
            UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)),
            for: .normal
        )
    }

    @objc private func close() {
        UIView.animate(withDuration: 0.2, animations: {
            self.scrollView.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
            self.scrollView.alpha = 0
            self.backgroundView.alpha = 0
            self.counterLabel.alpha = 0
            self.closeBlur.alpha = 0
            self.saveBlur.alpha = 0
            self.headerHost.view.alpha = 0
            self.captionLabel.alpha = 0
        }, completion: { _ in self.onDismiss() })
    }

    // MARK: - UIGestureRecognizerDelegate

    func gestureRecognizer(
        _ gr: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

/// Per-page content. Photo / GIF → zoomable scroll view, video → AVPlayer.
struct AlbumPage: View {
    let message: Message
    let isCurrent: Bool
    let onTap: () -> Void
    let onZoomChanged: (Bool) -> Void

    var body: some View {
        switch message.kind {
        case .photo:
            AlbumImagePage(message: message, onTap: onTap, onZoomChanged: onZoomChanged)
        case .video:
            AlbumVideoPage(message: message, isCurrent: isCurrent)
        default:
            Color.black
        }
    }
}

/// Status dot + nickname (or UIN) in a material capsule.
private struct AlbumSenderHeader: View {
    let uin: Int

    var body: some View {
        let resolved = Self.resolve(uin)
        HStack(spacing: 6) {
            StatusDot(status: resolved.status, size: 8)
            Text(resolved.name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
    }

    private static func resolve(_ uin: Int) -> (name: String, status: UserStatus) {
        if uin == AuthService.shared.ownUIN {
            let nick = AuthService.shared.nickname
            return (nick.isEmpty ? "UIN \(uin)" : nick, PresenceService.shared.status)
        }
        if let c = ContactService.shared.contacts.first(where: { $0.uin == uin }) {
            return (c.nickname, c.status)
        }
        return ("UIN \(uin)", .offline)
    }
}

/// Photo / GIF page. Decrypts via MediaService then hands a (possibly
/// animated) UIImage to the UIScrollView-backed zoomer.
private struct AlbumImagePage: View {
    let message: Message
    let onTap: () -> Void
    let onZoomChanged: (Bool) -> Void

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                ZoomableImageView(image: image, onTap: onTap, onZoomChanged: onZoomChanged)
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: message.mediaID ?? "") { await load() }
    }

    private func load() async {
        guard let combined = message.mediaID else { return }
        let parts = combined.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return }
        let mediaID = String(parts[0])
        let key = String(parts[1])
        guard !mediaID.isEmpty, !key.isEmpty else { return }
        if let (img, data) = await MediaService.shared.loadImageWithData(mediaID: mediaID, keyBase64: key) {
            // GIF → animated UIImage so UIImageView animates inline.
            let final = AnimatedGIFView.isGIF(data) ? (UIImage.rcqAnimatedGIF(from: data) ?? img) : img
            await MainActor.run { self.image = final }
        }
    }
}

/// SwiftUI wrapper over `ZoomableScrollView`.
private struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    let onTap: () -> Void
    let onZoomChanged: (Bool) -> Void

    func makeUIView(context: Context) -> ZoomableScrollView {
        let v = ZoomableScrollView()
        v.onSingleTap = onTap
        v.onZoomChanged = onZoomChanged
        v.setImage(image)
        return v
    }

    func updateUIView(_ uiView: ZoomableScrollView, context: Context) {
        uiView.onSingleTap = onTap
        uiView.onZoomChanged = onZoomChanged
        if uiView.imageView.image !== image { uiView.setImage(image) }
    }
}

/// UIScrollView that zooms and pans a single image view, with
/// focal-point double-tap and a single-tap callback.
final class ZoomableScrollView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    var onSingleTap: (() -> Void)?
    var onZoomChanged: ((Bool) -> Void)?

    init() {
        super.init(frame: .zero)
        delegate = self
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        bouncesZoom = true
        backgroundColor = .clear
        imageView.contentMode = .scaleToFill
        imageView.isUserInteractionEnabled = true
        addSubview(imageView)

        let dbl = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        dbl.numberOfTapsRequired = 2
        addGestureRecognizer(dbl)
        let single = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        single.numberOfTapsRequired = 1
        single.require(toFail: dbl)
        addGestureRecognizer(single)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setImage(_ image: UIImage) {
        imageView.image = image
        imageView.frame = CGRect(origin: .zero, size: image.size)
        contentSize = image.size
        setNeedsLayout()
        layoutIfNeeded()
        applyFitScale()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if zoomScale <= minimumZoomScale { applyFitScale() }
        centerImage()
    }

    private func applyFitScale() {
        guard let img = imageView.image, bounds.width > 0, bounds.height > 0,
              img.size.width > 0, img.size.height > 0 else { return }
        let fit = min(bounds.width / img.size.width, bounds.height / img.size.height)
        minimumZoomScale = fit
        maximumZoomScale = fit * 4
        if abs(zoomScale - fit) > 0.0001 { zoomScale = fit }
        centerImage()
    }

    private func centerImage() {
        let boundsSize = bounds.size
        var frame = imageView.frame
        frame.origin.x = frame.width < boundsSize.width ? (boundsSize.width - frame.width) / 2 : 0
        frame.origin.y = frame.height < boundsSize.height ? (boundsSize.height - frame.height) / 2 : 0
        imageView.frame = frame
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        onZoomChanged?(zoomScale > minimumZoomScale + 0.01)
    }

    @objc private func handleSingleTap() { onSingleTap?() }

    @objc private func handleDoubleTap(_ gr: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale + 0.01 {
            setZoomScale(minimumZoomScale, animated: true)
            onZoomChanged?(false)
        } else {
            let target = min(maximumZoomScale, minimumZoomScale * 3)
            let point = gr.location(in: imageView)
            let w = bounds.width / target
            let h = bounds.height / target
            zoom(to: CGRect(x: point.x - w / 2, y: point.y - h / 2, width: w, height: h), animated: true)
            onZoomChanged?(true)
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

extension UIImage {
    /// Decode GIF data into an animated UIImage so a plain
    /// UIImageView animates every frame. UIImage(data:) keeps only
    /// the first frame.
    static func rcqAnimatedGIF(from data: Data) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(src)
        guard count > 1 else {
            return CGImageSourceCreateImageAtIndex(src, 0, nil).map { UIImage(cgImage: $0) }
        }
        var frames: [UIImage] = []
        var total: Double = 0
        for i in 0..<count {
            guard let cg = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            frames.append(UIImage(cgImage: cg))
            let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double)
                ?? 0.1
            total += max(delay, 0.02)
        }
        guard !frames.isEmpty else { return nil }
        return UIImage.animatedImage(with: frames, duration: total)
    }
}

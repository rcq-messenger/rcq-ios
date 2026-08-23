// AVFoundation, not AVKit: this viewer deliberately no longer uses
// `VideoPlayer` / `AVPlayerViewController`. See `AlbumVideoPage`.
import AVFoundation
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

final class AlbumViewerVC: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate,
    UIAdaptivePresentationControllerDelegate
{
    /// ⚠ INTERACTION MODEL SHARED WITH ANDROID (founder item 9b). The
    /// chrome fades out after this long without a touch and comes back on
    /// tap, with the same fade in both directions. Android's viewer holds
    /// the identical pair of numbers - change one, change both.
    static let chromeAutoHideDelay: TimeInterval = 3.0
    static let chromeFadeDuration: TimeInterval = 0.25

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
    private var chromeTimer: Timer?
    /// Distance from the bottom of the screen to the top of the
    /// caption / counter block, so a video page can float its transport
    /// above them instead of on top of them. Recomputed after layout.
    private var videoControlsInset: CGFloat = 0
    /// True while the current photo page is zoomed; dismiss-pan is
    /// suppressed.
    private var currentPageZoomed = false
    /// Only a video page reads `chromeVisible` / `bottomInset`, so a
    /// pure-photo album never has to rebuild its pages on a chrome toggle.
    private lazy var hasVideoItem: Bool = items.contains { $0.kind == .video }

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

        headerHost = UIHostingController(rootView: makeHeader(uin: items[currentIndex].senderUIN))
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

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        scheduleChromeAutoHide()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        cancelChromeAutoHide()
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
        recomputeVideoControlsInset()
    }

    /// How far a video page has to lift its transport so it clears the
    /// caption and the page counter. Read off the LAID-OUT frames rather
    /// than guessed from font metrics, because the caption is up to three
    /// lines of arbitrary text and the counter only exists in a real album.
    private func recomputeVideoControlsInset() {
        guard hasVideoItem, view.bounds.height > 0 else { return }
        let bottom = view.bounds.height
        var top = bottom - view.safeAreaInsets.bottom - 14
        if items.count > 1, counterLabel.frame.height > 0 {
            top = min(top, counterLabel.frame.minY)
        }
        if !(captionLabel.text ?? "").isEmpty, captionLabel.frame.height > 0 {
            top = min(top, captionLabel.frame.minY)
        }
        let inset = max(0, bottom - top) + 10
        guard abs(inset - videoControlsInset) > 0.5 else { return }
        videoControlsInset = inset
        refreshPages()
    }

    /// Push fresh `AlbumPage` values into the hosting controllers.
    /// `@State` inside a page survives this - the view identity does not
    /// change, only its inputs - which is why the decrypted image and the
    /// live `AVPlayer` are not thrown away on a chrome toggle.
    private func refreshPages() {
        for (i, host) in pageHosts.enumerated() {
            host.rootView = makePage(message: items[i], index: i)
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
            chromeVisible: !chromeHidden,
            bottomInset: videoControlsInset,
            onTap: { [weak self] in self?.toggleChrome() },
            onInteraction: { [weak self] in self?.noteInteraction() },
            onZoomChanged: { [weak self] zoomed in
                guard let self, index == self.currentIndex else { return }
                self.currentPageZoomed = zoomed
            }
        )
    }

    private func makeHeader(uin: Int) -> AlbumSenderHeader {
        AlbumSenderHeader(
            uin: uin,
            onOpenProfile: { [weak self] in self?.openProfile(uin: uin) }
        )
    }

    private func updateCounter() {
        counterLabel.text = " \(currentIndex + 1) / \(items.count) "
    }

    /// ⚠ `isHidden` is only about "is there a caption at all". Whether the
    /// chrome is showing rides on `alpha`, because that is what the fade
    /// animates - the two used to be mixed here, so paging to a captioned
    /// photo while the chrome was hidden left the caption permanently
    /// invisible: `isHidden` latched true and the un-hide only ever
    /// restored `alpha`.
    private func updateCaption() {
        let text = items[currentIndex].text.trimmingCharacters(in: .whitespacesAndNewlines)
        captionLabel.text = text
        captionLabel.isHidden = text.isEmpty
        captionLabel.alpha = chromeHidden ? 0 : 1
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
            headerHost.rootView = makeHeader(uin: items[idx].senderUIN)
            refreshPages()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        updateCurrentFromOffset()
        noteInteraction()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        updateCurrentFromOffset()
    }

    // MARK: - chrome

    /// Tap toggles. Showing (re)arms the auto-hide, hiding disarms it, so
    /// the two paths can never leave a stale timer that yanks the chrome
    /// away a beat after the user asked for it.
    private func toggleChrome() {
        setChrome(hidden: !chromeHidden)
    }

    private func setChrome(hidden: Bool) {
        guard hidden != chromeHidden else { return }
        chromeHidden = hidden
        let a: CGFloat = hidden ? 0 : 1
        let hasCaption = !(captionLabel.text ?? "").isEmpty
        UIView.animate(withDuration: Self.chromeFadeDuration, delay: 0, options: [.beginFromCurrentState]) {
            self.closeBlur.alpha = a
            self.saveBlur.alpha = a
            self.headerHost.view.alpha = a
            self.counterLabel.alpha = a
            self.captionLabel.alpha = (hidden || !hasCaption) ? 0 : 1
        }
        // The video transport lives inside the SwiftUI page and fades with
        // the rest, so the page has to be told.
        if hasVideoItem { refreshPages() }
        if hidden { cancelChromeAutoHide() } else { scheduleChromeAutoHide() }
    }

    /// Any touch that is not a chrome toggle: keeps a visible chrome alive
    /// for another full delay, and deliberately does NOT resurrect a hidden
    /// one - swiping to the next photo with the chrome down should stay
    /// down, only a tap brings it back.
    private func noteInteraction() {
        guard !chromeHidden else { return }
        scheduleChromeAutoHide()
    }

    private func scheduleChromeAutoHide() {
        cancelChromeAutoHide()
        chromeTimer = Timer.scheduledTimer(
            withTimeInterval: Self.chromeAutoHideDelay, repeats: false
        ) { [weak self] _ in
            Task { @MainActor in self?.setChrome(hidden: true) }
        }
    }

    private func cancelChromeAutoHide() {
        chromeTimer?.invalidate()
        chromeTimer = nil
    }

    private var chromeAlpha: CGFloat { chromeHidden ? 0 : 1 }

    // MARK: - profile

    /// The sender's name is a link to their card (founder item 9b-c),
    /// presented as a sheet because this viewer is a modal of its own and
    /// has no navigation stack to push onto.
    private func openProfile(uin: Int) {
        cancelChromeAutoHide()
        let isOwn = uin == (AuthService.shared.ownUIN ?? -1)
        var sheetRef: UIViewController?
        let sheet = UIHostingController(
            rootView: AlbumProfileSheet(uin: uin, isOwn: isOwn) { [weak self] in
                sheetRef?.dismiss(animated: true) { self?.profileSheetDidClose() }
            }
        )
        sheetRef = sheet
        sheet.presentationController?.delegate = self
        present(sheet, animated: true)
    }

    /// Swipe-down on the sheet never runs the button's completion.
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        profileSheetDidClose()
    }

    private func profileSheetDidClose() {
        // "Open chat" from the card parks a UIN for the root navigation
        // stack and dismisses itself. Nothing behind us can be seen while
        // this viewer is up, so it has to get out of the way too.
        if AppState.shared.pendingOpenChatUIN != nil {
            onDismiss()
            return
        }
        setChrome(hidden: false)
        scheduleChromeAutoHide()
    }

    // MARK: - dismiss pan

    @objc private func handleDismissPan(_ gr: UIPanGestureRecognizer) {
        let translation = gr.translation(in: view)
        let velocity = gr.velocity(in: view)
        switch gr.state {
        case .began:
            dismissAxis = nil
            noteInteraction()
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
            // Restart the countdown from when the finger LEFT, not from when
            // it landed: a scheduled timer cannot fire while the run loop is
            // in tracking mode, so without this a long drag is followed by
            // the chrome vanishing the instant the user lets go.
            noteInteraction()
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
        noteInteraction()
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
        cancelChromeAutoHide()
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

/// Per-page content. Photo / GIF → zoomable scroll view, video → player
/// layer with our own transport.
struct AlbumPage: View {
    let message: Message
    let isCurrent: Bool
    /// Drives the video transport's fade so it rises and falls with the
    /// close / save / sender chrome instead of on its own schedule.
    let chromeVisible: Bool
    /// Clearance the video transport needs above the caption + counter.
    let bottomInset: CGFloat
    let onTap: () -> Void
    let onInteraction: () -> Void
    let onZoomChanged: (Bool) -> Void

    var body: some View {
        switch message.kind {
        case .photo:
            AlbumImagePage(message: message, onTap: onTap, onZoomChanged: onZoomChanged)
        case .video:
            AlbumVideoPage(
                message: message,
                isCurrent: isCurrent,
                chromeVisible: chromeVisible,
                bottomInset: bottomInset,
                onTap: onTap,
                onInteraction: onInteraction
            )
        default:
            Color.black
        }
    }
}

/// Avatar (or the status flower when there is no picture) + nickname in a
/// material capsule. A plain dot said less than the picture the person chose,
/// and the picture is what makes the header read as "who sent this".
///
/// Tapping it opens that person's card (founder item 9b-c) - but only when
/// `ProfileCardPrivacy` allows it. This viewer is one of the surfaces the
/// setting was written for: send a photo into a group and your name sits
/// over it for everyone in the room. When the card may not be opened the
/// capsule renders identically minus the chevron and does not respond,
/// rather than looking tappable and doing nothing.
private struct AlbumSenderHeader: View {
    let uin: Int
    let onOpenProfile: () -> Void

    var body: some View {
        if canOpenCard {
            Button(action: onOpenProfile) { capsule(chevron: true) }
                .buttonStyle(.plain)
                .accessibilityHint(Text("album.sender.open_profile".localized))
        } else {
            // Hit-testing off so the capsule stops eating the tap that
            // toggles the chrome: the hosting view returns nil when nothing
            // inside accepts the touch, and it falls through to the page.
            capsule(chevron: false)
                .allowsHitTesting(false)
        }
    }

    /// A photo carries only its sender's UIN, so the island's per-viewer
    /// verdict is looked up in the rosters this client already holds.
    /// ⚠ Fails OPEN when nothing knows the answer.
    private var canOpenCard: Bool {
        ProfileCardPrivacy.canOpenCard(
            uin: uin,
            openable: ProfileCardPrivacy.verdict(for: uin),
            myUIN: AuthService.shared.ownUIN,
            isContact: ContactService.shared.contacts.contains { $0.uin == uin }
        )
    }

    private func capsule(chevron: Bool) -> some View {
        let resolved = Self.resolve(uin)
        return HStack(spacing: 6) {
            PersonAvatarView(
                mediaID: resolved.avatarID,
                keyBase64: resolved.avatarKey,
                status: resolved.status,
                host: resolved.host,
                size: 22,
                crossIsland: resolved.host != nil
            )
            Text(resolved.name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
        .contentShape(Capsule())
    }

    private static func resolve(
        _ uin: Int
    ) -> (name: String, status: UserStatus, avatarID: String?, avatarKey: String?, host: String?) {
        if uin == AuthService.shared.ownUIN {
            let nick = AuthService.shared.nickname
            let p = PresenceService.shared
            return (nick.isEmpty ? "UIN \(uin)" : nick, p.status, p.ownAvatarID, p.ownAvatarKey, nil)
        }
        if let c = ContactService.shared.contacts.first(where: { $0.uin == uin }) {
            return (c.nickname, c.status, c.avatarMediaID, c.avatarMediaKey, c.host)
        }
        return ("UIN \(uin)", .offline, nil, nil, nil)
    }
}

/// The sender's card, wrapped for modal presentation. `UserInfoView`
/// expects a navigation stack (it owns a title and a trailing menu) and it
/// dismisses itself through `@Environment(\.dismiss)`, which works out of a
/// sheet; the extra leading Close is there because a sheet over a black
/// fullscreen viewer gives no other visual way back.
private struct AlbumProfileSheet: View {
    let uin: Int
    let isOwn: Bool
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            UserInfoView(uin: uin, isOwn: isOwn)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("common.close".localized, action: onClose)
                    }
                }
        }
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

/// Video page - downloads + decrypts to a temp file, then plays through a
/// bare `AVPlayerLayer` with a transport we draw ourselves.
///
/// ## Why not `VideoPlayer` / `AVPlayerViewController` any more (item 9b)
/// AVKit draws its own transport across the top and bottom of the same
/// rectangle our close / save / sender capsule floats over, so the viewer
/// showed two stacked sets of controls, and AVKit owns every touch inside
/// it, which is exactly why a tap toggled the chrome on a photo and did
/// nothing at all on a video.
///
/// The two ways out were "hide the native controls" and "restructure so
/// they do not collide". Restructuring is not available: our chrome is
/// anchored top by the same requirement that put the sender's name over
/// the picture, and moving it would break both the photo pages and the
/// Android viewer we are keeping identical. So: native controls off. The
/// SwiftUI `VideoPlayer` wrapper exposes no `showsPlaybackControls`, and
/// even `AVPlayerViewController` with controls disabled keeps gesture
/// recognizers and a PiP affordance we would then have to fight, so this
/// drops straight to the player layer. The transport below is part of the
/// chrome, fades on the same timer with the same curve, and leaves the
/// tap to us.
private struct AlbumVideoPage: View {
    let message: Message
    let isCurrent: Bool
    let chromeVisible: Bool
    let bottomInset: CGFloat
    let onTap: () -> Void
    let onInteraction: () -> Void

    @State private var url: URL?
    @State private var player: AVPlayer?
    @State private var preparing = false
    @State private var error = false
    @State private var isPlaying = false
    @State private var elapsed: Double = 0
    @State private var total: Double = 0
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    @State private var timeObserver: Any?

    var body: some View {
        ZStack {
            Color.black
            if let player {
                PlayerLayerContainer(player: player)
            }
            if preparing {
                ProgressView().tint(.white)
            } else if error {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 28)).foregroundColor(.white)
                    Text("media.bubble.failed".localized)
                        .foregroundColor(.white)
                }
            }
            if player != nil {
                transport
                    .opacity(chromeVisible ? 1 : 0)
                    .animation(
                        .easeInOut(duration: AlbumViewerVC.chromeFadeDuration),
                        value: chromeVisible
                    )
                    .allowsHitTesting(chromeVisible)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .task(id: "\(isCurrent)|\(message.mediaID ?? "")") { await prepareIfLookedAt() }
        .onChange(of: isCurrent) { current in
            if current { play() } else { pause() }
        }
        .onDisappear { teardown() }
    }

    // MARK: - transport

    private var transport: some View {
        VStack {
            Spacer()
            Button(action: togglePlayback) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 64, height: 64)
                    .background(.ultraThinMaterial, in: Circle())
                    .environment(\.colorScheme, .dark)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(
                (isPlaying ? "audio.strip.pause" : "audio.strip.play").localized
            ))
            Spacer()
            HStack(spacing: 10) {
                Text(Self.clock(scrubbing ? scrubValue : elapsed))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white)
                    .monospacedDigit()
                Slider(
                    // Clamped: the duration is NaN until the asset loads,
                    // so `elapsed` can briefly sit outside the range.
                    value: Binding(
                        get: { min(max(0, scrubbing ? scrubValue : elapsed), max(total, 0.1)) },
                        set: { scrubValue = $0 }
                    ),
                    in: 0...max(total, 0.1),
                    onEditingChanged: { editing in
                        onInteraction()
                        if editing {
                            scrubbing = true
                        } else {
                            seek(to: scrubValue)
                            scrubbing = false
                        }
                    }
                )
                .tint(.white)
                Text(Self.clock(total))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white)
                    .monospacedDigit()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            // White-on-video is unreadable over a bright frame, and the
            // frame is whatever the sender shot. Same material capsule the
            // close / save / sender chrome already sits on.
            .background(.ultraThinMaterial, in: Capsule())
            .environment(\.colorScheme, .dark)
            .padding(.horizontal, 16)
            .padding(.bottom, bottomInset)
        }
    }

    private static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let s = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: - playback

    private func togglePlayback() {
        onInteraction()
        if isPlaying { pause() } else { play() }
    }

    private func play() {
        guard let player else { return }
        // Restart from the top when the last play ran to the end, instead
        // of a play button that does nothing.
        if total > 0, player.currentTime().seconds >= total - 0.05 {
            player.seek(to: .zero)
        }
        player.play()
        isPlaying = true
    }

    private func pause() {
        player?.pause()
        isPlaying = false
    }

    private func seek(to seconds: Double) {
        player?.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero
        )
        elapsed = seconds
    }

    /// ⚠ A periodic observer must come off before its `AVPlayer` goes away,
    /// so this runs both on teardown AND before `prepare` swaps in a new
    /// player (a `.task(id:)` re-run on a changed mediaID).
    private func detachObserver() {
        if let player, let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
    }

    private func teardown() {
        detachObserver()
        player?.pause()
        isPlaying = false
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    /// Fetch this clip only while it is the page being looked at.
    ///
    /// ⚠⚠ The `isCurrent` half of the task id is the whole point. Every page of
    /// an album is built and added to the scroll view the moment the album
    /// opens, so a task keyed on the media id alone starts a download AND a
    /// decrypt for every clip in the album at once: an album of three long
    /// videos pulls down most of a gigabyte nobody asked for, writes two temp
    /// files per clip, and does it on whatever connection the person is on.
    /// Android's album draws the poster and fetches on the play tap; this
    /// fetches on the swipe, which is the same promise: a clip costs something
    /// only once it is being watched.
    ///
    /// A page already prepared is not fetched twice. The view identity survives
    /// `refreshPages`, so `player` outlives a swipe away and back.
    private func prepareIfLookedAt() async {
        guard isCurrent else { return }
        guard player == nil else {
            play()
            return
        }
        await prepare()
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
        // ⚠ The failure flag is cleared here, not only set below. Swiping away
        // from a page mid-download cancels the fetch, which comes back as a
        // failure and leaves the triangle armed; without this the retry on the
        // way back draws it over a video that played perfectly well.
        await MainActor.run {
            preparing = true
            error = false
        }
        if let local = await MediaService.shared.decryptToFile(mediaID: mediaID, keyBase64: key) {
            let p = AVPlayer(url: local)
            await MainActor.run {
                self.detachObserver()
                self.url = local
                self.player = p
                self.preparing = false
                self.attachObserver(to: p)
                if isCurrent {
                    p.play()
                    self.isPlaying = true
                }
            }
        } else {
            await MainActor.run {
                self.error = true
                self.preparing = false
            }
        }
    }

    /// Four ticks a second is enough for a scrubber and cheap enough not to
    /// matter; the duration is only readable once the asset has loaded, so
    /// it is re-read on every tick until it stops being NaN.
    private func attachObserver(to p: AVPlayer) {
        timeObserver = p.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { time in
            if let d = p.currentItem?.duration.seconds, d.isFinite, d > 0 {
                total = d
            }
            if !scrubbing {
                elapsed = time.seconds.isFinite ? time.seconds : 0
            }
            // Reaching the end leaves AVPlayer paused; keep the glyph honest.
            if total > 0, time.seconds >= total - 0.05 {
                isPlaying = false
            }
        }
    }
}

/// `AVPlayerLayer` in a plain UIView. No AVKit, so no transport chrome and
/// no gesture recognizers competing with ours.
private struct PlayerLayerContainer: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let v = PlayerLayerView()
        v.backgroundColor = .clear
        // ⚠ Touches must pass straight through to SwiftUI. A UIKit child
        // that hit-tests wins over the ancestor's `onTapGesture`, and a
        // video whose tap does nothing is the exact bug item 9b is fixing -
        // there is nothing interactive in a bare player layer anyway.
        v.isUserInteractionEnabled = false
        v.playerLayer.videoGravity = .resizeAspect
        v.playerLayer.player = player
        return v
    }

    func updateUIView(_ uiView: PlayerLayerView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }
}

final class PlayerLayerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
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

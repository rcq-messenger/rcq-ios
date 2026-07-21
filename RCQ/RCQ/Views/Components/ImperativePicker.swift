import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// iOS 26 cascade-dismiss bug: PHPicker hosted in `.sheet` inside a `fullScreenCover`
/// tears down the parent cover on dismiss. Present imperatively on the scene's top VC instead.
@MainActor
enum ImperativePicker {

    static func pickImages(limit: Int, onPick: @escaping ([UIImage]) -> Void) {
        guard let presenter = topViewController() else {
            onPick([])
            return
        }
        var cfg = Self.libraryFreeConfig()
        cfg.filter = .images
        cfg.selectionLimit = limit
        cfg.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: cfg)
        let coord = ImageCoordinator(onPick: onPick)
        picker.delegate = coord
        // delegate is weak; associated object keeps coord alive for picker's lifetime.
        objc_setAssociatedObject(picker, &Self.coordKey, coord, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        presenter.present(picker, animated: true)
    }

    /// Single-selection picker that preserves animated GIFs. Returns
    /// `.gif(data:preview:)` when the underlying file is a GIF,
    /// `.photo(UIImage)` otherwise.
    static func pickPhotoOrGIF(onPick: @escaping (CapturedMedia?) -> Void) {
        guard let presenter = topViewController() else {
            onPick(nil)
            return
        }
        var cfg = Self.libraryFreeConfig()
        cfg.filter = .images
        cfg.selectionLimit = 1
        // `.current` keeps the GIF's animation frames; `.compatible`
        // would re-encode to a single still on some library configs.
        cfg.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: cfg)
        let coord = PhotoOrGIFCoordinator(onPick: onPick)
        picker.delegate = coord
        objc_setAssociatedObject(picker, &Self.coordKey, coord, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        presenter.present(picker, animated: true)
    }

    enum CameraMode { case photo, video, both }

    static func captureFromCamera(mode: CameraMode = .both, onPick: @escaping (CapturedMedia?) -> Void) {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            onPick(nil)
            return
        }
        guard let presenter = topViewController() else {
            onPick(nil)
            return
        }
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.allowsEditing = false
        switch mode {
        case .photo: picker.mediaTypes = [UTType.image.identifier]
        case .video:
            picker.mediaTypes = [UTType.movie.identifier]
            picker.cameraCaptureMode = .video
        case .both:  picker.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
        }
        let coord = CameraCoordinator(onPick: onPick)
        picker.delegate = coord
        objc_setAssociatedObject(picker, &Self.coordKey, coord, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        presenter.present(picker, animated: true)
    }

    /// Mixed photo+video picker. Returned items preserve order; videos
    /// are copied off the system temp URL the same way `pickVideo`
    /// does, so the upload pipeline can safely delete its source.
    static func pickMedia(
        limit: Int,
        onPick: @escaping ([CapturedMedia]) -> Void
    ) {
        guard let presenter = topViewController() else {
            onPick([])
            return
        }
        var cfg = Self.libraryFreeConfig()
        // No filter == show everything in Photos. `.any(of: [.images,
        // .videos])` is supposed to do the same on iOS 15+ but in
        // practice it sometimes silently hides the videos tab on
        // certain library configs / iOS builds, so we just leave the
        // filter unset.
        cfg.selectionLimit = limit
        // `.compatible` for video-friendly transcode; `.current` is
        // image-tuned and can drop video representations entirely.
        cfg.preferredAssetRepresentationMode = .compatible
        let picker = PHPickerViewController(configuration: cfg)
        let coord = MixedCoordinator(onPick: onPick)
        picker.delegate = coord
        objc_setAssociatedObject(picker, &Self.coordKey, coord, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        presenter.present(picker, animated: true)
    }

    static func pickVideo(onPick: @escaping (URL?) -> Void) {
        guard let presenter = topViewController() else {
            onPick(nil)
            return
        }
        var cfg = Self.libraryFreeConfig()
        cfg.filter = .videos
        cfg.selectionLimit = 1
        cfg.preferredAssetRepresentationMode = .compatible
        let picker = PHPickerViewController(configuration: cfg)
        let coord = VideoCoordinator(onPick: onPick)
        picker.delegate = coord
        objc_setAssociatedObject(picker, &Self.coordKey, coord, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        presenter.present(picker, animated: true)
    }

    /// A PHPicker config NOT bound to a `PHPhotoLibrary`. Binding to
    /// `.shared()` makes the picker respect the app's Limited-Access
    /// selection: it then shows ONLY the user's pinned subset plus a
    /// "Select More Photos" prompt, and a fresh grant doesn't refresh
    /// the already-open picker (both reported: "can only pick my 2
    /// allowed photos", "allowing one more needs a re-open"). Without
    /// the binding the picker runs fully out-of-process, needs NO photo
    /// permission, and always shows the entire library. None of our
    /// coordinators read `result.assetIdentifier` (they load bytes via
    /// the itemProvider), so dropping the binding costs nothing.
    private static func libraryFreeConfig() -> PHPickerConfiguration {
        PHPickerConfiguration()
    }

    // MARK: - top VC lookup

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

    private static var coordKey: UInt8 = 0
}

enum CapturedMedia {
    case photo(UIImage)
    case video(URL)
    /// Animated GIF preserved through the picker without JPEG
    /// recompression. `data` is the raw GIF bytes (uploaded as-is by
    /// `MediaService.uploadGIF`); `preview` is the first frame for
    /// pending-row thumbnails. Most consumer sites fall through to the
    /// preview when they don't need animation — only the chat send
    /// path and the inline bubble actually look at `data`.
    case gif(data: Data, preview: UIImage)
}

private final class CameraCoordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    let onPick: (CapturedMedia?) -> Void
    init(onPick: @escaping (CapturedMedia?) -> Void) { self.onPick = onPick }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true) { [onPick] in onPick(nil) }
    }

    func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
        // Copy off the system temp URL — upload pipeline deletes its source.
        if let movieURL = info[.mediaURL] as? URL {
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("rcq-cap-\(UUID().uuidString).\(movieURL.pathExtension)")
            do {
                if FileManager.default.fileExists(atPath: copy.path) {
                    try FileManager.default.removeItem(at: copy)
                }
                try FileManager.default.copyItem(at: movieURL, to: copy)
                picker.dismiss(animated: true) { [onPick] in onPick(.video(copy)) }
            } catch {
                picker.dismiss(animated: true) { [onPick] in onPick(nil) }
            }
            return
        }
        if let image = (info[.editedImage] as? UIImage) ?? (info[.originalImage] as? UIImage) {
            picker.dismiss(animated: true) { [onPick] in onPick(.photo(image)) }
            return
        }
        picker.dismiss(animated: true) { [onPick] in onPick(nil) }
    }
}

private final class PhotoOrGIFCoordinator: NSObject, PHPickerViewControllerDelegate {
    let onPick: (CapturedMedia?) -> Void
    init(onPick: @escaping (CapturedMedia?) -> Void) { self.onPick = onPick }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider else {
            onPick(nil)
            return
        }
        let gifType = UTType.gif.identifier
        if provider.hasItemConformingToTypeIdentifier(gifType) {
            provider.loadDataRepresentation(forTypeIdentifier: gifType) { [onPick] data, _ in
                guard let data, let preview = UIImage(data: data) else {
                    DispatchQueue.main.async { onPick(nil) }
                    return
                }
                DispatchQueue.main.async {
                    onPick(.gif(data: data, preview: preview))
                }
            }
            return
        }
        guard provider.canLoadObject(ofClass: UIImage.self) else {
            onPick(nil)
            return
        }
        provider.loadObject(ofClass: UIImage.self) { [onPick] obj, _ in
            DispatchQueue.main.async {
                if let img = obj as? UIImage {
                    onPick(.photo(img))
                } else {
                    onPick(nil)
                }
            }
        }
    }
}

private final class ImageCoordinator: NSObject, PHPickerViewControllerDelegate {
    let onPick: ([UIImage]) -> Void
    init(onPick: @escaping ([UIImage]) -> Void) { self.onPick = onPick }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard !results.isEmpty else { onPick([]); return }
        var collected: [UIImage] = []
        let group = DispatchGroup()
        for r in results {
            guard r.itemProvider.canLoadObject(ofClass: UIImage.self) else { continue }
            group.enter()
            r.itemProvider.loadObject(ofClass: UIImage.self) { obj, _ in
                if let img = obj as? UIImage { collected.append(img) }
                group.leave()
            }
        }
        group.notify(queue: .main) { [onPick] in onPick(collected) }
    }
}

private final class MixedCoordinator: NSObject, PHPickerViewControllerDelegate {
    let onPick: ([CapturedMedia]) -> Void
    init(onPick: @escaping ([CapturedMedia]) -> Void) { self.onPick = onPick }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard !results.isEmpty else { onPick([]); return }
        let movieType = UTType.movie.identifier
        // Index keeps the user's selection order despite async loads
        // completing in a non-deterministic order.
        var indexed: [(Int, CapturedMedia)] = []
        let lock = NSLock()
        let group = DispatchGroup()
        for (i, r) in results.enumerated() {
            let provider = r.itemProvider
            if provider.hasItemConformingToTypeIdentifier(movieType) {
                group.enter()
                provider.loadFileRepresentation(forTypeIdentifier: movieType) { url, _ in
                    defer { group.leave() }
                    guard let url else { return }
                    let copy = FileManager.default.temporaryDirectory
                        .appendingPathComponent("rcq-pick-\(UUID().uuidString).\(url.pathExtension)")
                    do {
                        if FileManager.default.fileExists(atPath: copy.path) {
                            try FileManager.default.removeItem(at: copy)
                        }
                        try FileManager.default.copyItem(at: url, to: copy)
                        lock.lock(); indexed.append((i, .video(copy))); lock.unlock()
                    } catch {}
                }
            } else if provider.canLoadObject(ofClass: UIImage.self) {
                group.enter()
                provider.loadObject(ofClass: UIImage.self) { obj, _ in
                    defer { group.leave() }
                    if let img = obj as? UIImage {
                        lock.lock(); indexed.append((i, .photo(img))); lock.unlock()
                    }
                }
            }
        }
        group.notify(queue: .main) { [onPick] in
            let ordered = indexed.sorted { $0.0 < $1.0 }.map { $0.1 }
            onPick(ordered)
        }
    }
}

private final class VideoCoordinator: NSObject, PHPickerViewControllerDelegate {
    let onPick: (URL?) -> Void
    init(onPick: @escaping (URL?) -> Void) { self.onPick = onPick }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider else { onPick(nil); return }
        let typeID = UTType.movie.identifier
        guard provider.hasItemConformingToTypeIdentifier(typeID) else { onPick(nil); return }
        provider.loadFileRepresentation(forTypeIdentifier: typeID) { [onPick] url, _ in
            guard let url else { DispatchQueue.main.async { onPick(nil) }; return }
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("rcq-pick-\(UUID().uuidString).\(url.pathExtension)")
            do {
                if FileManager.default.fileExists(atPath: copy.path) {
                    try FileManager.default.removeItem(at: copy)
                }
                try FileManager.default.copyItem(at: url, to: copy)
                DispatchQueue.main.async { onPick(copy) }
            } catch {
                DispatchQueue.main.async { onPick(nil) }
            }
        }
    }
}

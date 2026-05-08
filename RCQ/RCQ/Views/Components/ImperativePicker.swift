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
        var cfg = PHPickerConfiguration(photoLibrary: .shared())
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

    static func pickVideo(onPick: @escaping (URL?) -> Void) {
        guard let presenter = topViewController() else {
            onPick(nil)
            return
        }
        var cfg = PHPickerConfiguration(photoLibrary: .shared())
        cfg.filter = .videos
        cfg.selectionLimit = 1
        cfg.preferredAssetRepresentationMode = .compatible
        let picker = PHPickerViewController(configuration: cfg)
        let coord = VideoCoordinator(onPick: onPick)
        picker.delegate = coord
        objc_setAssociatedObject(picker, &Self.coordKey, coord, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        presenter.present(picker, animated: true)
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

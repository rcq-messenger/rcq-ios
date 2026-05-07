import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// Imperative UIKit-driven launcher for PHPickerViewController.
///
/// SwiftUI's `.sheet { PhotoPicker(...) }` works fine outside a
/// `fullScreenCover`, but on iOS 26 there is a cascade-dismiss
/// bug: when a PHPicker sheet hosted inside a fullScreenCover
/// dismisses (either via `picker.dismiss(...)` or via the binding
/// flipping to false), the system unwinds the modal stack one
/// step too far and tears down the parent fullScreenCover too.
/// Visible to the user as "I sent a photo and the chat
/// disappeared". Wrapping `ChatView` in a `NavigationStack` did
/// not help on iOS 26.
///
/// Workaround: present the picker imperatively via UIKit on the
/// scene's top view controller, completely outside SwiftUI's
/// `.sheet` mechanism. Dismiss is then a plain `dismiss(animated:)`
/// on the picker itself, which iOS handles correctly without
/// touching ancestor SwiftUI presentations.
///
/// API mirrors the SwiftUI wrappers it replaces:
/// `pickImages(limit:)` for PhotoPicker, `pickVideo()` for
/// VideoPicker.
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
        // Anchor the coordinator to the picker's lifetime — we only
        // hold a weak ref via `delegate`, but the coordinator must
        // outlive the picker's last delegate callback. Stash on
        // `presentationController.delegate` won't do (taken by the
        // PHPickerViewController). Use associated objects on the
        // picker so the coord goes away with it.
        objc_setAssociatedObject(picker, &Self.coordKey, coord, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        presenter.present(picker, animated: true)
    }

    /// Launch the system camera for an in-the-moment photo OR video
    /// capture. Uses `UIImagePickerController` (PHPicker has no camera
    /// source). Both modes are exposed in one call so the chat
    /// attachment menu can drop the user into either capture flow.
    /// `.both` lets the user choose still/movie inside the picker.
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

    /// Walk the active scene's window chain to find the top-most
    /// presented view controller. Falls back to the root if no
    /// modal is up.
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

/// Discriminated payload returned by `captureFromCamera` — either a
/// freshly-shot photo or a movie file URL the chat can then upload
/// through the existing photo / video send paths.
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
        // Movie capture lands as a temp URL the system writes to;
        // copy into our own temp dir so the existing video pipeline
        // (which deletes the source after upload) can manage it.
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

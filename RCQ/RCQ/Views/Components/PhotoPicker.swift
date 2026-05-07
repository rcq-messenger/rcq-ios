import PhotosUI
import SwiftUI

/// Thin SwiftUI wrapper over PHPickerViewController. Presented as `.sheet`. Returns
/// up to `selectionLimit` UIImages via the closure.
struct PhotoPicker: UIViewControllerRepresentable {
    let selectionLimit: Int
    let onPick: ([UIImage]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var cfg = PHPickerConfiguration(photoLibrary: .shared())
        cfg.filter = .images
        cfg.selectionLimit = selectionLimit
        cfg.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: cfg)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
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
}

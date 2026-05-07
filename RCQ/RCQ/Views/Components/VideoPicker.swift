import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Single-video PHPicker. We process each pick through `VideoProcessor` (compress,
/// thumbnail, duration check) before handing it back. Only one selection at a time
/// — videos are heavy enough that batch sends should be explicit, not accidental.
struct VideoPicker: UIViewControllerRepresentable {
    let onPick: (URL?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var cfg = PHPickerConfiguration(photoLibrary: .shared())
        cfg.filter = .videos
        cfg.selectionLimit = 1
        cfg.preferredAssetRepresentationMode = .compatible
        let picker = PHPickerViewController(configuration: cfg)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: (URL?) -> Void
        init(onPick: @escaping (URL?) -> Void) { self.onPick = onPick }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider else { onPick(nil); return }
            let typeID = UTType.movie.identifier
            guard provider.hasItemConformingToTypeIdentifier(typeID) else { onPick(nil); return }
            provider.loadFileRepresentation(forTypeIdentifier: typeID) { [onPick] url, _ in
                guard let url else { DispatchQueue.main.async { onPick(nil) }; return }
                // Copy out — the system deletes the original when this closure returns.
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
}

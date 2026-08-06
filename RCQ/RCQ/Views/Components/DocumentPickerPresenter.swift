import UIKit
import UniformTypeIdentifiers

/// Imperative `UIDocumentPicker` wrapper. Matches the pattern used by
/// `UnifiedMediaPickerPresenter` / `ImperativePicker` — walk to the top
/// view controller and present directly, sidestepping the iOS 26 SwiftUI
/// sheet-after-sheet drop.
@MainActor
enum DocumentPickerPresenter {
    struct PickedFile {
        let url: URL
        let fileName: String
        let mime: String
        let sizeBytes: Int
    }

    static func present(
        onPick: @escaping (PickedFile) -> Void,
        onCancel: @escaping () -> Void = {},
    ) {
        guard let top = topViewController() else {
            onCancel()
            return
        }
        // `.item` accepts everything except packages — wide enough for
        // PDFs, docs, archives, plain blobs. We import (copy into the
        // app sandbox) so we own the URL across the upload Task and
        // the security-scoped resource doesn't expire mid-upload.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        let delegate = Delegate(onPick: onPick, onCancel: onCancel)
        picker.delegate = delegate
        // Retain the delegate across the modal lifetime — UIDocumentPicker
        // holds it weakly, so without an extra anchor it'd be deinit-ed
        // before the user taps a file.
        objc_setAssociatedObject(picker, &delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        top.present(picker, animated: true)
    }

    /// Hand a file already on disk to the system so the person can put it
    /// wherever they keep things. Exporting a URL rather than a `FileDocument`
    /// keeps a multi-gigabyte archive out of memory: the file is written first
    /// and only its path is passed here.
    static func presentExport(
        url: URL,
        onDone: @escaping () -> Void = {},
        onCancel: @escaping () -> Void = {},
    ) {
        guard let top = topViewController() else {
            onCancel()
            return
        }
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.shouldShowFileExtensions = true
        let delegate = ExportDelegate(onDone: onDone, onCancel: onCancel)
        picker.delegate = delegate
        objc_setAssociatedObject(picker, &delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        top.present(picker, animated: true)
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

    private final class ExportDelegate: NSObject, UIDocumentPickerDelegate {
        let onDone: () -> Void
        let onCancel: () -> Void

        init(onDone: @escaping () -> Void, onCancel: @escaping () -> Void) {
            self.onDone = onDone
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onDone()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }

    private final class Delegate: NSObject, UIDocumentPickerDelegate {
        let onPick: (PickedFile) -> Void
        let onCancel: () -> Void

        init(onPick: @escaping (PickedFile) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { onCancel(); return }
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? Int) ?? 0
            let name = url.lastPathComponent
            let mime = Self.mime(for: url)
            onPick(PickedFile(url: url, fileName: name, mime: mime, sizeBytes: size))
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }

        private static func mime(for url: URL) -> String {
            // UTType derives the MIME from the file extension. Falls
            // back to a generic "application/octet-stream" for unknown
            // suffixes so the receiver never gets an empty mime.
            let ext = url.pathExtension
            if !ext.isEmpty,
               let type = UTType(filenameExtension: ext),
               let mime = type.preferredMIMEType {
                return mime
            }
            return "application/octet-stream"
        }
    }
}

private var delegateKey: UInt8 = 0

import QuickLook
import SwiftUI
import UIKit

/// Renders a `.file` message — file-type icon + filename + size + tap
/// to download, decrypt, and open via QuickLook. The encrypted blob is
/// fetched lazily on tap (small files preview instantly, big PDFs show
/// the progress ring while downloading). Cached after the first open
/// via `MediaService`'s data cache so re-tap is instant.
///
/// AUDIO is the exception (founder item 9a): a document whose mime is
/// `audio/*` used to hand the whole screen to QuickLook's player. It now
/// plays through `VoicePlayer` - the same owner the voice bubbles use, so
/// a song and a voice note can never overlap - and surfaces in the
/// app-wide `AudioPlayerBar` instead, which survives leaving the chat.
/// QuickLook is still the fallback for a codec `AVAudioPlayer` refuses.
struct FileBubble: View {
    let message: Message
    var maxWidth: CGFloat = 260

    @State private var downloading = false
    @State private var failed = false
    @StateObject private var progress = MediaProgressStore.shared

    private var fileName: String { message.fileName ?? "file" }
    private var mime: String { message.fileMime ?? "application/octet-stream" }
    private var sizeBytes: Int { message.fileSizeBytes ?? 0 }

    private var isUploading: Bool {
        message.mediaID == nil && message.deliveryState == .sending
    }
    private var didFailUpload: Bool {
        message.mediaID == nil && message.deliveryState == .failed
    }

    /// Route this document into the audio strip rather than QuickLook?
    /// Uploads are excluded: there is nothing to fetch yet.
    private var isAudio: Bool {
        guard !isUploading, !didFailUpload else { return false }
        return Self.looksLikeAudio(mime: mime, name: fileName)
    }

    var body: some View {
        Button(action: openTap) {
            HStack(spacing: 12) {
                iconTile
                VStack(alignment: .leading, spacing: 3) {
                    Text(fileName)
                        .font(.system(.subheadline, weight: .medium))
                        .foregroundColor(Theme.Color.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        Text(Self.formatSize(sizeBytes))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(Theme.Color.textMono)
                        if let ext = Self.shortExt(for: fileName) {
                            Text("·")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundColor(Theme.Color.textMono)
                            Text(ext.uppercased())
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundColor(Theme.Color.textMono)
                                .tracking(1.2)
                        }
                    }
                    if isAudio {
                        AudioFileProgressLine(messageID: message.id)
                    }
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isUploading || didFailUpload)
    }

    @ViewBuilder
    private var iconTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.Color.accent.opacity(0.18))
            if isUploading, let p = progress.value(for: message.id) {
                progressRing(p)
            } else if didFailUpload {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(Theme.Color.statusBusy)
            } else if downloading {
                ProgressView().tint(Theme.Color.accent)
            } else if failed {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Theme.Color.accent)
            } else if isAudio {
                AudioFileGlyph(messageID: message.id)
            } else {
                Image(systemName: Self.glyph(forMime: mime, name: fileName))
                    .font(.system(size: 22, weight: .regular))
                    .foregroundColor(Theme.Color.accent)
            }
        }
        .frame(width: 44, height: 44)
    }

    private func progressRing(_ p: Double) -> some View {
        ZStack {
            Circle()
                .stroke(Theme.Color.accent.opacity(0.25), lineWidth: 3)
                .frame(width: 28, height: 28)
            Circle()
                .trim(from: 0, to: max(0.02, CGFloat(p)))
                .stroke(Theme.Color.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 28, height: 28)
                .animation(.easeOut(duration: 0.2), value: p)
        }
    }

    private func openTap() {
        guard !downloading, !isUploading, !didFailUpload else { return }
        guard message.mediaID != nil else { return }
        if isAudio {
            audioTap()
        } else {
            quickLookTap()
        }
    }

    /// Play / pause through the process-wide owner. The first tap has to
    /// download + decrypt, so the tile spins; every later tap is a plain
    /// toggle with no network.
    private func audioTap() {
        if VoicePlayer.shared.playingMessageID == message.id {
            VoicePlayer.shared.togglePlayPause()
            return
        }
        downloading = true
        failed = false
        Task {
            let outcome = await VoicePlayer.shared.playAudioFile(
                messageID: message.id,
                mediaToken: message.mediaID,
                title: fileName,
                fileExtension: (fileName as NSString).pathExtension
            )
            await MainActor.run {
                downloading = false
                switch outcome {
                case .started:
                    break
                case .unplayable:
                    // Codec AVAudioPlayer will not open, or the blob would
                    // not decrypt: fall through to the old behaviour rather
                    // than leaving the tap dead.
                    quickLookTap()
                case .busy:
                    // A call or an audio room owns the audio. Deliberately
                    // NOT QuickLook - that would play the file over them.
                    break
                }
            }
        }
    }

    private func quickLookTap() {
        guard let raw = message.mediaID else { return }
        let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        let mediaID = parts[0]
        let key = parts[1]
        downloading = true
        failed = false
        Task {
            let data = await MediaService.shared.fetchDecrypted(mediaID: mediaID, keyBase64: key)
            await MainActor.run {
                downloading = false
                if let data {
                    Self.presentQuickLook(data: data, fileName: fileName)
                } else {
                    failed = true
                }
            }
        }
    }

    // MARK: - helpers

    /// Containers `AVAudioPlayer` cannot open at all. Everything else that
    /// declares itself audio gets the strip, and the runtime fallback in
    /// `audioTap` catches whatever this list misses.
    private static let unplayableAudioExtensions: Set<String> = [
        "ogg", "oga", "opus", "wma", "ra", "rm", "mid", "midi", "amr",
    ]

    static func looksLikeAudio(mime: String, name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        if unplayableAudioExtensions.contains(ext) { return false }
        if mime.lowercased().hasPrefix("audio/") { return true }
        return ["mp3", "m4a", "m4b", "aac", "wav", "aif", "aiff", "caf", "alac", "flac", "au"]
            .contains(ext)
    }

    static func formatSize(_ bytes: Int) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: Int64(bytes))
    }

    static func shortExt(for filename: String) -> String? {
        let ext = (filename as NSString).pathExtension
        return ext.isEmpty ? nil : ext
    }

    /// Pick an SF Symbol that hints at the file kind without claiming
    /// it perfectly. Falls back to `doc.fill` so we never ship a
    /// blank tile.
    static func glyph(forMime mime: String, name: String) -> String {
        let lowerMime = mime.lowercased()
        let ext = (name as NSString).pathExtension.lowercased()
        if lowerMime.hasPrefix("application/pdf") || ext == "pdf" {
            return "doc.richtext.fill"
        }
        if lowerMime.hasPrefix("application/zip") || ["zip", "rar", "7z", "tar", "gz"].contains(ext) {
            return "doc.zipper"
        }
        if lowerMime.hasPrefix("text/") || ["txt", "md", "csv", "log"].contains(ext) {
            return "doc.text.fill"
        }
        if lowerMime.contains("word") || ["doc", "docx", "rtf", "pages"].contains(ext) {
            return "doc.fill"
        }
        if lowerMime.contains("sheet") || ["xls", "xlsx", "numbers"].contains(ext) {
            return "tablecells.fill"
        }
        if lowerMime.contains("presentation") || ["ppt", "pptx", "key"].contains(ext) {
            return "rectangle.fill.on.rectangle.fill"
        }
        if lowerMime.hasPrefix("audio/") {
            return "music.note"
        }
        return "doc.fill"
    }

    @MainActor
    private static func presentQuickLook(data: Data, fileName: String) {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rcq-file-preview", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let url = tmpDir.appendingPathComponent(fileName)
        try? data.write(to: url, options: [.atomic])
        QuickLookPresenter.present(url: url)
    }
}

/// Play / pause glyph for an audio document.
///
/// A separate view on purpose: `VoicePlayer` republishes `elapsed` and
/// `progress` twenty times a second, and observing it from `FileBubble`
/// itself would re-render the whole bubble (name, size, icon tile,
/// layout) on every tick for every audio file in the thread. Only this
/// 22pt glyph and the hairline below it pay that cost.
private struct AudioFileGlyph: View {
    let messageID: UUID
    @StateObject private var player = VoicePlayer.shared

    var body: some View {
        let active = player.playingMessageID == messageID
        Image(systemName: active && player.isPlaying ? "pause.fill" : "play.fill")
            .font(.system(size: 18, weight: .semibold))
            .foregroundColor(Theme.Color.accent)
    }
}

/// Hairline under the size row, filled while this file is the one loaded
/// into the player. Zero height when it is not, so a bubble that is not
/// playing keeps exactly the layout it had before item 9a.
private struct AudioFileProgressLine: View {
    let messageID: UUID
    @StateObject private var player = VoicePlayer.shared

    var body: some View {
        if player.playingMessageID == messageID {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.Color.divider)
                    Capsule()
                        .fill(Theme.Color.accent)
                        .frame(width: geo.size.width * CGFloat(player.progress))
                        .animation(.linear(duration: 0.05), value: player.progress)
                }
            }
            .frame(height: 3)
            .padding(.top, 2)
        }
    }
}

/// Reusable QuickLook host. Owns a `QLPreviewController` + data source,
/// kept alive via associated object on the presented VC so the preview
/// survives the Swift closure scope.
@MainActor
enum QuickLookPresenter {
    static func present(url: URL) {
        guard let top = topViewController() else { return }
        let controller = QLPreviewController()
        let source = SingleItemSource(url: url)
        controller.dataSource = source
        objc_setAssociatedObject(controller, &sourceKey, source, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        top.present(controller, animated: true)
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

    private final class SingleItemSource: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as QLPreviewItem
        }
    }
}

private var sourceKey: UInt8 = 0

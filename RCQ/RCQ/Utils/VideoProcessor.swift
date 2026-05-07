import AVFoundation
import UIKit

/// Pre-upload pipeline for outgoing videos:
///   1. Compress to ≤720p H.264 via AVAssetExportSession.
///   2. Extract a JPEG thumbnail from t=0.
///   3. Read duration.
/// Returns the temp URL of the compressed file plus the thumbnail and duration.
/// The caller deletes the temp file after upload completes.
enum VideoProcessor {
    struct Output {
        let url: URL
        let thumbnailB64: String
        let durationSec: Double
        let bytes: Int
    }

    enum Failure: Error, LocalizedError {
        case unreadable
        case exportFailed(String)
        case tooLong(Double)
        case tooLarge(Int)

        var errorDescription: String? {
            switch self {
            case .unreadable: return "This video can't be read."
            case .exportFailed(let msg): return "Compression failed: \(msg)"
            case .tooLong(let s): return "Video is \(Int(s))s — max is 120s."
            case .tooLarge(let b): return "Compressed video is \(b/1024/1024) MB — over the 30 MB limit."
            }
        }
    }

    static let maxDurationSec: Double = 120
    static let maxBytes: Int = 30 * 1024 * 1024

    static func process(sourceURL: URL) async throws -> Output {
        let asset = AVURLAsset(url: sourceURL)
        let durationCM = try await asset.load(.duration)
        let duration = CMTimeGetSeconds(durationCM)
        if duration > maxDurationSec {
            throw Failure.tooLong(duration)
        }

        // Thumbnail at t=0, capped to 320 longest side, JPEG q=0.7.
        let imageGen = AVAssetImageGenerator(asset: asset)
        imageGen.appliesPreferredTrackTransform = true
        imageGen.maximumSize = CGSize(width: 320, height: 320)
        let cg = try imageGen.copyCGImage(at: .zero, actualTime: nil)
        let thumb = UIImage(cgImage: cg)
        let thumbData = thumb.jpegData(compressionQuality: 0.7) ?? Data()
        let thumbB64 = thumbData.base64EncodedString()

        // Compress.
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rcq-out-\(UUID().uuidString).mp4")
        guard let exporter = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPreset1280x720
        ) else {
            throw Failure.exportFailed("no exporter for preset")
        }
        exporter.outputURL = outURL
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true

        await exporter.export()

        if exporter.status == .failed || exporter.status == .cancelled {
            let msg = exporter.error?.localizedDescription ?? "unknown"
            throw Failure.exportFailed(msg)
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: outURL.path)
        let size = (attrs[.size] as? Int) ?? 0
        if size > maxBytes {
            try? FileManager.default.removeItem(at: outURL)
            throw Failure.tooLarge(size)
        }

        return Output(
            url: outURL,
            thumbnailB64: thumbB64,
            durationSec: duration,
            bytes: size
        )
    }
}

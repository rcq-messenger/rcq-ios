import AVFoundation
import SwiftUI
import UIKit

/// Standalone Bug Bounty sheet — surfaced as its OWN row in Settings,
/// next to (not inside) the "About RCQ" entry. Reads as a feature
/// rather than a footnote: contributors get tokens for accepted reports,
/// and the program is the project's only public support / disclosure
/// channel (the security model documents this; see /security on the
/// landing).
///
/// Sections:
///   1. How it works — terse explanation of the bounty model.
///   2. Severity tiers — how the token reward scales with impact.
///   3. Submit — text + attached screenshots / clips. Posts to
///      /reports with context = "bug_bounty" so the admin queue can
///      sort by report-vs-bounty in the same table.
///
/// Attachments ride the standard encrypted /media/upload lane — server
/// stores opaque ciphertext + keys, admin client decrypts locally for
/// review. Reporter pays nothing (free-tier ≤50 MB covers bug-report
/// screenshots and short clips; larger video uploads silently fail
/// the size gate and surface as an error rather than charging jetons).
struct BugBountySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var description: String = ""
    @State private var attachments: [Attachment] = []
    @State private var sending: Bool = false
    @State private var sentOK: Bool = false
    @State private var errorMessage: String?

    /// Hard cap matches the backend's `MAX_REASON_LEN` so a typed-out
    /// report fits in one POST without surprise truncation.
    private static let maxLength: Int = 1000
    /// Min so a careless tap doesn't fire an empty submission.
    private static let minLength: Int = 20
    /// Matches backend `MAX_ATTACHMENTS_PER_REPORT`. Three is the
    /// typical "two screenshots + one screen recording" envelope.
    private static let maxAttachments: Int = 3

    /// In-flight upload state for one picked piece of media. We hold
    /// onto the preview UIImage so the strip renders immediately,
    /// even while the encrypted bytes are still climbing the network.
    private struct Attachment: Identifiable {
        let id = UUID()
        let preview: UIImage
        let mime: String
        var mediaID: String?
        var keyB64: String?
        var size: Int = 0
        var uploading: Bool = true
        var failed: Bool = false
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    howItWorks
                    severityTiers
                    submitForm
                    Text("bug_bounty.disclosure".localized)
                        .font(.caption2)
                        .foregroundColor(Theme.Color.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(20)
            }
            .background(Theme.Color.bgPrimary.ignoresSafeArea())
            .navigationTitle("bug_bounty.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".localized) { dismiss() }
                }
            }
            .alert("bug_bounty.alert.title".localized,
                   isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                   ),
                   actions: { Button("common.ok".localized, role: .cancel) {} },
                   message: { Text(errorMessage ?? "") })
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "ladybug.fill")
                .font(.system(size: 28))
                .foregroundColor(Theme.Color.accent)
                .frame(width: 56, height: 56)
                .background(Theme.Color.accent.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text("bug_bounty.heading".localized)
                    .font(.title3.weight(.semibold))
                    .foregroundColor(Theme.Color.textPrimary)
                Text("bug_bounty.subheading".localized)
                    .font(.caption)
                    .foregroundColor(Theme.Color.textSecondary)
            }
        }
    }

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("bug_bounty.section.how")
            bulletParagraph("bug_bounty.how.b1")
            bulletParagraph("bug_bounty.how.b2")
            bulletParagraph("bug_bounty.how.b3")
            bulletParagraph("bug_bounty.how.b4")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Color.bgSecondary)
        .cornerRadius(8)
    }

    private var severityTiers: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("bug_bounty.section.tiers")
            tierRow(label: "bug_bounty.tier.critical", reward: "10 000", color: .red)
            tierRow(label: "bug_bounty.tier.high",     reward: "3 000",  color: .orange)
            tierRow(label: "bug_bounty.tier.medium",   reward: "500",    color: .yellow)
            tierRow(label: "bug_bounty.tier.low",      reward: "50",     color: Theme.Color.accent)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Color.bgSecondary)
        .cornerRadius(8)
    }

    private func tierRow(label: String, reward: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label.localized)
                .font(.callout)
                .foregroundColor(Theme.Color.textPrimary)
            Spacer()
            // Reward chip — coin sized to match the digit height
            // (was 14pt next to a 17pt body number, looked starved).
            HStack(spacing: 5) {
                ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                    .frame(width: 18, height: 18)
                Text(reward)
                    .font(.system(.callout, weight: .bold).monospacedDigit())
                    .foregroundColor(Theme.Color.textPrimary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.Color.bgPrimary.opacity(0.6))
            .clipShape(Capsule())
        }
    }

    private var submitForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("bug_bounty.section.submit")
            // The "20–1000 characters" hint used to sit here, but the
            // live "N / 1000" counter below the editor already says
            // the same thing — dropped the duplicate.
            ZStack(alignment: .topLeading) {
                if description.isEmpty {
                    Text("bug_bounty.submit.placeholder".localized)
                        .font(.callout)
                        .foregroundColor(Theme.Color.textSecondary.opacity(0.6))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $description)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(minHeight: 140)
                    .foregroundColor(Theme.Color.textPrimary)
            }
            .background(Theme.Color.bgSecondary)
            .cornerRadius(8)
            .onChange(of: description) { _ in
                if description.count > Self.maxLength {
                    description = String(description.prefix(Self.maxLength))
                }
            }

            attachmentsStrip

            HStack {
                Text("\(description.count) / \(Self.maxLength)")
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(Theme.Color.textSecondary)
                Spacer()
                if sentOK {
                    Label("bug_bounty.submit.sent".localized, systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundColor(Theme.Color.accent)
                } else {
                    Button {
                        Task { await submit() }
                    } label: {
                        Text(sending ? "bug_bounty.submit.sending".localized
                                     : "bug_bounty.submit.cta".localized)
                            .font(.system(.body, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .background(canSubmit ? Theme.Color.accent : Theme.Color.divider)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSubmit || sending)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Color.bgSecondary.opacity(0.6))
        .cornerRadius(8)
    }

    private var attachmentsStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "paperclip")
                    .font(.caption)
                    .foregroundColor(Theme.Color.textSecondary)
                Text("bug_bounty.attach.hint".localized)
                    .font(.caption2)
                    .foregroundColor(Theme.Color.textSecondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(attachments) { att in
                        attachmentTile(att)
                    }
                    if attachments.count < Self.maxAttachments {
                        attachButton
                        if UIPasteboard.general.hasImages {
                            pasteButton
                        }
                    }
                }
            }
        }
    }

    /// "Paste screenshot" tile — appears next to the + tile when the
    /// clipboard contains an image. Saves the user a trip to Photos
    /// just to attach a screenshot they already have on copy.
    private var pasteButton: some View {
        Button {
            guard let img = UIPasteboard.general.image else { return }
            let att = Attachment(preview: img, mime: "image/jpeg")
            attachments.append(att)
            Task { await uploadPhoto(img, attachmentID: att.id) }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(Theme.Color.accent)
                Text("bug_bounty.attach.paste".localized)
                    .font(.caption2)
                    .foregroundColor(Theme.Color.accent)
            }
            .frame(width: 72, height: 72)
            .background(Theme.Color.bgSecondary)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.Color.accent.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4]))
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func attachmentTile(_ att: Attachment) -> some View {
        ZStack(alignment: .topTrailing) {
            Image(uiImage: att.preview)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    if att.uploading {
                        ZStack {
                            Color.black.opacity(0.35)
                            ProgressView()
                                .tint(.white)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else if att.failed {
                        ZStack {
                            Color.red.opacity(0.45)
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.white)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            Button {
                attachments.removeAll { $0.id == att.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.6))
                    .padding(2)
            }
            .buttonStyle(.plain)
        }
    }

    private var attachButton: some View {
        Button {
            presentMediaPicker()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(Theme.Color.textSecondary)
                Text("bug_bounty.attach.cta".localized)
                    .font(.caption2)
                    .foregroundColor(Theme.Color.textSecondary)
            }
            .frame(width: 72, height: 72)
            .background(Theme.Color.bgSecondary)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.Color.divider, style: StrokeStyle(lineWidth: 1, dash: [4]))
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func presentMediaPicker() {
        let remaining = max(0, Self.maxAttachments - attachments.count)
        guard remaining > 0 else { return }
        UnifiedMediaPickerPresenter.present(limit: remaining) { picks in
            for pick in picks {
                handlePick(pick)
            }
        }
    }

    private func handlePick(_ pick: CapturedMedia) {
        switch pick {
        case .photo(let img):
            let att = Attachment(preview: img, mime: "image/jpeg")
            attachments.append(att)
            Task { await uploadPhoto(img, attachmentID: att.id) }
        case .gif(let data, let preview):
            let att = Attachment(preview: preview, mime: "image/gif")
            attachments.append(att)
            Task { await uploadGIF(data, attachmentID: att.id) }
        case .video(let url):
            let preview = Self.videoPreview(url: url) ?? UIImage(systemName: "video.fill") ?? UIImage()
            let mime = Self.mimeFor(url: url)
            let att = Attachment(preview: preview, mime: mime)
            attachments.append(att)
            Task { await uploadVideo(url, attachmentID: att.id) }
        }
    }

    private func uploadPhoto(_ image: UIImage, attachmentID: UUID) async {
        do {
            let res = try await MediaService.shared.uploadImage(image)
            applyUploadResult(attachmentID: attachmentID, mediaID: res.mediaID, key: res.keyBase64, size: 0)
        } catch {
            markFailed(attachmentID: attachmentID, error: error)
        }
    }

    private func uploadGIF(_ data: Data, attachmentID: UUID) async {
        do {
            let res = try await MediaService.shared.uploadGIF(data: data)
            applyUploadResult(attachmentID: attachmentID, mediaID: res.mediaID, key: res.keyBase64, size: data.count)
        } catch {
            markFailed(attachmentID: attachmentID, error: error)
        }
    }

    private func uploadVideo(_ url: URL, attachmentID: UUID) async {
        // Free-tier cap: bug-report video should fit in 50 MB.
        // Beyond that we surface an error rather than charge the
        // reporter — they shouldn't pay to report a bug.
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if bytes > MediaService.freeTierBytes {
            markFailed(attachmentID: attachmentID,
                       error: MediaService.Failure.tooLarge(actualBytes: bytes))
            return
        }
        do {
            let res = try await MediaService.shared.uploadFile(at: url, payJetons: 0)
            applyUploadResult(attachmentID: attachmentID, mediaID: res.mediaID, key: res.keyBase64, size: bytes)
        } catch {
            markFailed(attachmentID: attachmentID, error: error)
        }
    }

    private func applyUploadResult(attachmentID: UUID, mediaID: String, key: String, size: Int) {
        guard let idx = attachments.firstIndex(where: { $0.id == attachmentID }) else { return }
        attachments[idx].mediaID = mediaID
        attachments[idx].keyB64 = key
        attachments[idx].size = size
        attachments[idx].uploading = false
        attachments[idx].failed = false
    }

    private func markFailed(attachmentID: UUID, error: Error) {
        guard let idx = attachments.firstIndex(where: { $0.id == attachmentID }) else { return }
        attachments[idx].uploading = false
        attachments[idx].failed = true
        if errorMessage == nil {
            errorMessage = String(format: "bug_bounty.error.attach".localized,
                                  error.localizedDescription)
        }
    }

    private var canSubmit: Bool {
        let textOK = description.trimmingCharacters(in: .whitespacesAndNewlines).count >= Self.minLength
        let attachmentsReady = attachments.allSatisfy { !$0.uploading && !$0.failed }
        return textOK && attachmentsReady
    }

    private func sectionLabel(_ key: String) -> some View {
        Text(key.localized)
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(Theme.Color.textSecondary)
            .textCase(.uppercase)
            .tracking(0.5)
    }

    private func bulletParagraph(_ key: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(Theme.Color.accent).frame(width: 5, height: 5).padding(.top, 7)
            Text(key.localized)
                .font(.callout)
                .foregroundColor(Theme.Color.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func submit() async {
        // Bug-bounty submissions ride the same /reports endpoint as
        // user reports — context tag lets the admin filter the
        // queue. Target is self (server cleanly accepts that for
        // bounty context); the real signal is the body text.
        struct AttachmentBody: Encodable {
            let media_id: String
            let key: String
            let mime: String
            let size: Int
        }
        struct Body: Encodable {
            let target_uin: Int
            let reason: String
            let context: String
            let attachments: [AttachmentBody]
        }
        guard let me = AuthService.shared.ownUIN else {
            errorMessage = "bug_bounty.error.no_identity".localized
            return
        }

        let readyAttachments: [AttachmentBody] = attachments.compactMap { att in
            guard !att.failed,
                  let mediaID = att.mediaID,
                  let key = att.keyB64 else { return nil }
            return AttachmentBody(media_id: mediaID, key: key, mime: att.mime, size: att.size)
        }

        sending = true
        defer { sending = false }
        do {
            struct Out: Decodable { let id: Int }
            let _: Out = try await APIClient.shared.request(
                "POST", "/reports",
                body: Body(
                    target_uin: me,
                    reason: description.trimmingCharacters(in: .whitespacesAndNewlines),
                    context: "bug_bounty",
                    attachments: readyAttachments
                )
            )
            sentOK = true
            description = ""
            attachments = []
        } catch {
            errorMessage = String(format: "bug_bounty.error.generic".localized,
                                  error.localizedDescription)
        }
    }

    private static func videoPreview(url: URL) -> UIImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        if let cg = try? gen.copyCGImage(at: .zero, actualTime: nil) {
            return UIImage(cgImage: cg)
        }
        return nil
    }

    private static func mimeFor(url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mp4": return "video/mp4"
        case "m4v": return "video/x-m4v"
        case "mov": return "video/quicktime"
        default: return "application/octet-stream"
        }
    }
}

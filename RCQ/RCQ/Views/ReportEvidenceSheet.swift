import SwiftUI
import UIKit

/// Report-with-evidence flow for media messages. Differs from
/// `ReportContactSheet` by gating Submit on an explicit moderator-
/// access consent toggle and uploading the decrypted bytes to
/// `POST /reports/with_evidence` for admin review.
/// v1: photos only — video bytes aren't surfaced by MediaService yet.
struct ReportEvidenceSheet: View {
    let message: Message
    let evidenceBytes: Data
    let evidenceMime: String
    let targetUIN: Int
    let targetNickname: String

    @Environment(\.dismiss) private var dismiss
    @State private var reason: String = ""
    @State private var consentAcknowledged: Bool = false
    @State private var sending: Bool = false
    @State private var sentOK: Bool = false
    @State private var errorMessage: String?

    private static let maxLength: Int = 1000
    private static let minLength: Int = 10

    private var canSubmit: Bool {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= Self.minLength
            && consentAcknowledged
            && !sending
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    Text("report_evidence.body".localized)
                        .font(.callout)
                        .foregroundColor(Theme.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    reasonField
                    consentToggle
                    Spacer(minLength: 0)
                }
                .padding(20)
            }
            .background(Theme.Color.bgPrimary.ignoresSafeArea())
            .navigationTitle("report_evidence.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel".localized) { dismiss() }
                }
            }
            .alert(
                "report.alert.title".localized,
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                ),
                actions: { Button("common.ok".localized, role: .cancel) {} },
                message: { Text(errorMessage ?? "") }
            )
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 26))
                .foregroundColor(Theme.Color.statusBusy)
                .frame(width: 52, height: 52)
                .background(Theme.Color.statusBusy.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text("report_evidence.heading".localized)
                    .font(.title3.weight(.semibold))
                    .foregroundColor(Theme.Color.textPrimary)
                HStack(spacing: 4) {
                    Text(targetNickname)
                        .font(.callout)
                        .foregroundColor(Theme.Color.textPrimary)
                    Text(verbatim: "\(targetUIN)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(Theme.Color.textSecondary)
                }
            }
        }
    }

    private var reasonField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("report.reason.label".localized)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Theme.Color.textSecondary)
                .textCase(.uppercase)
                .tracking(0.5)
            ZStack(alignment: .topLeading) {
                if reason.isEmpty {
                    Text("report_evidence.reason.placeholder".localized)
                        .font(.callout)
                        .foregroundColor(Theme.Color.textSecondary.opacity(0.6))
                        .padding(.horizontal, 12).padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $reason)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .frame(minHeight: 140)
                    .foregroundColor(Theme.Color.textPrimary)
            }
            .background(Theme.Color.bgSecondary)
            .cornerRadius(8)
            .onChange(of: reason) { _ in
                if reason.count > Self.maxLength {
                    reason = String(reason.prefix(Self.maxLength))
                }
            }
            HStack {
                Text(verbatim: "\(reason.count) / \(Self.maxLength)")
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(Theme.Color.textSecondary)
                Spacer()
            }
        }
    }

    private var consentToggle: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $consentAcknowledged) {
                Text("report_evidence.consent.toggle".localized)
                    .font(.footnote)
                    .foregroundColor(Theme.Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .tint(Theme.Color.accent)
            HStack {
                if sentOK {
                    Label("report.sent".localized, systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundColor(Theme.Color.accent)
                } else {
                    Spacer()
                    Button {
                        Task { await submit() }
                    } label: {
                        Text(sending ? "report.cta.sending".localized
                                     : "report_evidence.cta.send".localized)
                            .font(.system(.body, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .background(canSubmit ? Theme.Color.statusBusy : Theme.Color.divider)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSubmit)
                }
            }
        }
    }

    private func submit() async {
        struct Out: Decodable { let id: Int }
        sending = true
        defer { sending = false }

        let context = "media"
        let ext: String = {
            switch evidenceMime {
            case "image/jpeg": return "jpg"
            case "image/png":  return "png"
            default:           return "bin"
            }
        }()
        do {
            let _: Out = try await APIClient.shared.multipartUpload(
                path: "reports/with_evidence",
                formFields: [
                    "target_uin": String(targetUIN),
                    "reason": reason.trimmingCharacters(in: .whitespacesAndNewlines),
                    "context": context,
                    "message_id": message.id.uuidString.lowercased(),
                    "consent_acknowledged": "true",
                ],
                fileFieldName: "evidence",
                fileName: "evidence.\(ext)",
                fileMime: evidenceMime,
                fileBytes: evidenceBytes,
            )
            sentOK = true
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            await MainActor.run { dismiss() }
        } catch {
            errorMessage = String(format: "report.error.generic".localized,
                                  error.localizedDescription)
        }
    }
}

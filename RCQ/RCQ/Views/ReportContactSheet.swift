import SwiftUI

/// User-facing report flow. Shown when the long-press preview's
/// "Report" action fires on a contact. Single text-field + submit;
/// posts to /reports with `context = "contact"` so the admin queue
/// can sort by surface where the report originated.
///
/// Sealed-sender means the server can't tie this to a specific
/// message — the report is against the UIN as a whole. The reason
/// text the user types here is the only signal the admin sees.
struct ReportContactSheet: View {
    let targetUIN: Int
    let targetNickname: String
    /// Surface label that lands in the report row's `context` column
    /// — admin uses it to triage by where the report originated.
    /// Defaults to "contact" for legacy call sites that don't pass
    /// a value; UGC surfaces wire their own ("profile", "chat",
    /// "group", "audio_room", "story", "hood", "stranger_mode").
    var context: String = "contact"

    @Environment(\.dismiss) private var dismiss
    @State private var reason: String = ""
    @State private var sending: Bool = false
    @State private var sentOK: Bool = false
    @State private var errorMessage: String?

    private static let maxLength: Int = 1000
    private static let minLength: Int = 10

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    Text("report.body".localized)
                        .font(.callout)
                        .foregroundColor(Theme.Color.textSecondary)

                    reasonField

                    Spacer(minLength: 0)
                }
                .padding(20)
            }
            .background(Theme.Color.bgPrimary.ignoresSafeArea())
            .navigationTitle("report.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel".localized) { dismiss() }
                }
            }
            .alert("report.alert.title".localized,
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
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 26))
                .foregroundColor(Theme.Color.statusBusy)
                .frame(width: 52, height: 52)
                .background(Theme.Color.statusBusy.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text("report.heading".localized)
                    .font(.title3.weight(.semibold))
                    .foregroundColor(Theme.Color.textPrimary)
                HStack(spacing: 4) {
                    Text(targetNickname)
                        .font(.callout)
                        .foregroundColor(Theme.Color.textPrimary)
                    Text(verbatim: "#\(targetUIN)")
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
                    Text("report.reason.placeholder".localized)
                        .font(.callout)
                        .foregroundColor(Theme.Color.textSecondary.opacity(0.6))
                        .padding(.horizontal, 12).padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $reason)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .frame(minHeight: 160)
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
                Text("\(reason.count) / \(Self.maxLength)")
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(Theme.Color.textSecondary)
                Spacer()
                if sentOK {
                    Label("report.sent".localized, systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundColor(Theme.Color.accent)
                } else {
                    Button {
                        Task { await submit() }
                    } label: {
                        Text(sending ? "report.cta.sending".localized
                                     : "report.cta.send".localized)
                            .font(.system(.body, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .background(canSubmit ? Theme.Color.statusBusy : Theme.Color.divider)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSubmit || sending)
                }
            }
        }
    }

    private var canSubmit: Bool {
        reason.trimmingCharacters(in: .whitespacesAndNewlines).count >= Self.minLength
    }

    private func submit() async {
        struct Body: Encodable {
            let target_uin: Int
            let reason: String
            let context: String
        }
        struct Out: Decodable { let id: Int }
        sending = true
        defer { sending = false }
        do {
            let _: Out = try await APIClient.shared.request(
                "POST", "/reports",
                body: Body(
                    target_uin: targetUIN,
                    reason: reason.trimmingCharacters(in: .whitespacesAndNewlines),
                    context: context
                )
            )
            sentOK = true
            // Auto-dismiss after a beat so the user gets confirmation
            // visual + the sheet doesn't sit there awaiting another tap.
            Task {
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                await MainActor.run { dismiss() }
            }
        } catch {
            errorMessage = String(format: "report.error.generic".localized,
                                  error.localizedDescription)
        }
    }
}

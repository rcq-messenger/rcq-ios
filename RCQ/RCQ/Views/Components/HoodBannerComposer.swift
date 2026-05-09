import SwiftUI

struct HoodBannerComposer: View {
    let bucket: String
    @Environment(\.dismiss) private var dismiss
    @StateObject private var svc = HoodBannerService.shared
    @StateObject private var items = ItemsService.shared

    @State private var text: String = ""
    @State private var duration: BannerDuration = .oneDay
    @State private var isAnonymous: Bool = false
    @State private var busy: Bool = false
    @State private var alertMessage: String?
    @State private var showConfirm: Bool = false

    private let textLimit = 200

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 18) {
                        textField
                        durationPicker
                        anonymousToggle
                        warningBlock
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }
            }
            .navigationTitle("hood_banner.composer.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel".localized) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("hood_banner.composer.publish".localized) {
                        showConfirm = true
                    }
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                }
            }
            .alert("hood_banner.alert.title".localized,
                   isPresented: Binding(
                    get: { alertMessage != nil },
                    set: { if !$0 { alertMessage = nil } }),
                   actions: { Button("common.ok".localized, role: .cancel) {} },
                   message: { Text(alertMessage ?? "") })
            .confirmationDialog(
                String(format: "hood_banner.confirm.message".localized, duration.tokens, max(0, items.wallet.tokens - duration.tokens)),
                isPresented: $showConfirm,
                titleVisibility: .visible
            ) {
                Button("hood_banner.confirm.publish".localized) {
                    Task { await submit() }
                }
                Button("common.cancel".localized, role: .cancel) {}
            }
        }
    }

    private var textField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("hood_banner.composer.text_label".localized)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(2)
                .foregroundColor(Theme.Color.textSecondary)
            TextEditor(text: $text)
                .font(.body)
                .foregroundColor(Theme.Color.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 110)
                .background(Theme.Color.bgSecondary)
                .cornerRadius(10)
                .onChange(of: text) { newValue in
                    if newValue.count > textLimit {
                        text = String(newValue.prefix(textLimit))
                    }
                }
            HStack {
                Spacer()
                Text("\(text.count) / \(textLimit)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.Color.textSecondary)
            }
        }
    }

    private var durationPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("hood_banner.composer.duration_label".localized)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(2)
                .foregroundColor(Theme.Color.textSecondary)
            VStack(spacing: 0) {
                ForEach(BannerDuration.allCases) { d in
                    Button {
                        duration = d
                    } label: {
                        HStack {
                            Text(d.label)
                                .font(.callout)
                                .foregroundColor(Theme.Color.textPrimary)
                            Spacer()
                            HStack(spacing: 4) {
                                ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                                    .frame(width: 14, height: 14)
                                Text("\(d.tokens)")
                                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                                    .foregroundColor(Theme.Color.textPrimary)
                            }
                            if duration == d {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(Theme.Color.accent)
                                    .padding(.leading, 4)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if d != BannerDuration.allCases.last {
                        Rectangle()
                            .fill(Theme.Color.divider.opacity(0.4))
                            .frame(height: 0.5)
                            .padding(.leading, 14)
                    }
                }
            }
            .background(Theme.Color.bgSecondary)
            .cornerRadius(10)
        }
    }

    private var anonymousToggle: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $isAnonymous) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("hood_banner.composer.anonymous_label".localized)
                        .font(.callout.weight(.medium))
                        .foregroundColor(Theme.Color.textPrimary)
                    Text("hood_banner.composer.anonymous_hint".localized)
                        .font(.caption)
                        .foregroundColor(Theme.Color.textSecondary)
                }
            }
            .padding(14)
            .background(Theme.Color.bgSecondary)
            .cornerRadius(10)
        }
    }

    private var warningBlock: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundColor(.orange)
            Text("hood_banner.composer.warning".localized)
                .font(.caption)
                .foregroundColor(Theme.Color.textSecondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.orange.opacity(0.10))
        .cornerRadius(10)
    }

    private func submit() async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        busy = true
        defer { busy = false }
        let result = await svc.create(
            bucket: bucket,
            text: trimmed,
            duration: duration,
            isAnonymous: isAnonymous,
        )
        switch result {
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
        case .insufficientTokens(let req, let have):
            alertMessage = String(format: "hood_banner.error.insufficient".localized, req, have)
        case .bucketFull:
            alertMessage = "hood_banner.error.bucket_full".localized
        case .alreadyHaveBanner:
            alertMessage = "hood_banner.error.already_have".localized
        case .cooldown(let s):
            alertMessage = String(format: "hood_banner.error.cooldown".localized, s)
        case .other(let m):
            alertMessage = m
        }
    }
}

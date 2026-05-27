import SwiftUI

/// Compose a new district banner. Text body + duration picker + anon
/// toggle + mock-IAP confirmation. On purchase confirm we forward the
/// `mock-iap-…` receipt string to the server; real StoreKit slot is
/// in `HoodBannerService.create(...)`.
struct HoodBannerComposerSheet: View {
    let bucket: String
    let onPosted: (HoodBanner) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var service = HoodBannerService.shared

    @State private var text: String = ""
    @State private var duration: BannerDuration = .oneDay
    @State private var isAnonymous: Bool = false
    @State private var posting = false
    @State private var error: String?
    @State private var showConfirm = false

    private let textLimit = 500

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ZStack(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("hood.composer.placeholder".localized)
                                .font(.callout)
                                .foregroundColor(Theme.Color.textSecondary.opacity(0.6))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $text)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 110)
                            .onChange(of: text) { v in
                                if v.count > textLimit { text = String(v.prefix(textLimit)) }
                            }
                    }
                    HStack {
                        Text("\(text.count) / \(textLimit)")
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(Theme.Color.textSecondary)
                        Spacer()
                    }
                } header: {
                    Text("hood.composer.text_header".localized)
                }
                .listRowBackground(Theme.Color.bgSecondary)

                Section {
                    Picker("hood.composer.duration".localized, selection: $duration) {
                        ForEach(BannerDuration.allCases) { d in
                            HStack {
                                Text(d.localizedLabel)
                                Spacer()
                                Text(priceLabel(for: d))
                                    .font(.system(.callout, design: .monospaced))
                                    .foregroundColor(Theme.Color.textSecondary)
                            }
                            .tag(d)
                        }
                    }
                    Toggle("hood.composer.anonymous".localized, isOn: $isAnonymous)
                } footer: {
                    Text("hood.composer.footer".localized)
                }
                .listRowBackground(Theme.Color.bgSecondary)

                Section {
                    Button {
                        showConfirm = true
                    } label: {
                        HStack {
                            Image(systemName: "creditcard.fill")
                                .foregroundColor(.white)
                            Text(buyButtonLabel)
                                .foregroundColor(.white)
                            Spacer()
                            if posting {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .tint(.white)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.Color.accent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || posting)
                    if let error {
                        Text(error)
                            .font(.caption2)
                            .foregroundColor(.red)
                    }
                }
                .listRowBackground(Theme.Color.bgSecondary)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Color.bgPrimary.ignoresSafeArea())
            .navigationTitle("hood.composer.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel".localized) { dismiss() }
                }
            }
            .task { await service.fetchPricing() }
            .confirmationDialog(
                confirmTitle,
                isPresented: $showConfirm,
                titleVisibility: .visible
            ) {
                Button(confirmCTA, role: .destructive) {
                    Task { await runPost() }
                }
                Button("common.cancel".localized, role: .cancel) { }
            } message: {
                Text("hood.composer.confirm.body".localized)
            }
        }
    }

    private func priceLabel(for d: BannerDuration) -> String {
        if let p = service.pricing.first(where: { $0.duration == d.rawValue }) {
            return p.priceDisplay
        }
        return d.fallbackDisplay
    }

    private var buyButtonLabel: String {
        String(format: "hood.composer.buy".localized, priceLabel(for: duration))
    }

    private var confirmTitle: String {
        String(format: "hood.composer.confirm.title".localized, duration.localizedLabel, priceLabel(for: duration))
    }

    private var confirmCTA: String {
        String(format: "hood.composer.confirm.cta".localized, priceLabel(for: duration))
    }

    private func runPost() async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        posting = true
        defer { posting = false }
        let mockReceipt = "mock-iap-\(duration.rawValue)-\(Date().timeIntervalSince1970)"
        let result = await service.create(
            bucket: bucket,
            text: trimmed,
            duration: duration,
            isAnonymous: isAnonymous,
            receipt: mockReceipt,
        )
        switch result {
        case .success(let banner):
            onPosted(banner)
            dismiss()
        case .bucketFull:
            error = "hood.composer.error.bucket_full".localized
        case .other(let msg):
            error = msg
        }
    }
}

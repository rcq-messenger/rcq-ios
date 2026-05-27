import PhotosUI
import SwiftUI
import UIKit

/// Compose a new district banner. Text body + photo + duration picker +
/// anon toggle + bottom-of-screen pay capsule (mock IAP for now — real
/// StoreKit slot lives in `HoodBannerService.create(...)`).
struct HoodBannerComposer: View {
    let bucket: String
    @Environment(\.dismiss) private var dismiss
    @StateObject private var svc = HoodBannerService.shared

    @State private var text: String = ""
    @State private var duration: BannerDuration = .oneDay
    @State private var isAnonymous: Bool = false
    @State private var busy: Bool = false
    @State private var alertMessage: String?
    @State private var showConfirm: Bool = false

    @State private var photoItem: PhotosPickerItem?
    @State private var photoImage: UIImage?
    @State private var uploadingPhoto = false
    @State private var uploadedRef: String?  // "mediaID|keyBase64"

    private let textLimit = 200

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(spacing: 18) {
                            textField
                            photoBlock
                            durationPicker
                            anonymousToggle
                            warningBlock
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 12)
                    }
                    publishCapsule
                }
            }
            .navigationTitle("hood_banner.composer.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel".localized) { dismiss() }
                }
            }
            .alert("hood_banner.alert.title".localized,
                   isPresented: Binding(
                    get: { alertMessage != nil },
                    set: { if !$0 { alertMessage = nil } }),
                   actions: { Button("common.ok".localized, role: .cancel) {} },
                   message: { Text(alertMessage ?? "") })
            .confirmationDialog(
                confirmTitle,
                isPresented: $showConfirm,
                titleVisibility: .visible
            ) {
                Button(confirmCTA) {
                    Task { await submit() }
                }
                Button("common.cancel".localized, role: .cancel) {}
            } message: {
                Text("hood_banner.composer.confirm.body".localized)
            }
            .onChange(of: photoItem) { newItem in
                guard let newItem else { return }
                Task { await loadAndUploadPhoto(newItem) }
            }
            .task { await svc.fetchPricing() }
        }
    }

    // MARK: - sections

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

    @ViewBuilder
    private var photoBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("hood_banner.composer.photo_label".localized)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(2)
                .foregroundColor(Theme.Color.textSecondary)
            HStack(spacing: 12) {
                if let img = photoImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 4) {
                        if uploadingPhoto {
                            HStack(spacing: 6) {
                                ProgressView().tint(Theme.Color.textSecondary)
                                Text("hood_banner.composer.photo_uploading".localized)
                                    .font(.caption)
                                    .foregroundColor(Theme.Color.textSecondary)
                            }
                        } else if uploadedRef != nil {
                            Text("hood_banner.composer.photo_attached".localized)
                                .font(.caption)
                                .foregroundColor(Theme.Color.textSecondary)
                        }
                        Button(role: .destructive) {
                            photoImage = nil
                            uploadedRef = nil
                            photoItem = nil
                        } label: {
                            Text("hood_banner.composer.photo_remove".localized)
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                } else {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        HStack(spacing: 8) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 20))
                                .foregroundColor(Theme.Color.accent)
                            Text("hood_banner.composer.photo_pick".localized)
                                .font(.callout.weight(.medium))
                                .foregroundColor(Theme.Color.textPrimary)
                            Spacer()
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity)
                        .background(Theme.Color.bgSecondary)
                        .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                }
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
                            Text(d.localizedLabel)
                                .font(.callout)
                                .foregroundColor(Theme.Color.textPrimary)
                            Spacer()
                            Text(priceLabel(for: d))
                                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                                .foregroundColor(Theme.Color.textPrimary)
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

    private var warningBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.orange)
                Text("hood_banner.composer.warning.title".localized)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Theme.Color.textPrimary)
            }
            Text("hood_banner.composer.warning.body".localized)
                .font(.caption)
                .foregroundColor(Theme.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10))
        .cornerRadius(10)
    }

    // MARK: - bottom CTA capsule

    private var publishCapsule: some View {
        let disabled = text.trimmingCharacters(in: .whitespaces).isEmpty || busy || uploadingPhoto
        return VStack(spacing: 0) {
            Divider().background(Theme.Color.divider)
            Button {
                showConfirm = true
            } label: {
                HStack(spacing: 8) {
                    if busy {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "creditcard.fill")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    Text(String(format: "hood_banner.composer.publish_for".localized,
                                priceLabel(for: duration)))
                        .font(.system(.callout, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(
                    Capsule().fill(disabled
                                   ? Theme.Color.accent.opacity(0.45)
                                   : Theme.Color.accent)
                )
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
        .background(Theme.Color.bgPrimary)
    }

    // MARK: - pricing helpers

    private func priceLabel(for d: BannerDuration) -> String {
        if let p = svc.pricing.first(where: { $0.duration == d.rawValue }) {
            return p.priceDisplay
        }
        return d.fallbackDisplay
    }

    private var confirmTitle: String {
        String(format: "hood.composer.confirm.title".localized,
               duration.localizedLabel, priceLabel(for: duration))
    }

    private var confirmCTA: String {
        String(format: "hood.composer.confirm.cta".localized, priceLabel(for: duration))
    }

    // MARK: - actions

    private func loadAndUploadPhoto(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let img = UIImage(data: data) else { return }
            photoImage = img
            uploadingPhoto = true
            let result = try await MediaService.shared.uploadImage(img)
            uploadedRef = "\(result.mediaID)|\(result.keyBase64)"
            uploadingPhoto = false
        } catch {
            uploadingPhoto = false
            photoImage = nil
            uploadedRef = nil
            alertMessage = error.localizedDescription
        }
    }

    private func submit() async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        busy = true
        defer { busy = false }
        let mockReceipt = "mock-iap-\(duration.rawValue)-\(Date().timeIntervalSince1970)"
        let result = await svc.create(
            bucket: bucket,
            text: trimmed,
            duration: duration,
            isAnonymous: isAnonymous,
            receipt: mockReceipt,
            imageURL: uploadedRef,
            imageThumbURL: uploadedRef,
        )
        switch result {
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
        case .bucketFull:
            alertMessage = "hood_banner.error.bucket_full".localized
        case .other(let m):
            alertMessage = m
        }
    }
}

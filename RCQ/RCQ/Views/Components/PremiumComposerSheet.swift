import SwiftUI

/// Compose-side flow for sending paywalled media. Two-step:
///   1. User enters a token price (1..999_999 — same range as
///      marketplace listings + paid group entry).
///   2. User taps "Photo" or "Video", which dismisses the sheet and
///      hands off to the existing `ImperativePicker` (so we reuse
///      the gallery + camera UX without re-implementing it).
///
/// The picked media + price are forwarded back to ChatView via the
/// `onSendPhoto` / `onSendVideo` callbacks, which route to
/// `ChatViewModel.sendPremiumPhoto` / `sendPremiumVideo`.
struct PremiumComposerSheet: View {
    var onSendPhoto: (UIImage, Int) -> Void
    var onSendVideo: (URL, Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var priceText: String = ""
    /// Locked once a media-pick is in flight so a double-tap on the
    /// Photo / Video buttons doesn't fire two pickers.
    @State private var pickerLaunched: Bool = false

    private static let minPrice: Int = 1
    private static let maxPrice: Int = 999_999

    private var parsedPrice: Int? {
        guard let n = Int(priceText.trimmingCharacters(in: .whitespaces)),
              (Self.minPrice...Self.maxPrice).contains(n) else { return nil }
        return n
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 18) {
                    Text("chat.premium.compose.body".localized)
                        .font(.callout)
                        .foregroundColor(Theme.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                            .frame(width: 22, height: 22)
                        TextField("chat.premium.compose.price_placeholder".localized, text: $priceText)
                            .keyboardType(.numberPad)
                            .font(.system(.title3, weight: .semibold).monospacedDigit())
                            .foregroundColor(Theme.Color.textPrimary)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .background(Theme.Color.bgSecondary)
                    .cornerRadius(8)

                    Text("chat.premium.compose.hint".localized)
                        .font(.caption2)
                        .foregroundColor(Theme.Color.textSecondary)

                    HStack(spacing: 10) {
                        actionButton(
                            label: "chat.premium.compose.pick_photo".localized,
                            systemImage: "photo.fill"
                        ) {
                            launchPhotoPicker()
                        }
                        actionButton(
                            label: "chat.premium.compose.pick_video".localized,
                            systemImage: "video.fill"
                        ) {
                            launchVideoPicker()
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(20)
            }
            .navigationTitle("chat.premium.compose.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel".localized) { dismiss() }
                }
            }
        }
    }

    private func actionButton(label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .font(.system(.body, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(parsedPrice != nil ? Theme.Color.accent : Theme.Color.divider)
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .disabled(parsedPrice == nil || pickerLaunched)
    }

    private func launchPhotoPicker() {
        guard let price = parsedPrice, !pickerLaunched else { return }
        pickerLaunched = true
        // Present the picker ON TOP of this sheet — `ImperativePicker`
        // walks to the current top view controller (which IS this
        // sheet's host) and presents from there. The earlier "dismiss
        // first, then present" approach raced the sheet's slide-out
        // animation: `topViewController()` returned the sheet's VC
        // mid-tear-down and the picker silently failed to mount.
        // Hosting the picker on the sheet keeps a valid presenter
        // for the whole flow; we only dismiss the sheet AFTER the
        // picker returns a result (or the user cancelled).
        ImperativePicker.pickImages(limit: 1) { images in
            if let img = images.first {
                onSendPhoto(img, price)
            }
            // Cancel or success — either way, fold the composer.
            // Defer one runloop so the picker's own dismiss animation
            // finishes before SwiftUI tears down our hosting sheet
            // (avoids a single-frame double-animation flicker).
            DispatchQueue.main.async { dismiss() }
        }
    }

    private func launchVideoPicker() {
        guard let price = parsedPrice, !pickerLaunched else { return }
        pickerLaunched = true
        ImperativePicker.pickVideo { url in
            if let url {
                onSendVideo(url, price)
            }
            DispatchQueue.main.async { dismiss() }
        }
    }
}

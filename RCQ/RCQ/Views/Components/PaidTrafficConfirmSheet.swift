import SwiftUI

/// Confirmation sheet shown when a user tries to send a video / file
/// that crosses the 50 MB free-tier ceiling, with the
/// `rcq.network.pay_for_large_files` toggle currently OFF.
///
/// User can enable paid traffic in one tap (the toggle flips and
/// the original send retries automatically) or cancel and drop
/// the heavy item from the pending strip.
struct PaidTrafficConfirmSheet: View {
    let plaintextBytes: Int
    let jetonsRequired: Int
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var sizeLabel: String {
        let mb = Double(plaintextBytes) / (1024 * 1024)
        return String(format: "%.1f MB", mb)
    }

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Theme.Color.accent.opacity(0.14))
                    .frame(width: 84, height: 84)
                Image(systemName: "tray.full.fill")
                    .font(.system(size: 36))
                    .foregroundColor(Theme.Color.accent)
            }
            .padding(.top, 24)
            Text("paid_traffic.title".localized)
                .font(.title3.weight(.semibold))
                .foregroundColor(Theme.Color.textPrimary)
            Text(String(format: "paid_traffic.body".localized, sizeLabel))
                .font(.callout)
                .foregroundColor(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 32)
            HStack(spacing: 6) {
                ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                    .frame(width: 22, height: 22)
                Text("\(jetonsRequired)")
                    .font(.system(.title3, design: .monospaced).weight(.bold))
                    .foregroundColor(Theme.Color.textPrimary)
                Text("paid_traffic.price_suffix".localized)
                    .font(.caption)
                    .foregroundColor(Theme.Color.textSecondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Theme.Color.accent.opacity(0.10))
            .clipShape(Capsule())
            Spacer()
            Button {
                // Flip the toggle and re-run the original send. The
                // ChatViewModel's retry closure picks up the new
                // UserDefaults value on its next pass.
                UserDefaults.standard.set(true, forKey: "rcq.network.pay_for_large_files")
                onConfirm()
                dismiss()
            } label: {
                Text("paid_traffic.enable".localized)
                    .font(.body.weight(.semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.Color.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
            Button {
                dismiss()
            } label: {
                Text("paid_traffic.cancel".localized)
                    .font(.callout)
                    .foregroundColor(Theme.Color.textSecondary)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 24)
        }
        .background(Theme.Color.bgPrimary.ignoresSafeArea())
    }
}

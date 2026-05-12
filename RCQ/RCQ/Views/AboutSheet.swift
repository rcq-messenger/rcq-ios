import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// "About RCQ" sheet — tagline + crypto donation addresses with copy + QR.
struct AboutSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var headerLogoAngle: Double = 0

    // Real addresses pending — for now we ship the row layout with
    // empty addresses so it visibly reads as "coming soon" rather
    // than tempting anyone to send funds into the void of a mock
    // string. `DonationRow` swaps the address line for a dash and
    // greys out the copy / QR buttons when `address` is empty.
    private let donations: [DonationAddress] = [
        DonationAddress(ticker: "BTC", network: "Bitcoin", address: "", assetName: "crypto_btc"),
        DonationAddress(ticker: "ETH", network: "Ethereum", address: "", assetName: "crypto_eth"),
        DonationAddress(ticker: "SOL", network: "Solana", address: "", assetName: "crypto_sol"),
        DonationAddress(ticker: "TON", network: "TON", address: "", assetName: "crypto_ton"),
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        Text("about.body".localized)
                            .font(.subheadline)
                            .foregroundColor(Theme.Color.textSecondary)

                        VStack(spacing: 10) {
                            ForEach(donations) { d in
                                DonationRow(donation: d)
                            }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("about.privacy.section".localized).font(.system(size: 11, weight: .bold)).foregroundColor(Theme.Color.textSecondary)
                            bullet("about.privacy.b1".localized)
                            bullet("about.privacy.b2".localized)
                            bullet("about.privacy.b3".localized)
                            bullet("about.privacy.b4".localized)
                            bullet("about.privacy.b5".localized)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.Color.bgSecondary)
                        .cornerRadius(6)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("about.contact.section".localized).font(.system(size: 11, weight: .bold)).foregroundColor(Theme.Color.textSecondary)
                            contactLink(icon: "envelope.fill", label: "about.contact.support".localized, value: "support@rcq.app", url: URL(string: "mailto:support@rcq.app"))
                            contactLink(icon: "globe", label: "about.contact.website".localized, value: "rcq.app", url: URL(string: "https://rcq.app"))
                            contactLink(icon: "questionmark.circle", label: "about.contact.faq".localized, value: "rcq.app/help", url: URL(string: "https://rcq.app/help"))
                            contactLink(icon: "chevron.left.forwardslash.chevron.right", label: "about.contact.github".localized, value: "github.com/rcq-messenger/rcq-ios", url: URL(string: "https://github.com/rcq-messenger/rcq-ios"))
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.Color.bgSecondary)
                        .cornerRadius(6)

                        Text(versionLine)
                            .font(.caption2)
                            .foregroundColor(Theme.Color.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .padding(16)
                }
            }
            .navigationTitle("about.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.close".localized) { dismiss() } }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Group {
                if UIImage(named: "Logo") != nil {
                    Image("Logo").resizable().scaledToFit()
                } else {
                    Image(systemName: "message.circle.fill")
                        .resizable().scaledToFit()
                        .foregroundColor(Theme.Color.accent)
                }
            }
            .frame(width: 48, height: 48)
            .rotationEffect(.degrees(headerLogoAngle))
            .onAppear {
                withAnimation(.linear(duration: 30).repeatForever(autoreverses: false)) {
                    headerLogoAngle = 360
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("RCQ").font(.title.bold()).foregroundColor(Theme.Color.textPrimary)
                Text("about.tagline".localized)
                    .font(.caption)
                    .foregroundColor(Theme.Color.textSecondary)
            }
            Spacer()
        }
    }

    private func contactLink(icon: String, label: String, value: String, url: URL?) -> some View {
        Button {
            if let url, UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(Theme.Color.accent)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(Theme.Color.textPrimary)
                    Text(value)
                        .font(.caption2)
                        .foregroundColor(Theme.Color.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundColor(Theme.Color.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func bullet(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(Theme.Color.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var versionLine: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "RCQ \(v) (\(b))"
    }
}

private struct DonationAddress: Identifiable {
    let ticker: String
    let network: String
    let address: String
    let assetName: String
    var id: String { ticker }
}

private struct DonationRow: View {
    let donation: DonationAddress
    @State private var showQR = false
    @State private var copied = false

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Group {
                    if UIImage(named: donation.assetName) != nil {
                        Image(donation.assetName)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Text(donation.ticker)
                            .font(.system(.caption, weight: .bold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Circle().fill(Theme.Color.accent))
                    }
                }
                .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(donation.network).font(Theme.Font.nickname).foregroundColor(Theme.Color.textPrimary)
                    Text(donation.address.isEmpty ? "—" : truncated(donation.address))
                        .font(Theme.Font.monoSmall)
                        .foregroundColor(Theme.Color.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button {
                    UIPasteboard.general.string = donation.address
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        await MainActor.run { copied = false }
                    }
                } label: {
                    Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                        .foregroundColor(copied ? Theme.Color.accent : Theme.Color.textSecondary)
                        .font(.system(size: 18))
                }
                .disabled(donation.address.isEmpty)
                .opacity(donation.address.isEmpty ? 0.35 : 1)
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showQR.toggle() }
                } label: {
                    Image(systemName: showQR ? "qrcode.viewfinder" : "qrcode")
                        .foregroundColor(Theme.Color.textSecondary)
                        .font(.system(size: 18))
                }
                .disabled(donation.address.isEmpty)
                .opacity(donation.address.isEmpty ? 0.35 : 1)
            }
            if showQR && !donation.address.isEmpty {
                if let img = QRCode.image(from: donation.address) {
                    Image(uiImage: img)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 220, maxHeight: 220)
                        .padding(8)
                        .background(Color.white)
                        .cornerRadius(6)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(12)
        .background(Theme.Color.bgSecondary)
        .cornerRadius(6)
    }

    private func truncated(_ s: String) -> String {
        guard s.count > 24 else { return s }
        let prefix = s.prefix(10)
        let suffix = s.suffix(10)
        return "\(prefix)…\(suffix)"
    }
}

enum QRCode {
    /// Render `text` as a black-on-white QR code. Nil for empty strings.
    static func image(from text: String) -> UIImage? {
        guard !text.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = CGAffineTransform(scaleX: 8, y: 8)
        let scaled = output.transformed(by: scale)
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

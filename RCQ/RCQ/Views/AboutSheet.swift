import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// "About RCQ" sheet — tagline + the four crypto donation addresses with copy
/// buttons and tap-to-expand QR codes. Pure UI, no network. Replace placeholder
/// addresses with real ones before release (search for `REPLACE_` below).
struct AboutSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// Continuous slow rotation on the header logo, same idiom as
    /// BootSplash + onboarding — the mark stays in motion as a
    /// visual signature on every surface where it appears at size.
    @State private var headerLogoAngle: Double = 0

    /// Donation targets. Order is the same as the legacy ICQ "Tip jar" layout —
    /// BTC first because it's the most universal. Addresses below are
    /// **placeholders for layout review** — swap with real receive
    /// addresses before shipping a release build (search for `mock`).
    private let donations: [DonationAddress] = [
        DonationAddress(
            ticker: "BTC", network: "Bitcoin",
            address: "bc1qmockbtc0xreviewlayoutonly1234567890abcd", // mock
            assetName: "crypto_btc"
        ),
        DonationAddress(
            ticker: "ETH", network: "Ethereum",
            address: "0xMockEthereumAddressForLayoutPreview000000",  // mock
            assetName: "crypto_eth"
        ),
        DonationAddress(
            ticker: "SOL", network: "Solana",
            address: "MockSolanaPubkeyLayoutOnlyDoNotSendFunds111", // mock
            assetName: "crypto_sol"
        ),
        DonationAddress(
            ticker: "TON", network: "TON",
            address: "EQMockTonAddressLayoutOnlyDoNotSendFundsHere",  // mock
            assetName: "crypto_ton"
        ),
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

                        // Contact / support block. Placeholder
                        // links — swap before release. Each row
                        // taps through to the matching native
                        // app (Mail / Safari) so the user gets a
                        // pre-filled draft instead of having to
                        // copy the address out by hand.
                        VStack(alignment: .leading, spacing: 8) {
                            Text("about.contact.section".localized).font(.system(size: 11, weight: .bold)).foregroundColor(Theme.Color.textSecondary)
                            contactLink(icon: "envelope.fill", label: "about.contact.support".localized, value: "support@rcq.app", url: URL(string: "mailto:support@rcq.app"))
                            contactLink(icon: "ladybug.fill", label: "about.contact.bug".localized, value: "bugs@rcq.app", url: URL(string: "mailto:bugs@rcq.app?subject=RCQ%20bug%20report"))
                            contactLink(icon: "globe", label: "about.contact.website".localized, value: "rcq.app", url: URL(string: "https://rcq.app"))
                            contactLink(icon: "newspaper", label: "about.contact.updates".localized, value: "@rcqapp", url: URL(string: "https://twitter.com/rcqapp"))
                            contactLink(icon: "questionmark.circle", label: "about.contact.faq".localized, value: "rcq.app/help", url: URL(string: "https://rcq.app/help"))
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

    /// Single contact / support row. Tappable; opens the URL via
    /// the system handler (`mailto:` → Mail, `https://` → Safari).
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
        // No leading bullet glyph — the privacy block is already
        // visually offset by its rounded background, and the
        // green accent dots were reading as a status-online list
        // rather than just plain bullets.
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
    /// Asset-catalog name of the network's logo
    /// (`crypto_btc`/`crypto_eth`/...). Falls back to a circle
    /// with the ticker if the image isn't present in the
    /// bundle.
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
                    Text(truncated(donation.address))
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
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showQR.toggle() }
                } label: {
                    Image(systemName: showQR ? "qrcode.viewfinder" : "qrcode")
                        .foregroundColor(Theme.Color.textSecondary)
                        .font(.system(size: 18))
                }
            }
            if showQR {
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
    /// Render the given string as a black-on-white QR code UIImage. Returns nil if
    /// the string is empty.
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

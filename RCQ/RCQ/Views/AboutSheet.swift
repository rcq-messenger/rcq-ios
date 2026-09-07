import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// "About RCQ" sheet — tagline + privacy summary + contact links.
///
/// Crypto donation rows used to live here. We pulled them for two
/// reasons: (1) App Review reads external-payment links inside a
/// for-profit app as a 5.1.1 / 4.2.7 risk surface, even when the
/// addresses are purely "support the developer"; (2) a serious
/// E2EE messenger doesn't read like one when its About sheet
/// asks for crypto. Real revenue lands via App Store IAP +
/// out-of-band web billing for regions where IAP doesn't work.
struct AboutSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var headerLogoAngle: Double = 0
    // ⚠ The registered-user count used to live here, and it was the one thing
    // on this sheet that is NOT about the app: `/public/stats` counts the
    // people on THIS ISLAND, so on a self-hosted island it was a handful of
    // people presented as the size of RCQ. It moved to Settings' island
    // section, next to the island's own name and host, and the label moved
    // with it (founder, 07.09: "человек в RCQ" reads wrong, it is this island).
    // This sheet keeps its title: version, source, terms and privacy are the
    // app, not the island.

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

                        VStack(alignment: .leading, spacing: 6) {
                            Text("about.privacy.section".localized).font(.system(size: 11, weight: .bold)).foregroundColor(Theme.Color.textSecondary)
                            bullet("about.privacy.b1".localized)
                            bullet("about.privacy.b2".localized)
                            bullet("about.privacy.b3".localized)
                            bullet("about.privacy.b4".localized)
                            bullet("about.privacy.b5".localized)
                            // The islands are the thing nobody arrives
                            // understanding, and this sheet is where people
                            // land when they go looking. One line here, the
                            // depth is a tap away at rcq.app/faq below.
                            bullet("about.privacy.b6".localized)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.Color.bgSecondary)
                        .cornerRadius(6)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("about.contact.section".localized).font(.system(size: 11, weight: .bold)).foregroundColor(Theme.Color.textSecondary)
                            contactLink(icon: "envelope.fill", label: "about.contact.support".localized, value: "support@rcq.app", url: URL(string: "mailto:support@rcq.app"))
                            contactLink(icon: "globe", label: "about.contact.website".localized, value: "rcq.app", url: URL(string: "https://rcq.app"))
                            // ⚠ Was rcq.app/help, which the site has never
                            // served: the router knows /faq and nothing else,
                            // so the one link an confused user taps was a 404.
                            contactLink(icon: "questionmark.circle", label: "about.contact.faq".localized, value: "rcq.app/faq", url: URL(string: "https://rcq.app/faq"))
                            // The two documents a store wants reachable from inside the
                            // app (5.1.1), and the two a person should be able to find
                            // without a search engine (founder, 05.09).
                            contactLink(icon: "hand.raised.fill", label: "about.contact.privacy".localized, value: "rcq.app/privacy", url: URL(string: "https://rcq.app/privacy"))
                            contactLink(icon: "doc.text", label: "about.contact.terms".localized, value: "rcq.app/terms", url: URL(string: "https://rcq.app/terms"))
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
            if let url { InAppBrowser.open(url) }
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

    private var versionLine: String { BuildStamp.line(prefix: "RCQ ") }
}

/// QR helper — still consumed by `QRSheet` for contact-share QRs.
/// Used to live here next to the donation rows that depended on it;
/// the donations are gone but the helper stays.
enum QRCode {
    static func image(from text: String) -> UIImage? {
        guard !text.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

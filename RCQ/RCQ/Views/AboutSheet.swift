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
    /// Real registered-user count from `/public/stats`. nil until the
    /// fetch lands; `displayUserCount` ramps up to it for a count-up.
    @State private var userCount: Int?
    @State private var displayUserCount: Int = 0

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

                        if userCount != nil {
                            userCountCard
                        }

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
            .task { await loadStats() }
        }
    }

    /// "1 234 people on RCQ" badge — a small social-proof card under
    /// the tagline. The number counts up on first appear.
    private var userCountCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 18))
                .foregroundColor(Theme.Color.accent)
                .frame(width: 40, height: 40)
                .background(Theme.Color.accent.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 1) {
                Text(displayUserCount.formatted())
                    .font(.system(.title2, weight: .bold).monospacedDigit())
                    .foregroundColor(Theme.Color.textPrimary)
                    .contentTransition(.numericText())
                Text("about.stats.users".localized)
                    .font(.caption)
                    .foregroundColor(Theme.Color.textSecondary)
            }
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Color.bgSecondary)
        .cornerRadius(6)
    }

    private func loadStats() async {
        struct StatsOut: Decodable { let user_count: Int }
        do {
            let out: StatsOut = try await APIClient.shared.request(
                "GET", "/public/stats", authenticated: false,
            )
            userCount = out.user_count
            // Count-up ramp — ~0.6s from 0 to the real figure.
            let steps = 28
            for i in 1...steps {
                try? await Task.sleep(nanoseconds: 22_000_000)
                withAnimation(.easeOut(duration: 0.1)) {
                    displayUserCount = out.user_count * i / steps
                }
            }
            withAnimation { displayUserCount = out.user_count }
        } catch {
            // Soft-fail — no card if the stat can't be fetched.
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

    private var versionLine: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "RCQ \(v) (\(b))"
    }
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

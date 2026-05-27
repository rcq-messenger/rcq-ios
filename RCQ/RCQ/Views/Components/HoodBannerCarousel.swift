import SwiftUI

/// Horizontal strip of active banners for the caller's current
/// geohash bucket. Caller passes the bucket and presents a composer
/// sheet when the "post" pill is tapped. Tap an existing card to
/// see who posted it (when not anonymous) and the time left.
struct HoodBannerCarousel: View {
    let bucket: String
    let onCompose: () -> Void
    @StateObject private var service = HoodBannerService.shared

    private var banners: [HoodBanner] { service.banners(for: bucket) }
    private var canPost: Bool { service.canPost(in: bucket) }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                composeChip
                ForEach(banners) { b in
                    BannerCard(banner: b, onDelete: {
                        Task { await service.delete(bannerID: b.id, bucket: bucket) }
                    })
                }
            }
            .padding(.horizontal, 14)
        }
        .task(id: bucket) { await service.refresh(bucket: bucket) }
    }

    private var composeChip: some View {
        Button(action: onCompose) {
            VStack(spacing: 4) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(Theme.Color.accent)
                Text("hood.compose".localized)
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(Theme.Color.textPrimary)
            }
            .frame(width: 160, height: 96)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.Color.accent.opacity(0.4), style: StrokeStyle(lineWidth: 1.2, dash: [4]))
            )
            .opacity(canPost ? 1 : 0.5)
        }
        .disabled(!canPost)
    }
}

private struct BannerCard: View {
    let banner: HoodBanner
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: banner.isAnonymous ? "person.fill.questionmark" : "person.crop.circle.fill")
                    .font(.caption2)
                    .foregroundColor(Theme.Color.textSecondary)
                Text(authorLabel)
                    .font(.caption2)
                    .foregroundColor(Theme.Color.textSecondary)
                Spacer()
                if banner.isMine {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.caption2)
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(banner.text)
                .font(.caption)
                .foregroundColor(Theme.Color.textPrimary)
                .multilineTextAlignment(.leading)
                .lineLimit(3)
            Spacer(minLength: 0)
            Text(timeLeft)
                .font(.caption2)
                .foregroundColor(Theme.Color.textSecondary)
        }
        .padding(10)
        .frame(width: 200, height: 96, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.Color.bgSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.Color.divider, lineWidth: 0.5)
        )
    }

    private var authorLabel: String {
        if banner.isAnonymous { return "hood.author.anonymous".localized }
        return banner.ownerNickname ?? "#\(banner.ownerUIN ?? 0)"
    }

    private var timeLeft: String {
        let seconds = Int(banner.expiresAt.timeIntervalSinceNow)
        if seconds <= 0 { return "hood.expired".localized }
        if seconds < 3600 {
            let m = max(1, seconds / 60)
            return String(format: "hood.left_minutes".localized, m)
        }
        if seconds < 86_400 {
            let h = seconds / 3600
            return String(format: "hood.left_hours".localized, h)
        }
        let d = seconds / 86_400
        return String(format: "hood.left_days".localized, d)
    }
}

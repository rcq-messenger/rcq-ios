import SwiftUI

struct HoodBannerDetailSheet: View {
    let banner: HoodBanner
    let bucket: String
    @Environment(\.dismiss) private var dismiss
    @StateObject private var svc = HoodBannerService.shared
    @State private var showFullPhoto: Bool = false
    @State private var alertMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let url = banner.imageURL {
                            Button {
                                showFullPhoto = true
                            } label: {
                                AsyncImage(url: URL(string: url)) { phase in
                                    switch phase {
                                    case .success(let img):
                                        img.resizable().scaledToFit()
                                    default:
                                        Color.black.opacity(0.2).aspectRatio(16/9, contentMode: .fit)
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }

                        Text(banner.text)
                            .font(.body)
                            .foregroundColor(Theme.Color.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)

                        authorBlock
                        metaRow
                        Spacer(minLength: 0)
                    }
                    .padding(20)
                }
            }
            .navigationTitle("hood_banner.detail.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if banner.isMine {
                            Button(role: .destructive) {
                                Task {
                                    await svc.delete(bannerID: banner.id, bucket: bucket)
                                    dismiss()
                                }
                            } label: {
                                Label("hood_banner.detail.delete".localized, systemImage: "trash")
                            }
                        } else {
                            Button(role: .destructive) {
                                Task {
                                    await svc.report(bannerID: banner.id)
                                    alertMessage = "hood_banner.detail.reported".localized
                                }
                            } label: {
                                Label("common.report".localized, systemImage: "flag")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundColor(Theme.Color.textPrimary)
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("common.done".localized) { dismiss() }
                }
            }
            .alert("hood_banner.alert.title".localized,
                   isPresented: Binding(
                    get: { alertMessage != nil },
                    set: { if !$0 { alertMessage = nil } }),
                   actions: { Button("common.ok".localized, role: .cancel) {} },
                   message: { Text(alertMessage ?? "") })
            .fullScreenCover(isPresented: $showFullPhoto) {
                if let url = banner.imageURL {
                    FullPhotoView(url: url)
                }
            }
        }
    }

    @ViewBuilder
    private var authorBlock: some View {
        if banner.isAnonymous {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 22))
                    .foregroundColor(Theme.Color.textSecondary)
                Text("hood_banner.anonymous".localized)
                    .font(.callout)
                    .foregroundColor(Theme.Color.textSecondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Color.bgSecondary)
            .cornerRadius(10)
        } else if let nick = banner.ownerNickname, let uin = banner.ownerUIN {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(nick)
                        .font(.system(.callout, weight: .semibold))
                        .foregroundColor(Theme.Color.textPrimary)
                    Text(verbatim: "#\(uin)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Theme.Color.textSecondary)
                }
                Spacer()
                if !banner.isMine {
                    Button {
                        AppState.shared.pendingAddUIN = uin
                        dismiss()
                    } label: {
                        Text("hood_banner.detail.add_contact".localized)
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Theme.Color.accent)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
            .background(Theme.Color.bgSecondary)
            .cornerRadius(10)
        }
    }

    private var metaRow: some View {
        HStack(spacing: 14) {
            Label(timeLeft, systemImage: "timer")
                .font(.caption)
                .foregroundColor(Theme.Color.textSecondary)
            Spacer()
        }
    }

    private var timeLeft: String {
        let secs = max(0, Int(banner.expiresAt.timeIntervalSinceNow))
        let h = secs / 3600
        let m = (secs % 3600) / 60
        if h >= 24 {
            return String(format: "hood_banner.expires_in_days".localized, h / 24)
        }
        if h > 0 {
            return String(format: "hood_banner.expires_in_hm".localized, h, m)
        }
        return String(format: "hood_banner.expires_in_min".localized, m)
    }
}

private struct FullPhotoView: View {
    let url: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            AsyncImage(url: URL(string: url)) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFit()
                default:
                    ProgressView().tint(.white)
                }
            }
            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                    .padding()
                }
                Spacer()
            }
        }
    }
}

struct HoodBannerBoardSheet: View {
    let bucket: String
    let onSelect: (HoodBanner) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var svc = HoodBannerService.shared

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(svc.banners(for: bucket)) { banner in
                            Button {
                                onSelect(banner)
                            } label: {
                                BoardRow(banner: banner)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("hood_banner.board.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("common.done".localized) { dismiss() }
                }
            }
        }
    }
}

private struct BoardRow: View {
    let banner: HoodBanner

    var body: some View {
        HStack(spacing: 12) {
            if let thumb = banner.imageThumbURL ?? banner.imageURL {
                AsyncImage(url: URL(string: thumb)) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                    default:
                        Color.black.opacity(0.2)
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(banner.text)
                    .font(.system(size: 14))
                    .foregroundColor(Theme.Color.textPrimary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                Text(banner.isAnonymous
                     ? "hood_banner.anonymous".localized
                     : (banner.ownerNickname ?? ""))
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Color.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Theme.Color.bgSecondary)
        .cornerRadius(12)
    }
}

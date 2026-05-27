import SwiftUI
import UIKit

/// Banner detail surface. Owner sees a destructive Delete action;
/// everyone else sees Report, which submits to the generic `/reports`
/// endpoint with `context = "hood_banner"` (the per-banner endpoint
/// was not restored after the pivot).
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
                        if banner.imageURL != nil {
                            Button {
                                showFullPhoto = true
                            } label: {
                                BannerThumbnail(imageRef: banner.imageURL)
                                    .aspectRatio(16/10, contentMode: .fill)
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
                    // `.tint(.red)` wrap so destructive Label glyphs
                    // render red on iOS 26 — Menu otherwise ignores
                    // per-Label foregroundStyle. Same trick used in
                    // UserSafetyMenu elsewhere in the app.
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
                        } else if let _ = banner.ownerUIN {
                            Button(role: .destructive) {
                                Task { await submitReport() }
                            } label: {
                                Label("hood_banner.detail.report".localized, systemImage: "flag")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundColor(Theme.Color.textPrimary)
                    }
                    .tint(.red)
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
                if let ref = banner.imageURL {
                    FullPhotoView(imageRef: ref)
                }
            }
        }
    }

    private func submitReport() async {
        guard let targetUIN = banner.ownerUIN else { return }
        struct Body: Encodable {
            let target_uin: Int
            let reason: String
            let context: String
        }
        struct Out: Decodable { let id: Int }
        do {
            let _: Out = try await APIClient.shared.request(
                "POST", "/reports",
                body: Body(
                    target_uin: targetUIN,
                    reason: "Hood banner: \(banner.text.prefix(160))",
                    context: "hood_banner"
                )
            )
            alertMessage = "hood_banner.detail.reported".localized
        } catch {
            alertMessage = error.localizedDescription
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
    let imageRef: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            BannerThumbnail(imageRef: imageRef)
                .aspectRatio(contentMode: .fit)
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

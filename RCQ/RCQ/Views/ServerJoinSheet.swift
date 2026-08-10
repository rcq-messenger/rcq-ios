import SwiftUI

/// Confirmation sheet for an `rcq://server/<host>?invite=<code>` deep link — the
/// QR/link an operator of an invite-only island shares. Adds the island as a new
/// account (threading the invite token through register for closed servers).
struct ServerJoinSheet: View {
    let request: AppState.ServerJoinRequest
    var onJoined: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var joining = false
    @State private var error: String?
    /// The island's own description, asked of the island. Both fields have been
    /// served forever and shown nowhere, so an operator could name their island
    /// and set house rules that no one could ever read. This is the screen they
    /// are for.
    @State private var info: ServerInfoResponse?

    /// Bare domain from the link → a full https URL the app can register against.
    private var serverURL: String {
        let h = request.host.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("http://") || h.hasPrefix("https://") { return h }
        return "https://\(h)"
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "server.rack")
                .font(.system(size: 34, weight: .light))
                .foregroundColor(Theme.Color.accent)
                .padding(.top, 8)

            Text(info?.name.isEmpty == false ? (info?.name ?? "") : "serverjoin.title".localized)
                .font(.title3.weight(.semibold))
                .foregroundColor(Theme.Color.textPrimary)
                .multilineTextAlignment(.center)

            Text(request.host)
                .font(.callout.weight(.medium))
                .foregroundColor(Theme.Color.accent)
                .lineLimit(1)
                .truncationMode(.middle)

            Text((request.invite == nil ? "serverjoin.body_open" : "serverjoin.body").localized)
                .font(.footnote)
                .foregroundColor(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            // House rules, if the operator wrote any. Scrolls under a cap: a
            // long set is exactly what pushes the buttons off a sheet.
            if let rules = info?.welcome, !rules.isEmpty {
                ScrollView {
                    Text(rules)
                        .font(.footnote)
                        .foregroundColor(Theme.Color.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxHeight: 180)
            }

            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }

            Spacer(minLength: 0)

            Button {
                Task { await join() }
            } label: {
                Group {
                    if joining { ProgressView().tint(.white) }
                    else { Text("serverjoin.join".localized).fontWeight(.semibold) }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Theme.Color.accent)
                .foregroundColor(.white)
                .clipShape(Capsule())
            }
            .disabled(joining)

            Button("common.cancel".localized) { dismiss() }
                .foregroundColor(Theme.Color.textSecondary)
                .disabled(joining)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(Theme.Color.bgPrimary.ignoresSafeArea())
        .presentationDetents([.medium])
        .task {
            // Asked of the island being joined, not of the one we are on.
            info = await ServerInfoService.fetch(host: request.host)
        }
    }

    private func join() async {
        if AccountManager.shared.isAtAccountLimit {
            error = String(format: "add_account.limit".localized, AccountManager.maxAccounts)
            return
        }
        joining = true
        error = nil
        let ok = await AppState.shared.addAccount(serverURL: serverURL, invite: request.invite)
        joining = false
        if !ok {
            error = String(format: "add_account.limit".localized, AccountManager.maxAccounts)
            return
        }
        if AppState.shared.bootError != nil {
            // Register failed (wrong/expired invite, server unreachable). Roll
            // back the dangling account so the user stays on their previous one.
            if let danglingID = AccountManager.shared.activeAccountID,
               AccountManager.shared.accounts.last?.id == danglingID {
                AccountManager.shared.remove(danglingID)
            }
            error = "serverjoin.error".localized
            return
        }
        onJoined()
        dismiss()
    }
}

/// Confirmation sheet for a scanned `rcq://link?t=&k=` QR (connect to web). On
/// confirm it seals THIS account into the one-time relay so chat.rcq.app logs in
/// as the same identity. The blob carries recovery material, so it confirms
/// first — only continue if the user opened the QR on chat.rcq.app themselves.
struct WebLinkSheet: View {
    let request: AppState.WebLinkRequest
    var onClose: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var error: String?
    @State private var done = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "laptopcomputer.and.iphone")
                .font(.system(size: 34, weight: .light))
                .foregroundColor(Theme.Color.accent)
                .padding(.top, 8)

            Text(String(format: "weblink.title".localized, request.clientLabel))
                .font(.title3.weight(.semibold))
                .foregroundColor(Theme.Color.textPrimary)

            Text(done ? "weblink.done".localized : String(format: "weblink.body".localized, request.clientLabel))
                .font(.footnote)
                .foregroundColor(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }

            Spacer(minLength: 0)

            if done {
                Button("common.close".localized) { onClose(); dismiss() }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.Color.accent)
                    .foregroundColor(.white)
                    .clipShape(Capsule())
            } else {
                Button {
                    Task { await connect() }
                } label: {
                    Group {
                        if working { ProgressView().tint(.white) }
                        else { Text("weblink.confirm".localized).fontWeight(.semibold) }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.Color.accent)
                    .foregroundColor(.white)
                    .clipShape(Capsule())
                }
                .disabled(working)

                Button("common.cancel".localized) { onClose(); dismiss() }
                    .foregroundColor(Theme.Color.textSecondary)
                    .disabled(working)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(Theme.Color.bgPrimary.ignoresSafeArea())
        .presentationDetents([.medium])
    }

    private func connect() async {
        working = true
        error = nil
        let ok = await AppState.shared.linkWeb(request)
        working = false
        if ok { done = true } else { error = "weblink.error".localized }
    }
}

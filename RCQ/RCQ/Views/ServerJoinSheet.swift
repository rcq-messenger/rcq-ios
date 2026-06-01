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

            Text("serverjoin.title".localized)
                .font(.title3.weight(.semibold))
                .foregroundColor(Theme.Color.textPrimary)

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

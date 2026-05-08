import CryptoKit
import SwiftUI
import UIKit

/// Generates a one-shot JSON blob the chat.rcq.app web client adopts
/// as its session identity. WARNING: blob carries long-term private
/// keys; anyone with it gets full read-access to v=1 envelopes for the
/// account forever (phase-1 trade-off; phase-2 will move to a per-
/// device-linked identity). Web side enforces a 5-min clock-skew
/// window. Wire shape matches web-chat/src/lib/auth.ts.
struct LinkWebView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var blobJSON: String = ""
    @State private var error: String? = nil
    @State private var copied: Bool = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                VStack(spacing: 16) {
                    instructions
                    Spacer(minLength: 4)
                    actions
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 24)
            }
            .navigationTitle("link_web.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".localized) { dismiss() }
                }
            }
            .onAppear { regenerate() }
        }
    }

    private var instructions: some View {
        VStack(spacing: 10) {
            Image(systemName: "laptopcomputer.and.iphone")
                .font(.system(size: 38))
                .foregroundColor(Theme.Color.accent)
            Text("link_web.instructions.title".localized)
                .font(.system(.headline, weight: .semibold))
                .foregroundColor(Theme.Color.textPrimary)
                .multilineTextAlignment(.center)
            Text("link_web.instructions.body".localized)
                .font(.callout)
                .foregroundColor(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                UIPasteboard.general.string = blobJSON
                UISelectionFeedbackGenerator().selectionChanged()
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if copied { copied = false }
                }
            } label: {
                Label(
                    copied
                        ? "link_web.copied".localized
                        : "link_web.copy_blob".localized,
                    systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc",
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(copied ? Theme.Color.accent : Theme.Color.bgSecondary)
                .foregroundColor(copied ? .white : Theme.Color.textPrimary)
                .cornerRadius(8)
            }
            .disabled(blobJSON.isEmpty)

            Button(action: regenerate) {
                Label("link_web.regenerate".localized, systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .foregroundColor(Theme.Color.textSecondary)
            }

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundColor(Theme.Color.statusBusy)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func regenerate() {
        error = nil
        guard let uin = AuthService.shared.ownUIN,
              let jwt = KeychainStore.string(KeychainStore.Keys.token) else {
            error = "link_web.error.no_identity".localized
            blobJSON = ""
            return
        }
        guard let identityPrivBytes = KeychainStore.data(KeychainStore.Keys.identityPriv),
              let signingPrivBytes = KeychainStore.data(KeychainStore.Keys.signingPriv),
              let identityPriv = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: identityPrivBytes),
              let signingPriv = try? Curve25519.Signing.PrivateKey(rawRepresentation: signingPrivBytes) else {
            error = "link_web.error.keys_missing".localized
            blobJSON = ""
            return
        }
        let apiBase = APIClient.shared.baseURL.absoluteString
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let payload: [String: Any] = [
            "uin": uin,
            "jwt": jwt,
            "api_base": apiBase,
            "identity_priv": identityPrivBytes.base64EncodedString(),
            "identity_pub": identityPriv.publicKey.rawRepresentation.base64EncodedString(),
            "signing_priv": signingPrivBytes.base64EncodedString(),
            "signing_pub": signingPriv.publicKey.rawRepresentation.base64EncodedString(),
            "iat": Int(Date().timeIntervalSince1970),
        ]
        do {
            let json = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.sortedKeys],
            )
            blobJSON = String(data: json, encoding: .utf8) ?? ""
        } catch {
            self.error = "link_web.error.encode_failed".localized
            blobJSON = ""
        }
    }
}

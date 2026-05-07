import CryptoKit
import SwiftUI
import UIKit

/// "Link Web" sheet — generates a one-shot JSON linking blob the
/// chat.rcq.app web client adopts as its session identity. Wire
/// shape (matches `web-chat/src/lib/auth.ts`):
///
/// ```json
/// {
///   "uin": 123456,
///   "jwt": "<bearer token from Keychain>",
///   "api_base": "https://api.rcq.app",
///   "identity_priv": "<base64 raw 32-byte X25519 priv>",
///   "identity_pub":  "<base64 raw 32-byte X25519 pub>",
///   "signing_priv":  "<base64 raw 32-byte Ed25519 priv>",
///   "signing_pub":   "<base64 raw 32-byte Ed25519 pub>",
///   "iat": 1714602000  // unix seconds at issue time
/// }
/// ```
///
/// **Sensitivity.** This blob carries the long-term private keys of
/// the account. Anyone who has it gets full read-access to v=1
/// envelopes addressed to the user *forever* (the keys don't
/// rotate). Phase-1 prototype trade-off; phase-2 (libsignal-WASM)
/// will move to a per-device-linked identity model and obsolete
/// this blob. For now: copy → paste into the web client. The web
/// side enforces a 5-minute clock-skew window — short enough that
/// a stale paste a few minutes later doesn't keep working.
///
/// QR rendering was deliberately removed — desktops can't scan a
/// phone screen with a webcam in any reliable way, so the QR was
/// just visual noise. Copy-to-clipboard is the actual flow.
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

    /// Build the linking blob from local identity material. Failure
    /// modes are surfaced inline — the most common is "Keychain
    /// returned nil for the identity priv" which means the account
    /// was bootstrapped before the keys existed (vanishingly rare).
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

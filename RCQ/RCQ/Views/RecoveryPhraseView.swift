import SwiftUI
import UIKit

/// Settings → "Recovery phrase": shows the active account's 24-word BIP39
/// backup phrase so the user can write it down and restore the account on a
/// fresh device (Android `ui/RecoveryPhraseScreen` parity). The phrase IS the
/// account — anyone who has it owns the identity forever — so it's hidden
/// behind an explicit reveal and fronted by a blunt warning.
///
/// Legacy accounts whose keys predate seed-derivation have no phrase; they get
/// a "not available" notice instead.
struct RecoveryPhraseView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var revealed = false
    @State private var copied = false
    // The phrase grants full account access forever, so re-gate it behind the
    // PIN when one is set — the app being unlocked isn't enough. No PIN = no gate.
    @State private var unlocked = false
    @State private var showPINGate = false
    // Key re-issue (identity rotation).
    @State private var confirmReissue = false
    @State private var rotating = false
    @State private var reissueAlert: String? = nil

    var body: some View {
        // Derived in `body` (a @MainActor context) since AuthService is
        // main-actor isolated; the active account is stable while the sheet
        // is up and the encode is cheap.
        // Seed accounts get a 24-word phrase; legacy (pre-seed) accounts fall
        // back to a 48-word raw-key export. Truly keyless accounts show nothing.
        let phrase = AuthService.shared.recoveryPhrase() ?? AuthService.shared.legacyExportPhrase()
        let needsPIN = PanicPINService.shared.isConfigured && !unlocked
        return NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                if phrase == nil {
                    unavailable
                } else if needsPIN {
                    pinLocked
                } else if let phrase {
                    content(phrase)
                }
            }
            .navigationTitle("recovery.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".localized) { dismiss() }
                }
            }
            .onAppear {
                if phrase != nil, PanicPINService.shared.isConfigured, !unlocked {
                    showPINGate = true
                }
            }
            .sheet(isPresented: $showPINGate) {
                PINVerifySheet(title: "recovery.pin.title".localized) {
                    unlocked = true
                    revealed = true
                }
            }
        }
    }

    private var pinLocked: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 30, weight: .light))
                .foregroundColor(Theme.Color.accent)
            Text("recovery.pin.title".localized)
                .font(.callout)
                .foregroundColor(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                showPINGate = true
            } label: {
                Text("recovery.pin.unlock".localized)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(Theme.Color.accent))
                    .foregroundColor(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(28)
    }

    // MARK: - phrase available

    private func content(_ phrase: [String]) -> some View {
        ScrollView {
            VStack(spacing: 18) {
                warningBanner

                ZStack {
                    grid(phrase)
                        .blur(radius: revealed ? 0 : 9)
                        .disabled(!revealed)
                    if !revealed {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { revealed = true }
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: "eye.fill")
                                    .font(.system(size: 20, weight: .semibold))
                                Text("recovery.reveal".localized)
                                    .font(.callout.weight(.semibold))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 12)
                            .background(Capsule().fill(Theme.Color.accent))
                        }
                        .buttonStyle(.plain)
                    }
                }

                if revealed {
                    Button {
                        UIPasteboard.general.string = phrase.joined(separator: " ")
                        withAnimation { copied = true }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            Text((copied ? "recovery.copied" : "recovery.copy").localized)
                                .fontWeight(.semibold)
                        }
                        .foregroundColor(Theme.Color.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(
                            RoundedRectangle(cornerRadius: 12).fill(Theme.Color.bgSecondary)
                        )
                    }
                    .buttonStyle(.plain)
                }

                reissueSection
            }
            .padding(20)
        }
        .alert("reissue.confirm.title".localized, isPresented: $confirmReissue) {
            Button("reissue.cta".localized, role: .destructive) { performReissue() }
            Button("common.cancel".localized, role: .cancel) {}
        } message: {
            Text("reissue.confirm.body".localized)
        }
        .alert(
            "reissue.title".localized,
            isPresented: Binding(get: { reissueAlert != nil }, set: { if !$0 { reissueAlert = nil } })
        ) {
            Button("common.ok".localized, role: .cancel) {}
        } message: {
            Text(reissueAlert ?? "")
        }
    }

    // MARK: - re-issue (identity rotation)

    private var reissueSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
                .overlay(Theme.Color.textSecondary.opacity(0.2))
                .padding(.vertical, 4)
            Text("reissue.title".localized)
                .font(.callout.weight(.semibold))
                .foregroundColor(Theme.Color.textPrimary)
            Text("reissue.explain".localized)
                .font(.footnote)
                .foregroundColor(Theme.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                confirmReissue = true
            } label: {
                HStack(spacing: 8) {
                    if rotating { ProgressView().tint(.white) }
                    Text((rotating ? "reissue.working" : "reissue.cta").localized)
                        .fontWeight(.semibold)
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange))
            }
            .buttonStyle(.plain)
            .disabled(rotating)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func performReissue() {
        rotating = true
        Task {
            let result = await AuthService.shared.reissueKeys()
            rotating = false
            if result != nil {
                // Keychain now holds the new seed; reveal so `body` re-derives
                // and shows the fresh phrase, and confirm to the user.
                revealed = true
                reissueAlert = "reissue.done".localized
            } else {
                reissueAlert = "reissue.failed".localized
            }
        }
    }

    private var warningBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.system(size: 15, weight: .semibold))
            Text("recovery.warning".localized)
                .font(.footnote)
                .foregroundColor(Theme.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.orange.opacity(0.12))
        )
    }

    private func grid(_ phrase: [String]) -> some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
            spacing: 10
        ) {
            ForEach(Array(phrase.enumerated()), id: \.offset) { idx, word in
                HStack(spacing: 8) {
                    Text(verbatim: "\(idx + 1)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(Theme.Color.textSecondary)
                        .frame(width: 20, alignment: .trailing)
                    Text(word)
                        .font(.system(.callout, design: .monospaced).weight(.medium))
                        .foregroundColor(Theme.Color.textPrimary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 10).fill(Theme.Color.bgSecondary)
                )
            }
        }
    }

    // MARK: - legacy account (no seed)

    private var unavailable: some View {
        VStack(spacing: 14) {
            Image(systemName: "key.slash")
                .font(.system(size: 34, weight: .light))
                .foregroundColor(Theme.Color.textSecondary)
            Text("recovery.unavailable.title".localized)
                .font(.headline)
                .foregroundColor(Theme.Color.textPrimary)
                .multilineTextAlignment(.center)
            Text("recovery.unavailable.body".localized)
                .font(.callout)
                .foregroundColor(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
    }
}

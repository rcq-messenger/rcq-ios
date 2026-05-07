import SwiftUI
import MultipeerConnectivity

/// Entry surface for Radio Chat. Two sections — people-nearby
/// (1:1 candidates) and rooms-nearby (discoverable hosted rooms),
/// plus a "Create room" affordance. Tapping a 1:1 row sends an
/// invite; tapping a room row joins (with password if needed).
/// Acceptance flips to `RadioChatView`.
struct RadioDiscoveryView: View {
    @StateObject private var radio = RadioService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showCreateRoom = false
    @State private var passwordPromptFor: RadioPeer?
    @State private var passwordInput = ""

    /// True when an active radio session has taken over the surface —
    /// `RadioChatView` is rendered inside the same NavigationStack
    /// in that case, and supplies its own toolbar items via
    /// `principalContent` + back chevron + antenna glyph.
    private var inActiveSession: Bool {
        radio.activeOneToOne != nil || radio.activeRoom != nil
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                if radio.activeOneToOne != nil || radio.activeRoom != nil {
                    RadioChatView()
                } else {
                    listSurface
                }
                if let invite = radio.pendingInvite {
                    inviteOverlay(invite)
                }
                if let pending = radio.pendingRoomJoin {
                    joiningOverlay(pending)
                }
            }
            .navigationTitle(inActiveSession ? "" : "radio.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                // Discovery-mode chrome (X close + create-room).
                // RadioChatView injects its own back chevron +
                // principal title + antenna icon when an active
                // session takes over the surface; suppressing
                // these items there keeps the nav bar from
                // doubling up.
                if !inActiveSession {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            // Stop radio explicitly here — `.onDisappear`
                            // can fire spuriously on body re-renders when
                            // `inActiveSession` toggles or sheets present
                            // over the discovery surface, which would
                            // wipe `activeRoom` / `sessionKey` mid-join
                            // and silently downgrade a room session into
                            // a 1:1 fallback.
                            radio.stop()
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(Theme.Color.accent)
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showCreateRoom = true
                        } label: {
                            Image(systemName: "plus")
                                .foregroundColor(Theme.Color.accent)
                        }
                    }
                }
            }
            .task { radio.startDiscovery() }
            // NOTE: don't put `radio.stop()` here. SwiftUI fires
            // `.onDisappear` on this view in spurious cases (body
            // re-renders when `inActiveSession` flips, sheet
            // dismissals, etc.), which would clobber `activeRoom`
            // and `sessionKey` mid-handshake — turning a room join
            // into a 1:1 fallback. Cleanup is owned by the explicit
            // X button (which calls `radio.stop()` then `dismiss()`)
            // and by app-lifecycle handlers if needed.
            .sheet(isPresented: $showCreateRoom) {
                CreateRoomView()
                    .presentationDetents([.medium])
            }
            .sheet(item: $passwordPromptFor) { peer in
                passwordPrompt(for: peer)
                    .presentationDetents([.height(360)])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    // MARK: - List surface

    @ViewBuilder
    private var listSurface: some View {
        let peers = radio.discovered.filter { $0.kind == .oneToOne }
        let rooms = radio.discovered.filter { $0.kind == .room }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                preamble
                if !peers.isEmpty {
                    section("radio.section.people".localized) {
                        ForEach(peers) { peer in
                            row(peer)
                        }
                    }
                }
                if !rooms.isEmpty {
                    section("radio.section.rooms".localized) {
                        ForEach(rooms) { peer in
                            row(peer)
                        }
                    }
                }
                if peers.isEmpty && rooms.isEmpty {
                    emptyState
                }
                if let err = radio.lastError {
                    Text(err)
                        .font(Theme.Font.statusLabel)
                        .foregroundColor(.red)
                        .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
        // Pull-to-refresh — instant ghost-pruning + browser
        // restart. The 12s background timer in RadioService also
        // does this, but the manual gesture closes the gap when a
        // host has just gone dark and the user wants the list
        // clean *now*.
        .refreshable {
            radio.refreshDiscovery()
            // Brief settle so the spinner isn't an instant no-op —
            // gives MC a moment to re-fire foundPeer for the
            // surviving live peers.
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
    }

    private var preamble: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("radio.kicker".localized)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.Color.accent)
                .tracking(2)
            Text("radio.heading".localized)
                .font(.custom("Georgia", size: 22))
                .foregroundColor(Theme.Color.textPrimary)
            Text("radio.subhead".localized)
                .font(.footnote)
                .foregroundColor(Theme.Color.textSecondary)
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.Color.textSecondary)
                .tracking(2)
            VStack(spacing: 8) { content() }
        }
    }

    private func row(_ peer: RadioPeer) -> some View {
        Button {
            tap(peer)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: peer.kind == .room ? "person.3.fill" : "person.fill")
                    .font(.system(size: 18))
                    .foregroundColor(Theme.Color.accent)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(peer.displayName)
                        .font(Theme.Font.nickname)
                        .foregroundColor(Theme.Color.textPrimary)
                    if peer.kind == .room, let r = peer.room, r.needsPassword {
                        HStack(spacing: 4) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 10))
                            Text("radio.password.required".localized)
                                .font(Theme.Font.monoSmall)
                        }
                        .foregroundColor(Theme.Color.textMono)
                    }
                }
                Spacer()
                stateBadge(peer.state)
            }
            .padding(12)
            .background(Theme.Color.bgSecondary)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    private func stateBadge(_ state: RadioPeer.ConnectionState) -> some View {
        let label: String
        let color: Color
        switch state {
        case .discovered:   label = "radio.state.discovered".localized;   color = Theme.Color.accent
        case .inviting:     label = "radio.state.inviting".localized;     color = Theme.Color.accent
        case .connecting:   label = "radio.state.connecting".localized;   color = Theme.Color.accent
        case .connected:    label = "radio.state.connected".localized;    color = Theme.Color.statusOnline
        case .disconnected: label = "radio.state.gone".localized;         color = Theme.Color.textMono
        }
        return Text(label)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(color)
            .tracking(1.5)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            ProgressView().scaleEffect(0.85)
            Text("radio.empty".localized)
                .font(Theme.Font.statusLabel)
                .foregroundColor(Theme.Color.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - Tap handling

    private func tap(_ peer: RadioPeer) {
        switch peer.kind {
        case .oneToOne:
            radio.inviteOneToOne(peer)
        case .room:
            if let r = peer.room, r.needsPassword {
                passwordInput = ""
                passwordPromptFor = peer
            } else {
                radio.joinRoom(peer, password: nil)
            }
        }
    }

    // MARK: - Joining overlay (room password verification in flight)

    /// Modal-ish blocker shown while we wait for the host's first
    /// sealed frame to decrypt under the joiner's derived key.
    /// Resolves into either entry into the chat (key matches) or
    /// a "wrong password" error (key mismatches) — see
    /// `RadioService.pendingRoomJoin`.
    private func joiningOverlay(_ pending: RadioRoomMetadata) -> some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(Theme.Color.accent)
                Text(String(format: "radio.joining".localized, pending.name))
                    .font(.system(.callout, weight: .medium))
                    .foregroundColor(Theme.Color.textPrimary)
                    .multilineTextAlignment(.center)
            }
            .padding(20)
            .frame(width: 240)
            .background(Theme.Color.bgPrimary)
            .cornerRadius(12)
            .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
        }
    }

    // MARK: - Invite overlay

    private func inviteOverlay(_ invite: RadioService.PendingInvite) -> some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            VStack(spacing: 16) {
                Text("radio.invite.heading".localized)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.Color.accent)
                    .tracking(3)
                Text(invite.fromDisplayName)
                    .font(.custom("Georgia", size: 22))
                    .foregroundColor(Theme.Color.textPrimary)
                Text("radio.invite.body".localized)
                    .font(Theme.Font.statusLabel)
                    .foregroundColor(Theme.Color.textSecondary)
                HStack(spacing: 10) {
                    Button {
                        radio.declineInvite(invite)
                    } label: {
                        Text("radio.invite.decline".localized)
                            .font(.system(.body, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .foregroundColor(Theme.Color.textPrimary)
                            .background(Theme.Color.bgSecondary)
                            .cornerRadius(8)
                    }
                    Button {
                        radio.acceptInvite(invite)
                    } label: {
                        Text("radio.invite.accept".localized)
                            .font(.system(.body, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(Theme.Color.accent)
                            .cornerRadius(8)
                    }
                }
            }
            .padding(20)
            .frame(width: 280)
            .background(Theme.Color.bgPrimary)
            .cornerRadius(12)
            .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
        }
    }

    // MARK: - Password prompt

    private func passwordPrompt(for peer: RadioPeer) -> some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                VStack(spacing: 14) {
                    // Centered lock glyph anchors the sheet visually
                    // so a tight detent (~340pt) doesn't leave a
                    // gap of empty bgPrimary above the headline.
                    Image(systemName: "lock.fill")
                        .font(.system(size: 38))
                        .foregroundColor(Theme.Color.accent)
                        .padding(.top, 4)
                    VStack(spacing: 6) {
                        Text("radio.password.required".localized)
                            .font(.title3.bold())
                            .foregroundColor(Theme.Color.textPrimary)
                            .multilineTextAlignment(.center)
                        Text(String(format: "radio.password.body".localized, peer.displayName))
                            .font(.callout)
                            .foregroundColor(Theme.Color.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    SecureField("radio.password.field".localized, text: $passwordInput)
                        .padding(10)
                        .background(Theme.Color.bgSecondary)
                        .cornerRadius(8)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    Button {
                        radio.joinRoom(peer, password: passwordInput)
                        passwordPromptFor = nil
                    } label: {
                        Text("radio.password.cta".localized)
                            .font(.system(.body, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(passwordInput.count >= 6 ? Theme.Color.accent : Theme.Color.divider)
                            .cornerRadius(8)
                    }
                    .disabled(passwordInput.count < 6)
                }
                .padding(20)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { passwordPromptFor = nil } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Theme.Color.accent)
                    }
                }
            }
        }
    }
}

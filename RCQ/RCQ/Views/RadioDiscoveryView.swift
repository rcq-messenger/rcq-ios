import SwiftUI
import MultipeerConnectivity

/// Entry surface for Radio Chat. Sections: nearby people (1:1) and
/// nearby rooms. Tap a 1:1 row to invite, a room row to join.
struct RadioDiscoveryView: View {
    @StateObject private var radio = RadioService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showCreateRoom = false
    @State private var passwordPromptFor: RadioPeer?
    @State private var passwordInput = ""

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
                if !inActiveSession {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            // Explicit stop here: .onDisappear fires on
                            // spurious body re-renders and would clobber
                            // activeRoom/sessionKey mid-join.
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
            // NOTE: do not call radio.stop() in .onDisappear — it fires
            // on spurious body re-renders and would clobber the session
            // mid-handshake. Cleanup is owned by the X button.
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
        // Pull-to-refresh: prune ghosts + restart browser (the 12s
        // background timer does this too, but the gesture is on-demand).
        .refreshable {
            radio.refreshDiscovery()
            // Brief settle so MC can re-fire foundPeer for live peers.
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

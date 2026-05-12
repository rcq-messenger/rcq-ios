import AVKit
import SwiftUI
import WebRTC

/// Full-screen surface for the active audio room. Roster grid + control bar.
/// Tap chevron-down to hand off to `AudioRoomMinimizedBar` while audio keeps
/// streaming via the `audio` UIBackgroundMode.
struct AudioRoomScreen: View {
    @StateObject private var rooms = AudioRoomService.shared
    let initialRoomName: String

    @State private var inspectingPet: PetPreviewTarget?
    @State private var quickActionsTarget: AudioRoomMember?
    @State private var profilePeekUIN: Int?
    @State private var tradeTarget: AudioRoomMember?
    @State private var showRenameSheet: Bool = false
    @State private var renameDraft: String = ""

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                if rooms.isJoining {
                    Spacer()
                    ProgressView("audio_room.screen.joining".localized)
                        .tint(.white)
                        .foregroundColor(.white.opacity(0.8))
                    Spacer()
                } else {
                    rosterGrid
                        .padding(.top, 12)
                    Spacer()
                }
                controlBar
                    .padding(.bottom, 36)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(item: $inspectingPet) { target in
            PetPreviewSheet(pet: target.pet, ownerUIN: target.uin, ownerNickname: target.nickname)
                .preferredColorScheme(.dark)
        }
        .sheet(item: $quickActionsTarget) { member in
            AudioRoomQuickActionsSheet(
                member: member,
                isRoomOwner: rooms.activeRoomID.map { id in
                    rooms.rooms.first(where: { $0.id == id })?.ownerUIN == AuthService.shared.ownUIN
                } ?? false,
                onOpenProfile: {
                    quickActionsTarget = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                        profilePeekUIN = member.uin
                    }
                },
                onTrade: {
                    let target = member
                    quickActionsTarget = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                        tradeTarget = target
                    }
                },
                onKick: {
                    let target = member
                    quickActionsTarget = nil
                    if let id = rooms.activeRoomID {
                        Task { await rooms.kick(roomID: id, uin: target.uin) }
                    }
                },
                onSetMute: { newMuted in
                    let target = member
                    if let id = rooms.activeRoomID {
                        Task { await rooms.muteMember(roomID: id, uin: target.uin, muted: newMuted) }
                    }
                }
            )
            .presentationDetents([.fraction(0.4), .medium])
            .presentationDragIndicator(.visible)
            .preferredColorScheme(.dark)
        }
        .sheet(item: Binding(
            get: { profilePeekUIN.map { ProfilePeekTarget(uin: $0) } },
            set: { if $0 == nil { profilePeekUIN = nil } }
        )) { target in
            NavigationStack {
                UserInfoView(uin: target.uin, isOwn: target.uin == AuthService.shared.ownUIN)
            }
        }
        .sheet(item: $tradeTarget) { target in
            TradeProposeView(recipientUIN: target.uin, recipientNickname: target.nickname)
        }
        .sheet(isPresented: $showRenameSheet) {
            RenameAudioRoomSheet(
                draft: $renameDraft,
                onSave: { newName in
                    showRenameSheet = false
                    if let id = rooms.activeRoomID {
                        Task { await rooms.renameRoom(roomID: id, newName: newName) }
                    }
                },
                onCancel: { showRenameSheet = false }
            )
            .presentationDetents([.height(220)])
            .presentationDragIndicator(.visible)
            .preferredColorScheme(.dark)
        }
    }

    // MARK: - bars

    private var isRoomOwner: Bool {
        guard let id = rooms.activeRoomID,
              let room = rooms.rooms.first(where: { $0.id == id }) else {
            return false
        }
        return room.ownerUIN == AuthService.shared.ownUIN
    }

    private var ownerOnlyActive: Bool {
        guard let id = rooms.activeRoomID,
              let room = rooms.rooms.first(where: { $0.id == id }) else {
            return false
        }
        return room.ownerOnlySpeaking
    }

    // Extracted from topBar to keep the type-checker happy.
    @ViewBuilder
    private var roomTitleBlock: some View {
        let displayName = rooms.activeRoomName ?? initialRoomName
        let listeningLabel = String(format: "audio_room.screen.listening".localized, rooms.roster.count)
        if isRoomOwner {
            Button {
                renameDraft = displayName
                showRenameSheet = true
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(displayName)
                            .font(.headline)
                            .foregroundColor(.white)
                        Image(systemName: "pencil")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    Text(listeningLabel)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            .buttonStyle(.plain)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.headline)
                    .foregroundColor(.white)
                Text(listeningLabel)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                rooms.isMinimized = true
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.15))
                    .clipShape(Circle())
            }
            roomTitleBlock
            Spacer()
            if isRoomOwner {
                Button {
                    if let id = rooms.activeRoomID {
                        let next = !ownerOnlyActive
                        Task { await rooms.setOwnerOnly(roomID: id, enabled: next) }
                    }
                } label: {
                    Image(systemName: ownerOnlyActive ? "mic.slash.circle.fill" : "mic.slash.circle")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(ownerOnlyActive ? .red : .white)
                        .frame(width: 36, height: 36)
                        .background(ownerOnlyActive ? Color.white : Color.white.opacity(0.15))
                        .clipShape(Circle())
                }
                .accessibilityLabel(
                    ownerOnlyActive
                        ? "audio_room.actions.unmute_all".localized
                        : "audio_room.actions.mute_all".localized
                )
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
    }

    private var rosterGrid: some View {
        let members = rooms.roster.values.sorted { $0.uin < $1.uin }
        let columns = [GridItem(.adaptive(minimum: 96, maximum: 140), spacing: 16)]
        return LazyVGrid(columns: columns, spacing: 18) {
            ForEach(members) { m in
                memberTile(m)
            }
        }
        .padding(.horizontal, 20)
    }

    private func memberTile(_ m: AudioRoomMember) -> some View {
        let isMe = m.uin == AuthService.shared.ownUIN
        let isMuted = isMe && rooms.localMuted
        let videoTrack: RTCVideoTrack? = isMe
            ? rooms.localVideoTrack
            : rooms.remoteVideoTracks[m.uin]
        return VStack(spacing: 8) {
            ZStack {
                if let videoTrack {
                    AudioRoomVideoTile(track: videoTrack)
                        .frame(width: 84, height: 84)
                        .clipShape(Circle())
                } else {
                    Circle()
                        .fill(LinearGradient(
                            colors: [Theme.Color.accent, Theme.Color.accent.opacity(0.6)],
                            startPoint: .top, endPoint: .bottom
                        ))
                        .frame(width: 84, height: 84)
                    Text(String(m.nickname.prefix(1)).uppercased())
                        .font(.system(size: 32, weight: .bold))
                        .foregroundColor(.white)
                }
                if m.speaking {
                    Circle()
                        .stroke(Color.green, lineWidth: 3)
                        .frame(width: 92, height: 92)
                }
                if isMuted || m.mutedByOwner {
                    // Owner-mute uses orange so it reads distinct from self-mute (red).
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Image(systemName: "mic.slash.fill")
                                .font(.system(size: 14))
                                .foregroundColor(.white)
                                .padding(6)
                                .background(m.mutedByOwner ? Color.orange : Color.red)
                                .clipShape(Circle())
                                .offset(x: 6, y: 6)
                        }
                    }
                    .frame(width: 84, height: 84)
                }
                if let pet = m.equippedPet {
                    VStack {
                        Spacer()
                        HStack {
                            AudioRoomPetGlyph(pet: pet)
                                .offset(x: -2, y: 4)
                                .onTapGesture {
                                    inspectingPet = PetPreviewTarget(pet: pet, uin: m.uin, nickname: m.nickname)
                                }
                            Spacer()
                        }
                    }
                    .frame(width: 84, height: 84)
                }
            }
            .contentShape(Circle())
            .onTapGesture { handleTileTap(member: m, hasVideo: videoTrack != nil, isMe: isMe) }
            Text(m.nickname)
                .font(.callout)
                .foregroundColor(.white)
                .lineLimit(1)
                .frame(maxWidth: 110)
        }
    }

    private func handleTileTap(member: AudioRoomMember, hasVideo: Bool, isMe: Bool) {
        if isMe {
            if hasVideo { rooms.flipCamera() }
        } else {
            quickActionsTarget = member
        }
    }

    private var controlBar: some View {
        let micLocked: Bool = {
            let mutedByOwner: Bool = {
                guard let ownUIN = AuthService.shared.ownUIN else { return false }
                return rooms.roster[ownUIN]?.mutedByOwner ?? false
            }()
            return mutedByOwner || (ownerOnlyActive && !isRoomOwner)
        }()
        return HStack(spacing: 24) {
            controlButton(
                systemName: rooms.localMuted ? "mic.slash.fill" : "mic.fill",
                active: rooms.localMuted,
                label: "audio_room.control.mute".localized,
                disabled: micLocked
            ) { if !micLocked { rooms.toggleMute() } }

            controlButton(
                systemName: rooms.cameraEnabled ? "video.fill" : "video.slash.fill",
                active: rooms.cameraEnabled,
                label: "audio_room.control.camera".localized
            ) { rooms.toggleCamera() }

            VStack(spacing: 4) {
                AudioRoomRoutePickerButton()
                    .frame(width: 56, height: 56)
                Text("audio_room.control.route".localized)
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.7))
            }

            Button {
                rooms.exit()
            } label: {
                VStack(spacing: 4) {
                    ZStack {
                        Circle().fill(Color.red).frame(width: 56, height: 56)
                        Image(systemName: "phone.down.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.white)
                    }
                    Text("audio_room.control.leave".localized)
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.7))
                }
            }
        }
    }

    private func controlButton(systemName: String, active: Bool, label: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    Circle()
                        .fill(active ? Color.white : Color.white.opacity(0.15))
                        .frame(width: 56, height: 56)
                    Image(systemName: systemName)
                        .font(.system(size: 22))
                        .foregroundColor(active ? .black : .white)
                }
                Text(label)
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.7))
            }
            .opacity(disabled ? 0.45 : 1.0)
        }
        .disabled(disabled)
    }
}

private struct AudioRoomVideoTile: UIViewRepresentable {
    let track: RTCVideoTrack

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView()
        view.videoContentMode = .scaleAspectFill
        track.add(view)
        context.coordinator.attachedTrack = track
        return view
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        // Track identity swaps on peer renegotiation; rebind to avoid black tile.
        if context.coordinator.attachedTrack !== track {
            context.coordinator.attachedTrack?.remove(uiView)
            track.add(uiView)
            context.coordinator.attachedTrack = track
        }
    }

    static func dismantleUIView(_ uiView: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.attachedTrack?.remove(uiView)
        coordinator.attachedTrack = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var attachedTrack: RTCVideoTrack?
    }
}

private struct AudioRoomRoutePickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = UIColor.white.withAlphaComponent(0.15)
        container.layer.cornerRadius = 28

        let picker = AVRoutePickerView()
        picker.activeTintColor = .white
        picker.tintColor = .white
        picker.backgroundColor = .clear
        picker.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(picker)
        NSLayoutConstraint.activate([
            picker.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            picker.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            picker.widthAnchor.constraint(equalToConstant: 36),
            picker.heightAnchor.constraint(equalToConstant: 36),
        ])
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

private struct ProfilePeekTarget: Identifiable {
    let uin: Int
    var id: Int { uin }
}

private struct AudioRoomPetGlyph: View {
    let pet: EquippedPet
    var size: CGFloat = 28

    @StateObject private var items = ItemsService.shared

    var body: some View {
        if let basename = petBasename(for: pet.kindID) {
            ZStack {
                Circle()
                    .fill(pet.rarity.color.opacity(0.35))
                    .blur(radius: size * 0.18)
                    .scaleEffect(1.10)
                GIFImage(name: basename)
                    .shadow(color: .black.opacity(0.30),
                            radius: size * 0.06, x: 0, y: size * 0.04)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        } else {
            // Catalog not loaded; re-attempts on next ItemsService publish.
            Color.clear.frame(width: size, height: size)
        }
    }

    private func petBasename(for kindID: String) -> String? {
        guard let kind = items.catalog?.kind(by: kindID) else { return nil }
        let basename = (kind.assetRef as NSString).lastPathComponent
        return (basename as NSString).deletingPathExtension
    }
}

private struct AudioRoomQuickActionsSheet: View {
    let member: AudioRoomMember
    let isRoomOwner: Bool
    let onOpenProfile: () -> Void
    let onTrade: () -> Void
    let onKick: () -> Void
    /// Bool is the NEW mute state.
    let onSetMute: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var confirmKick: Bool = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(LinearGradient(
                                colors: [Theme.Color.accent, Theme.Color.accent.opacity(0.6)],
                                startPoint: .top, endPoint: .bottom
                            ))
                            .frame(width: 44, height: 44)
                            .overlay(
                                Text(String(member.nickname.prefix(1)).uppercased())
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundColor(.white)
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(member.nickname)
                                .font(.system(.headline, weight: .semibold))
                                .foregroundColor(Theme.Color.textPrimary)
                            Text("#\(member.uin)")
                                .font(Theme.Font.monoSmall)
                                .foregroundColor(Theme.Color.textMono)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 8)

                    Divider().background(Theme.Color.divider)

                    actionRow(systemImage: "person.crop.circle", labelKey: "audio_room.actions.profile") {
                        onOpenProfile()
                    }
                    actionRow(systemImage: "arrow.left.arrow.right", labelKey: "audio_room.actions.trade") {
                        onTrade()
                    }
                    if isRoomOwner {
                        Divider().background(Theme.Color.divider)
                        actionRow(
                            systemImage: member.mutedByOwner ? "mic.fill" : "mic.slash.fill",
                            labelKey: member.mutedByOwner
                                ? "audio_room.actions.unmute"
                                : "audio_room.actions.mute"
                        ) {
                            onSetMute(!member.mutedByOwner)
                            dismiss()
                        }
                        actionRow(
                            systemImage: "person.fill.xmark",
                            labelKey: "audio_room.actions.kick",
                            destructive: true
                        ) {
                            confirmKick = true
                        }
                    }
                    Divider().background(Theme.Color.divider)
                    UserSafetyActions(
                        targetUIN: member.uin,
                        targetNickname: member.nickname,
                        context: "audio_room",
                        style: .rows,
                    )
                    Spacer(minLength: 0)
                }
            }
            .navigationTitle("audio_room.actions.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("common.cancel".localized) { dismiss() }
                }
            }
            .confirmationDialog(
                String(format: "audio_room.kick.confirm.title".localized, member.nickname),
                isPresented: $confirmKick,
                titleVisibility: .visible
            ) {
                Button("audio_room.kick.confirm.do".localized, role: .destructive) {
                    onKick()
                }
                Button("common.cancel".localized, role: .cancel) {}
            } message: {
                Text("audio_room.kick.confirm.body".localized)
            }
        }
    }

    private func actionRow(systemImage: String, labelKey: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        let tint: Color = destructive ? Color.red : Theme.Color.textPrimary
        return Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 17))
                    .foregroundColor(tint)
                    .frame(width: 24)
                Text(labelKey.localized)
                    .font(.system(size: 16))
                    .foregroundColor(tint)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Floating bar shown over the home screen while the room is minimised.
struct AudioRoomMinimizedBar: View {
    @StateObject private var rooms = AudioRoomService.shared

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.wave.2.fill")
                .foregroundColor(.white)
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 1) {
                Text(rooms.activeRoomName ?? "audio_room.minimized.fallback".localized)
                    .font(.callout.weight(.semibold))
                    .foregroundColor(.white)
                Text(String(format: "audio_room.minimized.listening".localized, rooms.roster.count))
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.85))
            }
            Spacer()
            Button {
                rooms.toggleMute()
            } label: {
                Image(systemName: rooms.localMuted ? "mic.slash.fill" : "mic.fill")
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .background(rooms.localMuted ? Color.red : Color.white.opacity(0.22))
                    .clipShape(Circle())
            }
            Button {
                rooms.exit()
            } label: {
                Image(systemName: "phone.down.fill")
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .background(Color.red)
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        // Layered: green tint behind, ultraThinMaterial in front so blur
        // picks up the tint and softens it.
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.green.opacity(0.55))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        )
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
        .contentShape(Rectangle())
        .onTapGesture { rooms.isMinimized = false }
        .padding(.horizontal, 12)
    }
}

import AVKit
import SwiftUI
import WebRTC

/// Full-screen surface for the active audio room. Roster grid up top,
/// "Joining…" placeholder before the first roster lands, control bar
/// (mute / route / leave) at the bottom. Tap chevron-down to minimise
/// → `AudioRoomMinimizedBar` floats above the home screen and audio
/// keeps streaming via the `audio` UIBackgroundMode.
struct AudioRoomScreen: View {
    @StateObject private var rooms = AudioRoomService.shared
    let initialRoomName: String

    /// Pet snapshot the user just tapped on — drives the
    /// `PetPreviewSheet` modal so a member can inspect another
    /// participant's equipped pet without leaving the room.
    @State private var inspectingPet: PetPreviewTarget?
    /// Roster member whose tile was tapped — drives the quick-actions
    /// sheet (open profile / propose trade / kick if owner).
    @State private var quickActionsTarget: AudioRoomMember?
    /// Profile detail sheet — pushed when the user picks "Open profile"
    /// from the quick-actions sheet.
    @State private var profilePeekUIN: Int?
    /// Trade composer target — set when "Propose trade" is picked.
    @State private var tradeTarget: AudioRoomMember?
    /// Owner-only rename sheet trigger. Toggled when the owner taps
    /// the room name in the top bar; pre-fills with the current name
    /// + persists via `AudioRoomService.renameRoom`.
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

    /// True when the local user owns the active room. Drives the
    /// owner-only "mute all" toggle on the top bar and the Mute /
    /// Unmute row in the per-member quick-actions sheet.
    private var isRoomOwner: Bool {
        guard let id = rooms.activeRoomID,
              let room = rooms.rooms.first(where: { $0.id == id }) else {
            return false
        }
        return room.ownerUIN == AuthService.shared.ownUIN
    }

    /// Current `owner_only_speaking` state of the active room. Read
    /// off the cached `AudioRoom` so the toolbar toggle reflects the
    /// canonical value (server-broadcast via `audio_room_owner_only_changed`).
    private var ownerOnlyActive: Bool {
        guard let id = rooms.activeRoomID,
              let room = rooms.rooms.first(where: { $0.id == id }) else {
            return false
        }
        return room.ownerOnlySpeaking
    }

    /// Room name + "N listening" stack. For the owner the whole
    /// block is a Button that opens the rename sheet (pencil-icon
    /// affordance hints at it). Non-owners get a plain label.
    /// Extracted from `topBar`'s body to keep the type-checker
    /// happy — inlined, the conditional made the topBar's
    /// expression unable to type-check in reasonable time.
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
            // Owner-only mute-all toggle. Flips `owner_only_speaking`
            // on the room — when active, every non-owner client
            // auto-mutes its mic and the toolbar mic toggle becomes
            // a no-op for them. Soft enforcement (mesh WebRTC means
            // the server can't drop a misbehaving client's audio),
            // but the canonical state is server-held + broadcast so
            // every member sees the same room mode.
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
        // Local preview comes off the mesh's local track; remote tiles
        // pull from the per-UIN remote map. Either may be nil — we
        // fall back to the gradient avatar in that case.
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
                    // Bottom-trailing mic-slash badge. Two reasons it
                    // can show: the local user toggled their own mic
                    // off (`isMuted`), or the room owner force-muted
                    // this member (`mutedByOwner`). The owner-mute
                    // case uses an orange backing so it reads as a
                    // distinct moderation state and not "they muted
                    // themselves" — own-mute stays red.
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
                // Equipped-pet glyph — same affordance as the home
                // contact-list overlay. Sits in the bottom-leading
                // corner so it doesn't overlap the muted indicator
                // (which lives bottom-trailing). Tap-routes through a
                // higher-z hit area (see overlay below) to PetPreviewSheet.
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
            // Tile-wide tap → flip camera (own video on) / quick
            // actions (someone else). Pet glyph above takes its tap
            // first because it sits in a higher-z VStack within the
            // ZStack — the .onTapGesture is scoped to that overlay.
            .contentShape(Circle())
            .onTapGesture { handleTileTap(member: m, hasVideo: videoTrack != nil, isMe: isMe) }
            Text(m.nickname)
                .font(.callout)
                .foregroundColor(.white)
                .lineLimit(1)
                .frame(maxWidth: 110)
        }
    }

    /// Tile tap router. Three branches:
    ///   • Own tile + camera on → flip front/back. The most useful
    ///     thing to do with your own video preview.
    ///   • Own tile + camera off → no-op (the bottom toolbar is the
    ///     right entry point to enable the camera).
    ///   • Other user's tile → quick-actions sheet (profile / trade /
    ///     kick). Same content for owner + non-owner; the kick row
    ///     only renders when the local user is the room owner.
    private func handleTileTap(member: AudioRoomMember, hasVideo: Bool, isMe: Bool) {
        if isMe {
            if hasVideo { rooms.flipCamera() }
        } else {
            quickActionsTarget = member
        }
    }

    private var controlBar: some View {
        // Mic disabled in two cases for the local user:
        //   • Room owner flipped owner-only mode and I'm not the owner
        //   • Owner force-muted me individually
        // Either way the toggle becomes a no-op — `AudioRoomService`
        // already auto-mutes the mic on the matching events, this just
        // stops the user from poking at a button that won't do anything.
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

/// SwiftUI bridge for an `RTCMTLVideoView`. Used inside member tiles
/// to render either the local camera preview (when own tile) or a
/// peer's incoming video track (when remote). The track lives on
/// `AudioRoomMeshManager` / `AudioRoomService`; this view just
/// attaches a Metal renderer to it.
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
        // Track identity can swap when a peer's video re-arrives after
        // a renegotiation. Detach the previous and bind the new so the
        // tile keeps rendering instead of going black.
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

/// Same role as the route picker in CallScreen — local copy here
/// instead of bridging across files because the two surfaces have
/// independently-styled chrome.
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

/// Identifiable wrapper for the profile-peek sheet — `Int` would
/// collide with SwiftUI's identity tracking when used directly.
private struct ProfilePeekTarget: Identifiable {
    let uin: Int
    var id: Int { uin }
}

/// Equipped-pet badge for an audio-room tile. Same rendering rules as
/// `StatusWithPet`'s pet glyph — bare animated GIF with a soft
/// rarity-tinted halo behind it. No hard ring, no backing disc:
/// matches the contact-list / chat-header / group-info presentation.
///
/// The basename for the GIF is resolved through the catalog the same
/// way `StatusWithPet.petBasename` does — `pet.kindID` alone is NOT
/// the bundled file name (kinds like `pet_spark` map to bundled
/// assets like `pet1.gif` via the catalog's `assetRef`).
private struct AudioRoomPetGlyph: View {
    let pet: EquippedPet
    var size: CGFloat = 28

    /// Observe `ItemsService` so the glyph re-evaluates if the
    /// catalog finishes loading after the room screen mounts. Same
    /// pattern as `StatusWithPet`.
    @StateObject private var items = ItemsService.shared

    var body: some View {
        if let basename = petBasename(for: pet.kindID) {
            ZStack {
                // Soft rarity-tinted halo. Same opacity + blur ratio
                // as StatusWithPet so the glow reads as a subtle aura
                // around the pet, not a colored disc behind it.
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
            // Catalog not loaded yet (or unknown kind) — render
            // nothing rather than a broken placeholder. Re-attempts
            // automatically on the next ItemsService publish.
            Color.clear.frame(width: size, height: size)
        }
    }

    private func petBasename(for kindID: String) -> String? {
        guard let kind = items.catalog?.kind(by: kindID) else { return nil }
        let basename = (kind.assetRef as NSString).lastPathComponent
        return (basename as NSString).deletingPathExtension
    }
}

/// Quick-actions sheet shown when a user taps another participant's
/// tile in an audio room. Three rows: open profile, propose trade,
/// (owner only) kick. Mirrors the iOS-system "long-press on a person
/// in a Group FaceTime call" surface — quick interactions without
/// leaving the room.
private struct AudioRoomQuickActionsSheet: View {
    let member: AudioRoomMember
    let isRoomOwner: Bool
    let onOpenProfile: () -> Void
    let onTrade: () -> Void
    let onKick: () -> Void
    /// Toggle owner-set mute on this member. Bool is the NEW state
    /// (true = mute now, false = unmute now). Called from the
    /// Mute / Unmute action row right above Kick.
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
                        // Mute / Unmute toggle. Single row that flips
                        // its label + glyph based on current state —
                        // simpler than two separate rows that always
                        // show one disabled. Mic-slash-fill mirrors
                        // the iOS-system muted-mic icon.
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
                    // Block + Report — available to ANY participant
                    // about another participant (not gated to room
                    // owner). Same shared component as profile / chat
                    // / group surfaces.
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
                // Cancel sits on the trailing edge (top-right) per the
                // user's preference — `.cancellationAction` defaults to
                // leading on iOS, which felt off-balance for a sheet
                // whose primary content (the participant + actions) is
                // left-aligned.
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

/// Floating bar shown over the home screen while a room session is
/// minimised. Tap to expand back to the full screen, square button
/// to leave.
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
        // Frosted-green pill: ultraThinMaterial blurs whatever is
        // behind the bar (contact list, etc.), then a green tint
        // washes over the blur so it still reads as the "you're
        // in a room" green colour. Layering — material is the
        // CLOSEST background, the green tint sits BEHIND it so
        // SwiftUI's blur picks up the tint and softens it.
        // Previous solid `Color.green.opacity(0.85)` was an opaque
        // panel — nothing blurred through it, looked flat.
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

import Combine
import Foundation
import WebRTC

/// Owns the user's audio-room subscription list (home-screen section)
/// AND the live voice-session lifecycle (entered? roster? speaking?).
/// One service so the home-screen list, the room-screen surface, and
/// the minimised "you're in a room" pill can all observe the same
/// `@Published` state without three separate coordinators.
///
/// Mesh WebRTC lives in `AudioRoomMeshManager` — this service drives
/// it (peer entered → mesh.addPeer; left → mesh.dropPeer; we left →
/// mesh.tearDown) but doesn't own RTCPeerConnection state directly.
///
/// Single-busy: only one room at a time per device. Server enforces
/// the same against 1:1 calls (in-call user can't join a room and
/// vice-versa) so we don't need to second-guess that here.
@MainActor
final class AudioRoomService: ObservableObject {
    static let shared = AudioRoomService()

    /// Subscriptions — what the user sees in the home-screen list.
    /// Hydrated by `refresh()` (HTTP `GET /audio_rooms`); kept in sync
    /// via local mutations after create / join / leave / delete.
    @Published private(set) var rooms: [AudioRoom] = []

    /// Live state for the room the user is currently inside (null when
    /// not in any room). The roster is keyed by UIN; rebuilt on
    /// `room_roster`, mutated by `room_member_entered/left` and the
    /// `room_speaking` indicator.
    @Published private(set) var activeRoomID: Int?
    @Published private(set) var activeRoomName: String?
    @Published private(set) var roster: [Int: AudioRoomMember] = [:]
    /// Local mute mirror. Surface-level toggle — actually mutes via
    /// the mesh manager which flips every audio sender.
    @Published private(set) var localMuted: Bool = false
    /// Local camera state. Same shape as `localMuted` — surface flag
    /// the toolbar binds to; the mesh manager owns the actual video
    /// track lifecycle.
    @Published private(set) var cameraEnabled: Bool = false
    /// Local video track when the camera is on. Drives the self-tile
    /// preview in the room screen.
    @Published private(set) var localVideoTrack: RTCVideoTrack?
    /// Per-UIN remote video tracks. Populated as peers' offers land
    /// with a video m-section; cleared on `room_member_left` /
    /// `room_deleted` / our own exit.
    @Published private(set) var remoteVideoTracks: [Int: RTCVideoTrack] = [:]
    /// True between `enter()` and the first `room_roster` event.
    /// Drives the "Joining…" copy in the room sheet.
    @Published private(set) var isJoining: Bool = false
    /// Set the first time `refresh()` resolves — used by the home-screen
    /// to fade the audio-rooms section in smoothly on cold launch
    /// instead of letting it pop in once /audio_rooms answers.
    @Published private(set) var hasLoadedOnce: Bool = false
    /// Sticky surface flag — set when the last enter() failed (server
    /// rejected with `busy` / `full` / etc). UI presents a one-shot
    /// alert and then clears via `acknowledgeJoinError()`.
    @Published var lastJoinError: String?
    /// True when the user has dragged the room screen down — the
    /// floating pill takes over while audio keeps running. Mirrors
    /// CallService.isMinimized for the same reason.
    @Published var isMinimized: Bool = false

    private var cancellables = Set<AnyCancellable>()

    private init() {
        WebSocketService.shared.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in self?.handle(event) }
            .store(in: &cancellables)
        // Mirror video-track changes from the mesh manager into
        // @Published state SwiftUI can observe. The mesh fires these
        // synchronously on the main actor so we just shovel the value
        // through.
        AudioRoomMeshManager.shared.onLocalVideoTrackChanged = { [weak self] track in
            self?.localVideoTrack = track
        }
        AudioRoomMeshManager.shared.onRemoteVideoTrackChanged = { [weak self] uin, track in
            guard let self else { return }
            if let track {
                self.remoteVideoTracks[uin] = track
            } else {
                self.remoteVideoTracks.removeValue(forKey: uin)
            }
        }
    }

    // MARK: - HTTP API

    /// Hydrate the home-screen list from the server. Called on launch,
    /// pull-to-refresh, and after every mutation that crosses the wire.
    func refresh() async {
        do {
            let list: [AudioRoom] = try await APIClient.shared.request("GET", "/audio_rooms")
            self.rooms = list
        } catch {
            print("[AudioRoomService] refresh failed: \(error)")
        }
        // Always set true (success or fail). The home-screen treats
        // this as "we tried" — the section can stop hiding itself.
        hasLoadedOnce = true
    }

    /// POST /audio_rooms. Server mints the join key + adds owner as
    /// the first subscriber. We append the response into our list and
    /// return it for the caller to immediately enter (typical flow:
    /// "create + jump straight in").
    func create(name: String) async throws -> AudioRoom {
        struct Body: Encodable { let name: String }
        let room: AudioRoom = try await APIClient.shared.request(
            "POST", "/audio_rooms", body: Body(name: name)
        )
        rooms.insert(room, at: 0)
        return room
    }

    /// POST /audio_rooms/join. Subscribe by key. Adds to our list if
    /// we weren't already a member. Server is case-insensitive so
    /// pasting "abcd1234" works the same as "ABCD1234".
    func join(byKey key: String) async throws -> AudioRoom {
        struct Body: Encodable { let join_key: String }
        let room: AudioRoom = try await APIClient.shared.request(
            "POST", "/audio_rooms/join", body: Body(join_key: key)
        )
        if !rooms.contains(where: { $0.id == room.id }) {
            rooms.insert(room, at: 0)
        }
        return room
    }

    /// DELETE /audio_rooms/{id}/membership. Drop from MY list — room
    /// stays alive for everyone else. If we're currently inside the
    /// voice session, exit first so the mesh tears down cleanly.
    func leaveList(roomID: Int) async {
        if activeRoomID == roomID { exit() }
        do {
            let _: EmptyResponse = try await APIClient.shared.request(
                "DELETE", "/audio_rooms/\(roomID)/membership"
            )
            rooms.removeAll { $0.id == roomID }
        } catch {
            print("[AudioRoomService] leaveList failed: \(error)")
        }
    }

    /// POST /audio_rooms/{id}/kick. Owner-only — server enforces.
    /// Server drops the kicked user's membership row + boots them
    /// from the live session; the kicked user gets
    /// `audio_room_membership_revoked` (room disappears from their
    /// list) and, if they were in voice, `audio_room_kicked` (their
    /// session tears down). Other live members get `room_member_left`
    /// for the kicked UIN so their meshes drop the dead peer.
    /// Returns true on success so the caller's UI can dismiss the
    /// quick-actions sheet.
    @discardableResult
    func kick(roomID: Int, uin: Int) async -> Bool {
        struct Body: Encodable { let uin: Int }
        do {
            let _: AudioRoom = try await APIClient.shared.request(
                "POST", "/audio_rooms/\(roomID)/kick",
                body: Body(uin: uin)
            )
            // Local mirror — drop the kicked UIN from the live roster
            // immediately rather than waiting on the server's
            // `room_member_left` echo, so the tile vanishes the
            // instant the kicker confirms.
            if activeRoomID == roomID {
                roster.removeValue(forKey: uin)
                AudioRoomMeshManager.shared.dropPeer(uin: uin)
            }
            return true
        } catch {
            print("[AudioRoomService] kick failed: \(error)")
            return false
        }
    }

    /// POST /audio_rooms/{id}/members/{uin}/mute. Owner-only:
    /// mute (or unmute) a single participant. Server fans out
    /// `audio_room_member_muted` to every subscriber so all tiles
    /// repaint and the muted user's client honors by flipping its
    /// own mic. Returns true on success so the caller's quick-actions
    /// sheet can dismiss cleanly.
    @discardableResult
    func muteMember(roomID: Int, uin: Int, muted: Bool) async -> Bool {
        struct Body: Encodable { let uin: Int; let muted: Bool }
        do {
            let _: AudioRoom = try await APIClient.shared.request(
                "POST", "/audio_rooms/\(roomID)/members/\(uin)/mute",
                body: Body(uin: uin, muted: muted)
            )
            // Local mirror so the caller's UI updates without
            // waiting on the WS echo.
            if activeRoomID == roomID, var row = roster[uin] {
                row.mutedByOwner = muted
                roster[uin] = row
            }
            return true
        } catch {
            print("[AudioRoomService] muteMember failed: \(error)")
            return false
        }
    }

    /// POST /audio_rooms/{id}/owner_only. Owner-only: flip the room
    /// into / out of "only owner can speak" mode. Non-owner clients
    /// auto-mute mic on enable; on disable, mics stay muted (the
    /// user owns the un-mute decision).
    @discardableResult
    func setOwnerOnly(roomID: Int, enabled: Bool) async -> Bool {
        struct Body: Encodable { let enabled: Bool }
        do {
            let _: AudioRoom = try await APIClient.shared.request(
                "POST", "/audio_rooms/\(roomID)/owner_only",
                body: Body(enabled: enabled)
            )
            applyOwnerOnly(roomID: roomID, enabled: enabled)
            return true
        } catch {
            print("[AudioRoomService] setOwnerOnly failed: \(error)")
            return false
        }
    }

    /// PATCH /audio_rooms/{id}. Owner-only — change the room's
    /// display name. Server fans an `audio_room_renamed` WS event
    /// to every subscriber so home-screen lists + active room
    /// views update in lockstep. We mirror the new name into the
    /// local rooms array + activeRoomName immediately so the
    /// owner's UI reflects the change before the WS roundtrip.
    @discardableResult
    func renameRoom(roomID: Int, newName: String) async -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        struct Body: Encodable { let name: String }
        do {
            let room: AudioRoom = try await APIClient.shared.request(
                "PATCH", "/audio_rooms/\(roomID)",
                body: Body(name: trimmed),
            )
            applyRename(roomID: roomID, name: room.name)
            return true
        } catch {
            print("[AudioRoomService] renameRoom failed: \(error)")
            return false
        }
    }

    /// POST /audio_rooms/{id}/rotate_key. Owner-only — mints a fresh
    /// join key. Existing memberships are kept; anyone outside the
    /// subscription set who held the old key is locked out (the old
    /// key 404s on subsequent /join). The new key is fanned out to
    /// every subscriber via `audio_room_key_rotated` so cached
    /// `joinKey` fields update everywhere.
    @discardableResult
    func rotateKey(roomID: Int) async -> AudioRoom? {
        do {
            let room: AudioRoom = try await APIClient.shared.request(
                "POST", "/audio_rooms/\(roomID)/rotate_key"
            )
            // Local mirror — server fan-out also updates us via
            // `audio_room_key_rotated`, but acting on the response
            // is faster for the owner UI.
            if let idx = rooms.firstIndex(where: { $0.id == roomID }) {
                rooms[idx] = room
            }
            return room
        } catch {
            print("[AudioRoomService] rotateKey failed: \(error)")
            return nil
        }
    }

    /// DELETE /audio_rooms/{id}. Owner-only — server enforces. Boots
    /// every active member out via `audio_room_kicked` + clears the
    /// room from every subscriber's list via `audio_room_deleted`.
    func deleteRoom(roomID: Int) async {
        do {
            let _: EmptyResponse = try await APIClient.shared.request(
                "DELETE", "/audio_rooms/\(roomID)"
            )
            // Local mirror — server fan-out also fires `audio_room_deleted`
            // back to us, but acting on the response is faster.
            rooms.removeAll { $0.id == roomID }
            if activeRoomID == roomID { tearDownLocal() }
        } catch {
            print("[AudioRoomService] deleteRoom failed: \(error)")
        }
    }

    // MARK: - voice session lifecycle

    /// Enter the live voice session. Spins up the mesh manager and
    /// fires `room_enter` to the server, which responds with a
    /// `room_roster` (entry into the in-memory presence set). Existing
    /// members will then dial us with `room_offer` events.
    func enter(room: AudioRoom) {
        // Idempotent — no-op if we're already in this room.
        if activeRoomID == room.id { return }
        // Single-busy at the client too: hangup any existing call
        // would be cleaner UX than refusing the entry, but until
        // we settle that, just refuse silently.
        guard CallService.shared.state == .idle else {
            lastJoinError = "audio_room.error.in_call".localized
            return
        }
        // If we were inside another room, tear that down first.
        if activeRoomID != nil { exit() }

        activeRoomID = room.id
        activeRoomName = room.name
        roster.removeAll()
        localMuted = false
        isJoining = true

        AudioRoomMeshManager.shared.start(roomID: room.id)
        WebSocketService.shared.sendRoomEnter(roomID: room.id)
        // "I just joined" cue — only the local user hears this.
        // Plays immediately on tap so the entry feels confirmed
        // before the WebRTC mesh actually finishes negotiating.
        SoundService.shared.play(.joinMe)
    }

    /// Leave the live voice session. Tells the server (which fans out
    /// `room_member_left` to peers) and tears down our mesh. The
    /// home-screen subscription stays — call `leaveList(roomID:)` for
    /// the harder "remove from my list" action.
    func exit() {
        guard let id = activeRoomID else { return }
        WebSocketService.shared.sendRoomLeave(roomID: id)
        tearDownLocal()
    }

    /// Mute / unmute self. Mirrors WebRTCManager's pattern — flip the
    /// `isEnabled` flag on every audio sender across every peer
    /// connection in the mesh. Server doesn't need to know.
    func toggleMute() {
        let next = !localMuted
        AudioRoomMeshManager.shared.setMicMuted(next)
        localMuted = next
        // Reflect into our own roster row so the local member's mic
        // glyph updates immediately.
        if let me = AuthService.shared.ownUIN {
            let nick = AuthService.shared.nickname.isEmpty ? String(me) : AuthService.shared.nickname
            var row = roster[me] ?? AudioRoomMember(uin: me, nickname: nick)
            row.localMuted = next
            roster[me] = row
        }
    }

    /// Toggle the local camera. The mesh manager mints / tears down
    /// the video track and renegotiates SDP with every peer — the
    /// service just mirrors the resulting state into `cameraEnabled`
    /// so the UI control reflects it.
    func toggleCamera() {
        let next = !cameraEnabled
        AudioRoomMeshManager.shared.setCameraEnabled(next)
        cameraEnabled = next
    }

    /// Flip front ↔ back camera. No-op when camera is off.
    func flipCamera() {
        AudioRoomMeshManager.shared.flipCamera()
    }

    /// Refresh just the active counts on every subscribed room. Cheaper
    /// than a full `refresh()` when the user pulls down on the home
    /// screen mid-session — just bumps the "(N)" badges.
    func refreshActiveCounts() async {
        await refresh()
    }

    /// Convenience: am I (the local UIN) currently inside `roomID`?
    func isInside(_ roomID: Int) -> Bool {
        activeRoomID == roomID
    }

    func acknowledgeJoinError() {
        lastJoinError = nil
    }

    /// Burn-account / sign-out hook — drop everything without bothering
    /// the wire (the connection is about to disappear anyway).
    func wipe() {
        rooms.removeAll()
        tearDownLocal()
        lastJoinError = nil
    }

    // MARK: - WS event routing

    private func handle(_ event: WebSocketService.Event) {
        switch event {
        case .roomEnterRejected(let roomID, let reason):
            guard activeRoomID == roomID else { return }
            print("[AudioRoomService] enter rejected: \(reason)")
            lastJoinError = friendly(reason: reason)
            tearDownLocal()

        case .roomRoster(let roomID, let members, let ownerOnly):
            guard activeRoomID == roomID else { return }
            isJoining = false
            var fresh: [Int: AudioRoomMember] = [:]
            for m in members {
                fresh[m.uin] = AudioRoomMember(
                    uin: m.uin, nickname: m.nickname,
                    equippedPet: m.equippedPet, mutedByOwner: m.mutedByOwner
                )
            }
            roster = fresh
            updateActiveCount(roomID: roomID, count: members.count)
            // Mirror the owner-only flag onto our cached AudioRoom
            // so the toolbar UI updates without waiting on a
            // separate /audio_rooms refresh.
            applyOwnerOnly(roomID: roomID, enabled: ownerOnly)
            // If the room is in owner-only mode AND we're not the
            // owner, auto-mute mic. Same path the live event takes
            // — keeps cold-enter consistent with mid-session toggle.
            applyOwnerOnlyEnforcement(roomID: roomID, enabled: ownerOnly)
            // Per-member owner-mute also applies to ME if I appear
            // in the muted set. Mirror to local mic.
            if let me = AuthService.shared.ownUIN,
               let myRow = roster[me], myRow.mutedByOwner {
                AudioRoomMeshManager.shared.setMicMuted(true)
                localMuted = true
            }

        case .roomMemberEntered(let roomID, let uin, let nickname, let pet, let mutedByOwner):
            guard activeRoomID == roomID else { return }
            roster[uin] = AudioRoomMember(
                uin: uin, nickname: nickname,
                equippedPet: pet, mutedByOwner: mutedByOwner
            )
            updateActiveCount(roomID: roomID, count: roster.count)
            // Server convention: the EXISTING member is the offerer.
            // We're an existing member here (received this event for
            // someone *else's* arrival) so dial them.
            AudioRoomMeshManager.shared.dialNewPeer(uin: uin)
            // "Someone just walked in" cue — fires only for
            // existing members because the new joiner doesn't
            // receive `roomMemberEntered` for themselves (server
            // sends them `roomRoster` instead). Per-room behaviour
            // mirrors Discord/Telegram voice rooms.
            SoundService.shared.play(.joinAll)

        case .roomMemberLeft(let roomID, let uin):
            guard activeRoomID == roomID else { return }
            roster.removeValue(forKey: uin)
            updateActiveCount(roomID: roomID, count: roster.count)
            AudioRoomMeshManager.shared.dropPeer(uin: uin)

        case .roomOffer(let roomID, let from, let sdp):
            guard activeRoomID == roomID else { return }
            AudioRoomMeshManager.shared.handleOffer(fromUIN: from, sdp: sdp)

        case .roomAnswer(let roomID, let from, let sdp):
            guard activeRoomID == roomID else { return }
            AudioRoomMeshManager.shared.handleAnswer(fromUIN: from, sdp: sdp)

        case .roomIce(let roomID, let from, let candidateJSON):
            guard activeRoomID == roomID else { return }
            AudioRoomMeshManager.shared.handleIce(fromUIN: from, candidateJSON: candidateJSON)

        case .roomSpeaking(let roomID, let uin, let speaking):
            guard activeRoomID == roomID else { return }
            if var row = roster[uin] {
                row.speaking = speaking
                roster[uin] = row
            }

        case .roomKicked(let roomID, _):
            // Owner deleted the room out from under us. Drop the live
            // session immediately; the matching `room_deleted` will
            // remove the row from the home-screen list.
            guard activeRoomID == roomID else { return }
            lastJoinError = "audio_room.error.deleted".localized
            tearDownLocal()

        case .roomDeleted(let roomID):
            rooms.removeAll { $0.id == roomID }
            if activeRoomID == roomID { tearDownLocal() }

        case .roomMembershipRevoked(let roomID):
            // Owner kicked us out — drop the room from our home list
            // and tear down any live session for it. Treated separately
            // from `roomDeleted` because the room itself stays alive
            // for everyone else; only THIS user lost access.
            rooms.removeAll { $0.id == roomID }
            if activeRoomID == roomID {
                lastJoinError = "audio_room.error.kicked".localized
                tearDownLocal()
            }

        case .roomKeyRotated(let roomID, let newKey):
            // Owner minted a new join key. Patch the local cache so
            // anyone who shares the room from this device hands out
            // the fresh key — old key is dead server-side.
            if let idx = rooms.firstIndex(where: { $0.id == roomID }) {
                var room = rooms[idx]
                room = AudioRoom(
                    id: room.id, name: room.name, ownerUIN: room.ownerUIN,
                    joinKey: newKey, createdAt: room.createdAt,
                    activeCount: room.activeCount,
                    ownerOnlySpeaking: room.ownerOnlySpeaking
                )
                rooms[idx] = room
            }

        case .roomMemberMuted(let roomID, let uin, let mutedByOwner):
            guard activeRoomID == roomID else { return }
            if var row = roster[uin] {
                row.mutedByOwner = mutedByOwner
                roster[uin] = row
            }
            // If WE got muted, honor by flipping our own mic.
            // Unmute on receive does NOT auto-unmute the mic — user
            // re-enables on their own from the toolbar (avoids the
            // surprise of "owner unmuted me, now I'm broadcasting").
            if let me = AuthService.shared.ownUIN, uin == me, mutedByOwner {
                AudioRoomMeshManager.shared.setMicMuted(true)
                localMuted = true
            }

        case .roomOwnerOnlyChanged(let roomID, let enabled):
            guard activeRoomID == roomID else { return }
            applyOwnerOnly(roomID: roomID, enabled: enabled)
            applyOwnerOnlyEnforcement(roomID: roomID, enabled: enabled)

        case .roomRenamed(let roomID, let name):
            applyRename(roomID: roomID, name: name)

        default:
            break
        }
    }

    /// Patch the cached room name in `rooms` + `activeRoomName`.
    /// Driven by the rename-self-call response AND the
    /// `audio_room_renamed` WS event, so owners and members both
    /// see the name update without a refetch.
    private func applyRename(roomID: Int, name: String) {
        if let idx = rooms.firstIndex(where: { $0.id == roomID }) {
            var room = rooms[idx]
            room.name = name
            rooms[idx] = room
        }
        if activeRoomID == roomID {
            activeRoomName = name
        }
    }

    /// Patch the cached AudioRoom row's `ownerOnlySpeaking` flag.
    /// Drives the toolbar mute-all button's lit/unlit state and the
    /// "non-owner mic disabled" badge on remote tiles.
    private func applyOwnerOnly(roomID: Int, enabled: Bool) {
        if let idx = rooms.firstIndex(where: { $0.id == roomID }) {
            var room = rooms[idx]
            room.ownerOnlySpeaking = enabled
            rooms[idx] = room
        }
    }

    /// When owner-only mode flips ON, every non-owner client
    /// auto-mutes its mic. When it flips OFF, we don't auto-unmute
    /// — same rationale as `.roomMemberMuted`: the user owns the
    /// decision to start broadcasting.
    private func applyOwnerOnlyEnforcement(roomID: Int, enabled: Bool) {
        guard enabled else { return }
        let ownerUIN = rooms.first(where: { $0.id == roomID })?.ownerUIN
        let me = AuthService.shared.ownUIN
        guard ownerUIN != me else { return }  // owner stays free
        AudioRoomMeshManager.shared.setMicMuted(true)
        localMuted = true
    }

    // MARK: - internals

    private func updateActiveCount(roomID: Int, count: Int) {
        guard let idx = rooms.firstIndex(where: { $0.id == roomID }) else { return }
        var room = rooms[idx]
        room.activeCount = count
        rooms[idx] = room
    }

    private func tearDownLocal() {
        AudioRoomMeshManager.shared.stop()
        activeRoomID = nil
        activeRoomName = nil
        roster.removeAll()
        localMuted = false
        cameraEnabled = false
        localVideoTrack = nil
        remoteVideoTracks.removeAll()
        isJoining = false
        isMinimized = false
    }

    private func friendly(reason: String) -> String {
        let key: String
        switch reason {
        case "busy":         key = "audio_room.error.busy"
        case "full":         key = "audio_room.error.full"
        case "not_member":   key = "audio_room.error.not_member"
        case "no_such_room": key = "audio_room.error.no_such_room"
        default:             key = "audio_room.error.generic"
        }
        return key.localized
    }
}

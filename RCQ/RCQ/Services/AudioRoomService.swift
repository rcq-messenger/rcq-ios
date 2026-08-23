import Combine
import Foundation
import WebRTC

/// Owns the audio-room subscription list and the live voice-session lifecycle.
/// Mesh WebRTC state lives in `AudioRoomMeshManager`; single-busy enforced
/// against 1:1 calls server-side.
@MainActor
final class AudioRoomService: ObservableObject {
    static let shared = AudioRoomService()

    @Published private(set) var rooms: [AudioRoom] = []

    @Published private(set) var activeRoomID: Int?
    @Published private(set) var activeRoomName: String?
    @Published private(set) var roster: [Int: AudioRoomMember] = [:]
    @Published private(set) var localMuted: Bool = false
    @Published private(set) var cameraEnabled: Bool = false
    @Published private(set) var localVideoTrack: RTCVideoTrack?
    @Published private(set) var remoteVideoTracks: [Int: RTCVideoTrack] = [:]
    @Published private(set) var isJoining: Bool = false
    @Published private(set) var hasLoadedOnce: Bool = false
    @Published var lastJoinError: String?
    @Published var isMinimized: Bool = false

    private var cancellables = Set<AnyCancellable>()

    private init() {
        WebSocketService.shared.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in self?.handle(event) }
            .store(in: &cancellables)
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

    /// Paint the room list from disk before the network is asked (see
    /// `RosterSnapshot`). Called from `AppState.doBoot`, never from `init`.
    @discardableResult
    func hydrateFromSnapshot() -> Bool {
        if PanicPINService.shared.isDecoy { return false }
        guard let list = RosterSnapshot.load(.rooms, as: [AudioRoom].self) else { return false }
        rooms = list
        hasLoadedOnce = true
        return true
    }

    /// The account the list belongs to; see ContactService. Nil until a live
    /// answer landed, which is also what gates the write.
    private var roomsAccount: UUID?

    func saveSnapshot() {
        guard roomsAccount != nil else { return }
        RosterSnapshot.save(rooms, as: .rooms, accountID: roomsAccount)
    }

    func refresh() async {
        guard AppState.shared.networkReady else { return }
        let account = AccountManager.shared.activeAccountID
        do {
            let list: [AudioRoom] = try await APIClient.shared.request("GET", "/audio_rooms")
            guard account == AccountManager.shared.activeAccountID, !PanicPINService.shared.isLocked else { return }
            self.rooms = list
            self.roomsAccount = account
            saveSnapshot()
        } catch {
            print("[AudioRoomService] refresh failed: \(error)")
        }
        hasLoadedOnce = true
    }

    func create(name: String) async throws -> AudioRoom {
        struct Body: Encodable { let name: String }
        let room: AudioRoom = try await APIClient.shared.request(
            "POST", "/audio_rooms", body: Body(name: name)
        )
        rooms.insert(room, at: 0)
        return room
    }

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

    @discardableResult
    func kick(roomID: Int, uin: Int) async -> Bool {
        struct Body: Encodable { let uin: Int }
        do {
            let _: AudioRoom = try await APIClient.shared.request(
                "POST", "/audio_rooms/\(roomID)/kick",
                body: Body(uin: uin)
            )
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

    @discardableResult
    func muteMember(roomID: Int, uin: Int, muted: Bool) async -> Bool {
        struct Body: Encodable { let uin: Int; let muted: Bool }
        do {
            let _: AudioRoom = try await APIClient.shared.request(
                "POST", "/audio_rooms/\(roomID)/members/\(uin)/mute",
                body: Body(uin: uin, muted: muted)
            )
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

    @discardableResult
    func rotateKey(roomID: Int) async -> AudioRoom? {
        do {
            let room: AudioRoom = try await APIClient.shared.request(
                "POST", "/audio_rooms/\(roomID)/rotate_key"
            )
            if let idx = rooms.firstIndex(where: { $0.id == roomID }) {
                rooms[idx] = room
            }
            return room
        } catch {
            print("[AudioRoomService] rotateKey failed: \(error)")
            return nil
        }
    }

    func deleteRoom(roomID: Int) async {
        do {
            let _: EmptyResponse = try await APIClient.shared.request(
                "DELETE", "/audio_rooms/\(roomID)"
            )
            rooms.removeAll { $0.id == roomID }
            if activeRoomID == roomID { tearDownLocal() }
        } catch {
            print("[AudioRoomService] deleteRoom failed: \(error)")
        }
    }

    // MARK: - voice session lifecycle

    func enter(room: AudioRoom) {
        if activeRoomID == room.id { return }
        guard CallService.shared.state == .idle else {
            lastJoinError = "audio_room.error.in_call".localized
            return
        }
        if activeRoomID != nil { exit() }

        activeRoomID = room.id
        activeRoomName = room.name
        roster.removeAll()
        localMuted = false
        isJoining = true

        AudioRoomMeshManager.shared.start(roomID: room.id)
        WebSocketService.shared.sendRoomEnter(roomID: room.id)
        SoundService.shared.play(.joinMe)
    }

    func exit() {
        guard let id = activeRoomID else { return }
        WebSocketService.shared.sendRoomLeave(roomID: id)
        tearDownLocal()
    }

    func toggleMute() {
        let next = !localMuted
        AudioRoomMeshManager.shared.setMicMuted(next)
        localMuted = next
        if let me = AuthService.shared.ownUIN {
            let nick = AuthService.shared.nickname.isEmpty ? String(me) : AuthService.shared.nickname
            var row = roster[me] ?? AudioRoomMember(uin: me, nickname: nick)
            row.localMuted = next
            roster[me] = row
        }
    }

    func toggleCamera() {
        let next = !cameraEnabled
        AudioRoomMeshManager.shared.setCameraEnabled(next)
        cameraEnabled = next
    }

    func flipCamera() {
        AudioRoomMeshManager.shared.flipCamera()
    }

    func refreshActiveCounts() async {
        await refresh()
    }

    func isInside(_ roomID: Int) -> Bool {
        activeRoomID == roomID
    }

    func acknowledgeJoinError() {
        lastJoinError = nil
    }

    func wipe() {
        roomsAccount = nil
        rooms.removeAll()
        tearDownLocal()
        lastJoinError = nil
    }

    /// Called from RootView when the scene becomes active. iOS suspends
    /// the WS while the app is backgrounded; when it reconnects the
    /// server's in-memory room roster may have ejected this UIN (after
    /// the offline grace window) or kept it stale. Re-sending
    /// `room_enter` is idempotent server-side (Lua dedups) and forces
    /// a fresh `room_roster` event so the iOS roster + the chat-list
    /// participant counts get re-synced. `refresh()` brings the rooms
    /// list (member counts) up to date too. If we're not in a room,
    /// just refresh the list.
    func restoreOnForeground() {
        Task { @MainActor in
            await refresh()
            if let id = activeRoomID {
                WebSocketService.shared.sendRoomEnter(roomID: id)
            }
        }
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
                    mutedByOwner: m.mutedByOwner,
                    avatarMediaID: m.avatarID, avatarMediaKey: m.avatarKey
                )
            }
            roster = fresh
            updateActiveCount(roomID: roomID, count: members.count)
            applyOwnerOnly(roomID: roomID, enabled: ownerOnly)
            applyOwnerOnlyEnforcement(roomID: roomID, enabled: ownerOnly)
            if let me = AuthService.shared.ownUIN,
               let myRow = roster[me], myRow.mutedByOwner {
                AudioRoomMeshManager.shared.setMicMuted(true)
                localMuted = true
            }

        case .roomMemberEntered(let roomID, let uin, let nickname, let mutedByOwner, let avatarID, let avatarKey):
            guard activeRoomID == roomID else { return }
            roster[uin] = AudioRoomMember(
                uin: uin, nickname: nickname,
                mutedByOwner: mutedByOwner,
                avatarMediaID: avatarID, avatarMediaKey: avatarKey
            )
            updateActiveCount(roomID: roomID, count: roster.count)
            // Server convention: existing member is the offerer.
            AudioRoomMeshManager.shared.dialNewPeer(uin: uin)
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
            guard activeRoomID == roomID else { return }
            lastJoinError = "audio_room.error.deleted".localized
            tearDownLocal()

        case .roomDeleted(let roomID):
            rooms.removeAll { $0.id == roomID }
            if activeRoomID == roomID { tearDownLocal() }

        case .roomMembershipRevoked(let roomID):
            rooms.removeAll { $0.id == roomID }
            if activeRoomID == roomID {
                lastJoinError = "audio_room.error.kicked".localized
                tearDownLocal()
            }

        case .roomKeyRotated(let roomID, let newKey):
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
            // Owner unmute does NOT auto-unmute the local mic.
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

    private func applyOwnerOnly(roomID: Int, enabled: Bool) {
        if let idx = rooms.firstIndex(where: { $0.id == roomID }) {
            var room = rooms[idx]
            room.ownerOnlySpeaking = enabled
            rooms[idx] = room
        }
    }

    private func applyOwnerOnlyEnforcement(roomID: Int, enabled: Bool) {
        guard enabled else { return }
        let ownerUIN = rooms.first(where: { $0.id == roomID })?.ownerUIN
        let me = AuthService.shared.ownUIN
        guard ownerUIN != me else { return }
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
        // Take our own head off the cached count BEFORE activeRoomID is
        // cleared. Nobody else will: the server sends `room_member_left` only
        // to the people who REMAIN (so leaving an empty room broadcasts
        // nothing), the three WS handlers that could lower it are all gated on
        // `activeRoomID == roomID`, and the room list sits under a
        // fullScreenCover, so it is not rebuilt and does not refresh when the
        // cover closes. The row kept saying "1 внутри" next to an icon that had
        // already gone inactive (#418.1). Doing it here covers all five exits:
        // both Leave buttons, a kick, a revoked membership and a refused entry.
        if let id = activeRoomID, let idx = rooms.firstIndex(where: { $0.id == id }) {
            rooms[idx].activeCount = max(0, rooms[idx].activeCount - 1)
        }
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

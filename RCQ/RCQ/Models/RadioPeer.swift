import Foundation
import MultipeerConnectivity

/// One discoverable thing on the local radio mesh — either a
/// person willing to take a 1:1 chat invite, or a room someone
/// is hosting. The `MCPeerID` identifies the device-level peer;
/// `displayName` is the anonymous label shown to others; `kind`
/// gates which list the row appears in on the discovery screen.
struct RadioPeer: Identifiable, Hashable {
    let peerID: MCPeerID
    /// Anonymous label minted client-side before advertising —
    /// "Wandering Stranger #4982" style. Real UIN never goes on
    /// the wire here. (`peerID.displayName` carries it.)
    var displayName: String
    var kind: Kind
    /// Room metadata when `kind == .room`. Nil for 1:1 peers.
    var room: RadioRoomMetadata?
    /// Session-level connection state — drives the discovery row's
    /// "Discovered / Connecting / Connected" badge.
    var state: ConnectionState

    var id: String { peerID.displayName }

    enum Kind: Hashable {
        case oneToOne
        case room
    }

    enum ConnectionState: Hashable {
        case discovered
        case inviting
        case connecting
        case connected
        case disconnected
    }
}

/// Wire-friendly metadata about a room being advertised. Bonjour
/// / MultipeerConnectivity has a 64-byte cap on `discoveryInfo`
/// values, so we keep this dictionary compact: name, host, the
/// room's UUID, and a flag for password-gated rooms. The shared
/// AES key is NOT in the discovery info — for open rooms it's
/// derived from the room id (anyone may join), for closed rooms
/// it's derived from the password client-side.
struct RadioRoomMetadata: Hashable, Codable {
    /// Stable UUID per room — both for joining and for key
    /// derivation. Kept lowercase for cross-platform parity.
    let roomID: String
    let name: String
    let needsPassword: Bool

    static let infoKeyKind = "k"            // "1" / "r"
    static let infoKeyName = "n"            // display name (1:1) or room name (room)
    static let infoKeyRoomID = "rid"        // room only
    static let infoKeyNeedsPwd = "p"        // "1" / "0"

    /// Encode into the 64-byte-per-value Bonjour discovery info.
    /// Kind and name are always present; room rows add `rid` and
    /// `p`. 1:1 rows just carry `k=1` + `n`.
    static func encodeOneToOne(displayName: String) -> [String: String] {
        return [
            infoKeyKind: "1",
            infoKeyName: String(displayName.prefix(60)),
        ]
    }

    static func encodeRoom(name: String, roomID: String, needsPassword: Bool) -> [String: String] {
        return [
            infoKeyKind: "r",
            infoKeyName: String(name.prefix(60)),
            infoKeyRoomID: roomID,
            infoKeyNeedsPwd: needsPassword ? "1" : "0",
        ]
    }

    static func decodeKind(_ info: [String: String]?) -> RadioPeer.Kind {
        let k = info?[infoKeyKind] ?? "1"
        return k == "r" ? .room : .oneToOne
    }

    static func decodeRoom(_ info: [String: String]) -> RadioRoomMetadata? {
        guard
            info[infoKeyKind] == "r",
            let id = info[infoKeyRoomID]
        else { return nil }
        return RadioRoomMetadata(
            roomID: id.lowercased(),
            name: info[infoKeyName] ?? "Room",
            needsPassword: info[infoKeyNeedsPwd] == "1",
        )
    }

    static func decodeName(_ info: [String: String]?) -> String {
        info?[infoKeyName] ?? "chat.random.stranger".localized
    }
}

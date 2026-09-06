// The app-side types `CrossIslandVault` talks to, stubbed so the REAL
// Services/CrossIslandVault.swift compiles outside the app target. Nothing
// here is exercised: the parity run only calls `merge` / `encode` / `decode`,
// which are pure. They exist so the file under test can be compiled AS IT
// SHIPS rather than copied, the way Tools/SectionsParity does.
import Foundation

enum Vault {
    static let crossisland = "crossisland"
    static func slotId(identityPriv: Data, name: String) -> String { "" }
    static func seal(identityPriv: Data, slot: String, version: Int, plaintext: Data) throws -> Data { Data() }
    static func open(identityPriv: Data, slot: String, version: Int, blob: Data) throws -> Data { Data() }
}

enum VaultClient {
    struct SlotRead { let blob: String?; let version: Int }
    struct Write { let version: Int?; let current: Int }
    static func get(_ slot: String) async throws -> SlotRead { SlotRead(blob: nil, version: 0) }
    static func put(_ slot: String, blob: String, basedOn: Int) async throws -> Write { Write(version: nil, current: 0) }
}

enum VaultFloor {
    static func lastSeen(_ slot: String) -> Int { 0 }
    static func remember(_ slot: String, _ version: Int) {}
}

enum KeychainStore {
    enum Keys { static let identityPriv = "" }
    static func data(_ key: String) -> Data? { nil }
}

final class PanicPINService {
    static let shared = PanicPINService()
    var isDecoy: Bool { false }
}

struct ServerCapabilities { var vault = false }

final class AppState {
    static let shared = AppState()
    var serverCapabilities = ServerCapabilities()
}

enum UserStatus { case offline }

struct Contact {
    let uin: Int
    var nickname: String
    var status: UserStatus
    var statusMessage: String?
    var blocked: Bool
    var identityKey: String
    var signingKey: String
    var signalIdentityKey: String?
    var gender: String?
    var host: String?
    var avatarMediaID: String?
    var avatarMediaKey: String?
}

enum Multihome {
    static func isOwnHost(_ host: String?) -> Bool { false }
}

final class CrossIslandStore {
    static let shared = CrossIslandStore()
    var onChange: (() -> Void)?
    func all() -> [Contact] { [] }
    func addedAtFor(_ uin: Int, _ host: String) -> Double { 0 }
    func profileTSFor(_ uin: Int, _ host: String) -> Int { 0 }
    func tombstones() -> [String: Double] { [:] }
    func replaceAll(_ rows: [(contact: Contact, addedAt: Double, profileTS: Int)], graves: [String: Double]) {}
}

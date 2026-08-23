// The app-side types `SectionsVault` talks to, stubbed so the REAL
// Services/SectionsVault.swift compiles outside the app target. Nothing here is
// exercised: the parity run only calls `Sections`, which is pure. They exist so
// the file under test can be compiled AS IT SHIPS rather than copied, the way
// Tools/VaultCheck compiles the real Services/Vault.swift.
import Foundation

enum AppGroup {
    static func readActiveAccountID() -> UUID? { nil }
}

final class PanicPINService {
    static let shared = PanicPINService()
    var isDecoy: Bool { false }
    var isConfigured: Bool { false }
}

struct ServerCapabilities {
    var vault = false
}

final class AppState {
    static let shared = AppState()
    var serverCapabilities = ServerCapabilities()
}

enum KeychainStore {
    enum Keys {
        static let identityPriv = "rcq.identity.priv"
    }

    static func data(_ key: String) -> Data? { nil }
}

enum Vault {
    static let sections = "sections"

    static func slotId(identityPriv: Data, name: String) -> String { name }

    static func open(identityPriv: Data, slot: String, version: Int, blob: Data) throws -> Data { blob }

    static func seal(identityPriv: Data, slot: String, version: Int, plaintext: Data) throws -> Data { plaintext }
}

enum VaultClient {
    struct SlotRead {
        let blob: String?
        let version: Int
    }

    struct Write {
        let version: Int?
        let current: Int
    }

    static func get(_ slot: String) async throws -> SlotRead { SlotRead(blob: nil, version: 0) }

    static func put(_ slot: String, blob: String, basedOn: Int) async throws -> Write {
        Write(version: basedOn + 1, current: basedOn + 1)
    }
}

enum VaultFloor {
    static func lastSeen(_ slot: String) -> Int { 0 }
    static func remember(_ slot: String, _ version: Int) {}
}

@MainActor
final class SectionsStore {
    static let shared = SectionsStore()
    private(set) var tree: SectionsTree = Sections.emptyTree()

    func save(_ next: SectionsTree) { tree = next }
    func markPending(_ on: Bool) {}
}

struct AliasRef {
    let aliasId: Int
    let remoteId: Int
    let host: String
}

final class VisitedIslandsStore {
    static let shared = VisitedIslandsStore()
    func isForeignGroupId(_ id: Int) -> Bool { id < 0 }
    func refByAlias(_ aliasId: Int) -> AliasRef? { nil }
}

struct RCQGroup {
    let id: Int
}

import Foundation
import CryptoKit

/// Guest cards: how a stranger is allowed to write to you on a CLOSED island.
///
/// On a closed island the key that seals an envelope to somebody is withheld
/// from strangers, so knowing a number stops being enough. A card is what a
/// resident hands out to be reachable anyway: 32 random bytes THIS DEVICE
/// generates, of which the island is told only the sha256.
///
/// ⚠⚠ THE RAW CARD NEVER GOES TO THE ISLAND. Not at registration, not at use.
/// The island stores a digest and compares digests; the value itself travels
/// only between people: in the FRAGMENT of a shared contact link (a fragment
/// is never sent to a server) and in the clear INSIDE the first sealed
/// envelope we send somebody, which is what turns "I wrote to you first" into
/// "you may write back" with no server state and no screen. It rides the
/// `X-RCQ-Guest-Card` header and never a query string: it is a live credential
/// with no expiry, and a query string is an access log.
///
/// Mirrors `web-chat/src/lib/guest-card.ts` and Android's `GuestCardStore`,
/// including the one-card-for-everybody decision: a card PER CONTACT would let
/// a resident cut off exactly one person, but it would also hand the island a
/// stable per-relationship identifier it could count and time, which is the
/// metadata this design exists to avoid. Cutting off one person is a block,
/// which is client-side.
@MainActor
final class GuestCardStore {
    static let shared = GuestCardStore()

    private static let appGroup = "group.app.rcq.shared"
    private static let minePrefix = "rcq.guestcard.mine.v1."
    private static let theirsPrefix = "rcq.guestcard.theirs.v1."
    private static let cardBytes = 32
    private static let cardMax = 128

    struct MyCard: Codable {
        let card: String
        let hash: String
        var label: String?
        var createdAt: Double
    }

    private let defaults: UserDefaults
    private var account: UUID?

    private init() {
        defaults = UserDefaults(suiteName: Self.appGroup) ?? .standard
        account = AppGroup.readActiveAccountID()
    }

    func bind(accountID: UUID?) { account = accountID }

    private func key(_ prefix: String) -> String? {
        guard let a = account else { return nil }
        return prefix + a.uuidString
    }

    // MARK: - minting

    static func newCard() -> String {
        var b = [UInt8](repeating: 0, count: cardBytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, b.count, &b)
        return Data(b).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// sha256-hex. ⚠ Must equal the island's `models/guest_card.hash_card` and
    /// the other two clients, or a card this build registers opens nothing —
    /// and the symptom is a stranger being told "no such number", which is
    /// exactly what a working refusal looks like.
    static func hashCard(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = SHA256.hash(data: Data(trimmed.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - ours

    private func loadMine() -> [MyCard] {
        guard let k = key(Self.minePrefix), let d = defaults.data(forKey: k) else { return [] }
        return (try? JSONDecoder().decode([MyCard].self, from: d)) ?? []
    }

    private func saveMine(_ list: [MyCard]) {
        guard let k = key(Self.minePrefix), let d = try? JSONEncoder().encode(list) else { return }
        defaults.set(d, forKey: k)
    }

    var myCards: [MyCard] { loadMine().sorted { $0.createdAt > $1.createdAt } }

    /// The card to put in a link or an envelope, minting one the first time.
    /// `register` is called with the DIGEST when a new card is created, and
    /// only then: talking to the island is the caller's job.
    ///
    /// ⚠ Registered before it is stored. A card we kept but never told the
    /// island about opens nothing, and we would hand it out believing it works.
    func shareableCard(register: (String) async throws -> Void) async -> String? {
        guard account != nil else { return nil }
        if let existing = loadMine().last { return existing.card }
        let card = Self.newCard()
        do { try await register(Self.hashCard(card)) } catch { return nil }
        saveMine(loadMine() + [MyCard(card: card, hash: Self.hashCard(card),
                                      label: "shared", createdAt: Date().timeIntervalSince1970)])
        return card
    }

    func forgetMine(hash: String) { saveMine(loadMine().filter { $0.hash != hash }) }

    // MARK: - theirs

    func handle(_ uin: Int, _ host: String?) -> String {
        guard let h = host, !h.isEmpty else { return String(uin) }
        return "\(uin)@\(h.lowercased())"
    }

    private func loadTheirs() -> [String: String] {
        guard let k = key(Self.theirsPrefix) else { return [:] }
        return defaults.dictionary(forKey: k) as? [String: String] ?? [:]
    }

    private func saveTheirs(_ m: [String: String]) {
        guard let k = key(Self.theirsPrefix) else { return }
        defaults.set(m, forKey: k)
    }

    /// Remember a card somebody handed us, from a link or inside an envelope.
    func remember(uin: Int, host: String?, card: String) {
        let c = card.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty, c.count <= Self.cardMax else { return }
        var m = loadTheirs()
        let k = handle(uin, host)
        guard m[k] != c else { return }
        m[k] = c
        saveTheirs(m)
    }

    /// The card to present when asking an island about this person, or nil.
    func card(for uin: Int, host: String? = nil) -> String? { loadTheirs()[handle(uin, host)] }

    var allTheirCards: [String: String] { loadTheirs() }

    func replaceTheirCards(_ m: [String: String]) { saveTheirs(m) }

    /// Burn: a card is a credential of the account that is going away.
    func wipe(accountID: UUID) {
        defaults.removeObject(forKey: Self.minePrefix + accountID.uuidString)
        defaults.removeObject(forKey: Self.theirsPrefix + accountID.uuidString)
    }
}

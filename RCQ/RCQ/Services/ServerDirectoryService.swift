import Foundation

/// One entry in the public RCQ instance directory at
/// `rcq-messenger/rcq-servers` on GitHub. Schema mirrors `servers.json`
/// in that repo. Don't add fields here without bumping the schema
/// version on the directory side too.
struct ServerEntry: Codable, Identifiable, Hashable {
    let url: String
    let name: String
    let description: String
    let region: String
    let operatorContact: String
    let addedAt: String
    /// The island's logo, MIRRORED ON THE SITE rather than read from the island
    /// itself. An operator's logo lives at `<island>/server/logo`, and fetching
    /// it from there would hand this device's address to every island in the
    /// catalogue the moment the picker opened, including the ones somebody
    /// scrolls past and never joins. The catalogue and the paintings already
    /// come from rcq.app; one more file from that host says nothing new.
    /// Absent for an island whose operator never set one, which is normal.
    let logo: String?

    var id: String { url }

    /// Best-effort hostname for compact display ("api.rcq.app" from the
    /// full URL). Falls back to the raw URL if the parser can't make
    /// sense of it, which only happens on a malformed catalogue entry.
    var displayHost: String {
        URL(string: url)?.host ?? url
    }

    enum CodingKeys: String, CodingKey {
        case url
        case name
        case description
        case region
        case operatorContact = "operator_contact"
        case addedAt = "added_at"
        case logo
    }
}

/// Top-level shape of the catalogue file. `version` lets us evolve the
/// schema without breaking older clients; clients pinning to schema=1
/// can ignore unknown fields gracefully.
struct ServerDirectory: Codable {
    let version: Int
    let updatedAt: String
    let servers: [ServerEntry]

    enum CodingKeys: String, CodingKey {
        case version
        case updatedAt = "updated_at"
        case servers
    }
}

/// Fetch + cache the public RCQ instance directory.
///
/// Reads `https://raw.githubusercontent.com/rcq-messenger/rcq-servers/main/servers.json`
/// once per `Self.ttl` seconds (default 24h), persists the raw bytes
/// + a timestamp in `UserDefaults`, and exposes the parsed list to
/// SwiftUI via `@Published`. On any network or parse failure it
/// silently falls back to whichever state it has: cached list if one
/// is in UserDefaults, the hardcoded `defaultEntry` otherwise. Goal
/// is "the picker always shows at least one option" — `api.rcq.app`
/// must always be selectable, even from a fresh install on a flight
/// with no network.
///
/// Lifecycle: instantiated as the shared singleton, used by
/// `ServerPickerSheet` and any future surface that reads the
/// catalogue. Refresh is best-effort, never blocks a UI affordance.
@MainActor
final class ServerDirectoryService: ObservableObject {
    static let shared = ServerDirectoryService()

    @Published private(set) var servers: [ServerEntry]
    @Published private(set) var loading: Bool = false
    @Published private(set) var lastFetchAt: Date?
    @Published private(set) var lastFetchSucceeded: Bool = true

    private static let cacheKey = "rcq.directory.servers.json"
    private static let cachedAtKey = "rcq.directory.cachedAt"
    private static let ttl: TimeInterval = 24 * 60 * 60
    private static let sourceURL = URL(
        string: "https://raw.githubusercontent.com/rcq-messenger/rcq-servers/main/servers.json"
    )!

    /// Hardcoded last-resort entry. Used when neither network nor cache
    /// can produce a list. Has to match an actual reachable backend so
    /// a no-network fresh install still onboards successfully.
    static let defaultEntry = ServerEntry(
        url: "https://api.rcq.app",
        name: "RCQ",
        description: "Default backend operated by the RCQ maintainer.",
        region: "EU",
        operatorContact: "hello@rcq.app",
        addedAt: "2026-05-28",
        logo: nil
    )

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let cached = try? JSONDecoder().decode(ServerDirectory.self, from: data),
           !cached.servers.isEmpty {
            self.servers = cached.servers
        } else {
            self.servers = [Self.defaultEntry]
        }
        let cachedAt = UserDefaults.standard.double(forKey: Self.cachedAtKey)
        if cachedAt > 0 {
            self.lastFetchAt = Date(timeIntervalSince1970: cachedAt)
        }
    }

    /// Kick off a network refresh if the cache is older than `ttl`.
    /// Safe to call repeatedly — the no-op fast-path is a single
    /// timestamp compare.
    func refreshIfStale() {
        let now = Date().timeIntervalSince1970
        let cachedAt = UserDefaults.standard.double(forKey: Self.cachedAtKey)
        if now - cachedAt < Self.ttl, !servers.isEmpty { return }
        Task { await refresh() }
    }

    /// Force a network refresh regardless of cache age. Used when the
    /// user explicitly opens the picker — they probably want the
    /// freshest list available, even if the cache is 6h old.
    func refresh() async {
        loading = true
        defer { loading = false }
        var req = URLRequest(url: Self.sourceURL)
        // 8s is plenty for a ~1KB JSON over HTTPS, even from a slow
        // network. If it's slower than that the user gets the cached
        // or fallback list, which is the same outcome as failing.
        req.timeoutInterval = 8
        // Cache policy is "use protocol cache" — GitHub raw serves
        // sensible Cache-Control headers, no need to fight URLSession.
        do {
            // Through the tunnel when one is up (this list is often the first
            // thing a censored user needs), but never engage one for GitHub.
            let (data, response) = try await IslandHTTP.data(for: req, allowTunnelFallback: false)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                lastFetchSucceeded = false
                return
            }
            let decoded = try JSONDecoder().decode(ServerDirectory.self, from: data)
            guard !decoded.servers.isEmpty else {
                lastFetchSucceeded = false
                return
            }
            self.servers = decoded.servers
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
            let now = Date()
            UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Self.cachedAtKey)
            lastFetchAt = now
            lastFetchSucceeded = true
        } catch {
            lastFetchSucceeded = false
            // Keep whatever state we have. Cached list stays valid,
            // fallback entry stays selectable.
        }
    }

    /// The entry currently selected via `rcq.baseURL` UserDefaults.
    /// Used by the picker to render a checkmark next to the active
    /// row. Returns the default entry when nothing's been set.
    func currentSelection() -> ServerEntry {
        let override = UserDefaults.standard.string(forKey: "rcq.baseURL") ?? ""
        if override.isEmpty {
            return servers.first(where: { $0.url == Self.defaultEntry.url }) ?? Self.defaultEntry
        }
        if let match = servers.first(where: { $0.url == override }) {
            return match
        }
        // Custom URL the user typed in via CustomServerSheet that
        // isn't in the catalogue. Synthesise a minimal entry so the
        // picker can still show what's active.
        return ServerEntry(
            url: override,
            name: URL(string: override)?.host ?? override,
            description: "",
            region: "—",
            operatorContact: "",
            addedAt: "",
            logo: nil
        )
    }
}

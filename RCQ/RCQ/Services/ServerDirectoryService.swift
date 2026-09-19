import Foundation
import os.log

/// Fetch + cache the public RCQ instance directory.
///
/// Reads the catalogue once per `Self.ttl` seconds (default 24h) from the
/// sources in `ServerCatalogue.sources`, in their order: `rcq.app/servers.json`
/// first, the `rcq-messenger/rcq-servers` copy on GitHub second. Persists the
/// raw bytes + a timestamp in `UserDefaults`, and exposes the parsed list to
/// SwiftUI via `@Published`. On any network or parse failure it silently falls
/// back to whichever state it has: cached list if one is in UserDefaults, the
/// hardcoded `defaultEntry` otherwise, and it keeps showing a cache that is
/// past its TTL rather than emptying the picker. Goal is "the picker always
/// shows at least one option" — `api.rcq.app` must always be selectable, even
/// from a fresh install on a flight with no network.
///
/// The shape of the file, the tolerant reader for it and the source order all
/// live in `ServerCatalogue`, where they can be compiled and checked without
/// the app around them (`Tools/ServerCatalogueCheck`).
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

    private static let log = OSLog(subsystem: "app.rcq.client", category: "ServerDirectory")

    private static let cacheKey = "rcq.directory.servers.json"
    private static let cachedAtKey = "rcq.directory.cachedAt"
    private static let ttl: TimeInterval = 24 * 60 * 60

    /// The flagship, and the last-resort list when there is nothing else.
    /// Lives in `ServerCatalogue` so the ordering rule and the picker agree on
    /// one spelling of it.
    static let defaultEntry = ServerCatalogue.flagship

    init() {
        // The cached bytes go through the SAME tolerant reader as a fresh
        // fetch. A cache written by an older build can hold a file this one
        // reads differently, and dropping it whole here would empty the picker
        // for a person with no network.
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let cached = try? ServerCatalogue.parse(data),
           !cached.servers.isEmpty {
            self.servers = ServerCatalogue.flagshipFirst(cached.servers)
            Self.report(cached.skipped, source: "cache")
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
    ///
    /// Walks `ServerCatalogue.sources` in order and stops at the first one
    /// that serves a usable list. Nothing is written and nothing on screen
    /// changes until one does, so a blocked first source costs a few seconds
    /// and never a shorter picker.
    func refresh() async {
        loading = true
        defer { loading = false }
        for source in ServerCatalogue.sources {
            guard let (data, file) = await Self.read(source) else { continue }
            self.servers = ServerCatalogue.flagshipFirst(file.servers)
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
            let now = Date()
            UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Self.cachedAtKey)
            lastFetchAt = now
            lastFetchSucceeded = true
            return
        }
        // Every source failed. Keep whatever state we have: the cached list
        // stays valid however old it is, and the fallback entry stays
        // selectable.
        lastFetchSucceeded = false
    }

    /// One source, read once: the bytes it served and the catalogue they read
    /// as, or nil when that source produced nothing usable. Never throws, so
    /// the caller's loop can simply try the next road.
    private static func read(_ source: URL) async -> (Data, ServerDirectory)? {
        var req = URLRequest(url: source)
        // 8s is plenty for a ~2KB JSON over HTTPS, even from a slow
        // network. If it's slower than that we move to the next source, and
        // if that one is slow too the user gets the cached or fallback list,
        // which is the same outcome as failing.
        req.timeoutInterval = 8
        // Cache policy stays "use protocol cache": both hosts serve sensible
        // Cache-Control headers, no need to fight URLSession.
        do {
            // Through the tunnel when one is up (this list is often the first
            // thing a censored user needs), but never engage one for a host
            // that is not an island. That also keeps the island trust
            // delegate off these two, which `IslandTrust` requires for
            // rcq.app.
            let (data, response) = try await IslandHTTP.data(for: req, allowTunnelFallback: false)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            let file = try ServerCatalogue.parse(data)
            report(file.skipped, source: source.host ?? source.absoluteString)
            // An empty list is a broken file, not an answer: fall through to
            // the next source rather than emptying the picker.
            guard !file.servers.isEmpty else { return nil }
            return (data, file)
        } catch {
            return nil
        }
    }

    /// Say which entries were dropped and why. Public data by definition (this
    /// is the published directory), so the lines are not redacted: a picker
    /// that is one island short should be answerable from Console instead of
    /// looking like a network problem.
    private static func report(_ skipped: [String], source: String) {
        for line in skipped {
            os_log("catalogue from %{public}@: dropped %{public}@",
                   log: log, type: .error, source, line)
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

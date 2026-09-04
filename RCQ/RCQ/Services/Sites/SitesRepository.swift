import CryptoKit
import Foundation

/// Reading a `.rcq` site: fetch, verify, hash-check, sanitise. The half with a
/// network in it; `SiteSanitizer` is the half with none.
///
/// ⚠⚠ These requests carry NO Authorization header, no cookie and no session,
/// and that is the feature rather than hygiene. A token would let the island
/// build a record of who read what — the reading side of exactly the metadata
/// this project has spent months removing from everything else. The client that
/// asks for a page is a stranger to the island every time, and the island
/// cannot lie about the bytes anyway, because the manifest carries a signature
/// the island did not make.
///
/// The address was resolved on this device (`SiteAddressParser`), so the
/// request goes to the island that hosts the site and NEVER through the
/// reader's own island: proxying would hand its operator a journal of what its
/// users read elsewhere.
///
/// Mirrors `web-chat/src/lib/sites.ts` (`fetchSitePage`, `fetchFile`,
/// `fetchSiteIcon`, `fetchCatalogue`) and Android `SitesRepository.kt`.
actor SitesRepository {

    static let shared = SitesRepository()

    /// A page, ready for whatever draws it. There is no UI in this file on
    /// purpose: the screen decides how a banner looks, this decides what is
    /// true.
    struct SitePage {
        /// Assets inlined, everything outward removed, self-contained.
        let html: String
        /// Which file of the bundle this is.
        let path: String
        /// Every page of the bundle, so the reader can move between them
        /// without a single script running inside the web view.
        let pages: [String]
        let version: Int
        let key: String
        /// We had a DIFFERENT key pinned for this name. Trust on first use, the
        /// same rule as safety numbers: the island may serve other bytes, it
        /// may not pass them off as the same site. The page is still rendered —
        /// a reader who cannot see it cannot judge it — with a banner.
        let keyChanged: Bool
        let title: String?
    }

    /// The site's mark, verified the same way a page is: the manifest signature
    /// covers its hash and the bytes are checked against it. Raster bytes for
    /// the same decoder that draws every avatar — never SVG, see
    /// `SiteManifest.iconPath`.
    struct SiteMark {
        let path: String
        let mime: String
        let bytes: Data
    }

    /// One row of an island's catalogue.
    struct SiteListing {
        let name: String
        let title: String?
        /// The island put this site at the top of its catalogue (`home` on the
        /// flagship). False when the island does not say: the field is newer
        /// than some islands.
        let featured: Bool
        /// Whose site it is, when its author asked to be named.
        ///
        /// ⚠ Nil is the normal case and means "not said", never "unknown
        /// person": the island omits the owner from the public catalogue
        /// unless the author ticked `show_owner`, because publishing a page is
        /// not a decision to publish who wrote it. So a row without it shows
        /// no byline at all rather than an empty one.
        let ownerUIN: Int?
    }

    // MARK: - Entry points

    /// What the address bar typed into it: an address, or `.address` — and in
    /// the second case nothing has been sent anywhere.
    nonisolated func address(_ raw: String, ownHost: String) throws -> SiteAddress {
        guard let addr = SiteAddressParser.parse(raw, ownHost: ownHost) else {
            throw SiteError.address
        }
        return addr
    }

    /// Open a page of a site.
    ///
    /// `fresh` is the reload button: a bundle is served with a short cache,
    /// which is right for reading and wrong for somebody who just republished
    /// and wants to see it.
    func page(
        _ addr: SiteAddress,
        path: String = "index.html",
        fresh: Bool = false
    ) async throws -> SitePage {
        let m = try await manifest(addr, fresh: fresh)
        let raw = try await file(addr, m, path: path, fresh: fresh)

        // ⚠ A stylesheet or an image that is ABSENT or unreachable costs its own
        // element and not the page — that is the reference's behaviour and it is
        // what keeps a half-mirrored bundle readable. A hash MISMATCH is a
        // different sentence: that is the island serving bytes the owner did not
        // sign, and half a page assembled out of those is not a page worth
        // showing. The sanitiser has no opinion about either (it is handed a
        // reader, not a policy), so the mismatch is witnessed here and raised
        // once the pass is over.
        let witness = TamperWitness()
        let sanitiser = SiteSanitizer(manifest: m, path: path, fetch: { [weak self] inner in
            guard let self else { throw SiteError.offline }
            do {
                return try await self.file(addr, m, path: inner, fresh: fresh)
            } catch SiteError.tampered {
                witness.saw()
                throw SiteError.tampered
            }
        })
        let html = await sanitiser.inline(SiteText.decode(raw))
        if witness.sawTampering { throw SiteError.tampered }

        return SitePage(
            html: html,
            path: path,
            pages: m.pages,
            version: m.version,
            key: m.key,
            keyChanged: SitePins.shared.pin(addr, key: m.key),
            title: m.title
        )
    }

    /// Fetch the manifest and check the owner's signature over it.
    ///
    /// Note what this does NOT do: it does not pin. Only opening a page anchors
    /// a key, so drawing a catalogue of marks cannot quietly commit a reader to
    /// a key for a site they never opened.
    func manifest(_ addr: SiteAddress, fresh: Bool = false) async throws -> SiteManifest {
        let bytes = try await get(url(addr, path: "manifest.json"), fresh: fresh)
        return try SiteManifest.parseAndVerify(bytes, expecting: addr.name)
    }

    /// The site's mark, or nil when it has none or when anything about it does
    /// not check out. A mark we cannot verify is not drawn at all: it is what a
    /// site looks like in a list, and an island that could choose it could dress
    /// one site up as another.
    func mark(_ addr: SiteAddress, fresh: Bool = false) async -> SiteMark? {
        let cacheKey = addr.pinKey
        if fresh { forgetMark(cacheKey) }
        if let cached = marks[cacheKey] { return cached }
        var found: SiteMark?
        do {
            let m = try await manifest(addr, fresh: fresh)
            if let path = m.iconPath, let mime = Self.markMime(path) {
                found = SiteMark(path: path, mime: mime, bytes: try await file(addr, m, path: path, fresh: fresh))
            }
        } catch {
            found = nil
        }
        rememberMark(cacheKey, found)
        return found
    }

    /// The catalogue of an island: only the sites that asked to be in it. Best
    /// effort — an island that does not publish one is not an error, it is an
    /// island whose sites are found by being told their names.
    func catalogue(host: String) async -> [SiteListing] {
        guard let base = URL(string: SiteAddress.origin(forHost: host) + "/sites") else {
            return []
        }
        guard let bytes = try? await get(base, fresh: false),
              let rows = (try? JSONSerialization.jsonObject(with: bytes)) as? [[String: Any]] else {
            return []
        }
        return rows.compactMap { row in
            guard let name = row["name"] as? String else { return nil }
            return SiteListing(
                name: name,
                title: row["title"] as? String,
                featured: row["featured"] as? Bool ?? false,
                ownerUIN: row["owner_uin"] as? Int
            )
        }
    }

    // MARK: - The bytes

    /// Fetch one file of the bundle and check it against the manifest's hash.
    ///
    /// A path that is not in the manifest is NEVER requested: nothing unhashed
    /// is fetched, however ordinary the path looks.
    private func file(_ addr: SiteAddress, _ m: SiteManifest, path: String, fresh: Bool) async throws -> Data {
        guard let want = m.files[path] else { throw SiteError.missing }
        let bytes = try await get(url(addr, path: path), fresh: fresh)
        // Lowercase hex, because that is the spelling the manifest was signed
        // with. One spelling per network, decided by the signer: an uppercase
        // hash does not match and reads as tampered rather than being coerced
        // into agreement here.
        guard SiteBytes.sha256Hex(bytes) == want else { throw SiteError.tampered }
        return bytes
    }

    /// ⚠ Built out of path SEGMENTS rather than by pasting a string together.
    /// The site name is `[a-z0-9-]` by the time it gets here and needs no
    /// encoding, but a bundle path is whatever the owner signed, and a path
    /// pasted raw into a URL is how a stray `?` or `#` becomes a request
    /// somewhere else. A `..` segment is refused outright: `manifest.files` is a
    /// flat map of names and nothing in a bundle needs to climb.
    private func url(_ addr: SiteAddress, path: String) throws -> URL {
        let segments = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !segments.isEmpty, !segments.contains("..") else { throw SiteError.missing }
        guard var components = URLComponents(string: addr.origin) else { throw SiteError.offline }
        components.path = "/sites/" + addr.name + "/" + segments.joined(separator: "/")
        guard let url = components.url else { throw SiteError.offline }
        return url
    }

    private func get(_ url: URL, fresh: Bool) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // ⚠⚠ No header is set on this request and none ever should be. There is
        // no Authorization to add because a read is not an authenticated act,
        // and cookies are refused at the request as well as at the session: a
        // page a reader can be recognised across is a page the island can log
        // them reading.
        request.httpShouldHandleCookies = false
        request.cachePolicy = fresh ? .reloadIgnoringLocalAndRemoteCacheData : .useProtocolCachePolicy

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session().data(for: request)
        } catch {
            throw SiteError.offline
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // 410 is the island saying the site is gone ON PURPOSE, which is a
        // different sentence to a reader than "not found".
        if status == 410 { throw SiteError.frozen }
        guard (200..<300).contains(status) else { throw SiteError.missing }
        return data
    }

    // MARK: - The session

    private var cachedSession: URLSession?
    /// The proxy the cached session was built with, so a reader who engages the
    /// tunnel mid-visit does not keep reading through the old route.
    private var cachedProxyPort: Int = -1

    private func session() -> URLSession {
        let proxy = SingBoxTransport.proxyDictionary()
        let port = (proxy?["SOCKSPort"] as? Int) ?? 0
        if let cached = cachedSession, port == cachedProxyPort { return cached }
        cachedSession?.finishTasksAndInvalidate()

        // ⚠⚠ Ephemeral, and built HERE rather than borrowed from `APIClient`:
        // that session carries the account's token in an interceptor and a
        // cookie store, and inheriting either would put a name on every page
        // this reader opens. Ephemeral also means nothing about a visit lands on
        // disk — the cache, such as it is, dies with the process.
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = [:]
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        // Ride the tunnel when it is up, exactly as the signed relay config
        // does: a censored reader has to reach islands too, and there is no
        // identity in one of these requests to leak into it.
        config.connectionProxyDictionary = proxy

        // A `.rcq` read is a connection to an island like any other, so the
        // trust delegate rides here too: a fingerprint island serves its pages,
        // and an island whose certificate changed serves nothing until the
        // person decides. The delegate holds no identity, so the paragraph
        // above still stands.
        let built = URLSession(configuration: config, delegate: IslandTrust.shared, delegateQueue: nil)
        cachedSession = built
        cachedProxyPort = port
        return built
    }

    // MARK: - The mark cache

    /// Marks already fetched and checked this process, keyed `name@host`. A
    /// catalogue redraws often and a mark is the same bytes every time.
    ///
    /// ⚠ Bounded, unlike web-chat's map: these are image BYTES, and a reader
    /// who walks a few islands' catalogues would otherwise hold every mark they
    /// ever saw for the life of the process.
    private var marks: [String: SiteMark?] = [:]
    private var markOrder: [String] = []

    private func rememberMark(_ key: String, _ mark: SiteMark?) {
        if marks[key] == nil { markOrder.append(key) }
        marks[key] = .some(mark)
        while markOrder.count > 32 {
            marks.removeValue(forKey: markOrder.removeFirst())
        }
    }

    private func forgetMark(_ key: String) {
        marks.removeValue(forKey: key)
        markOrder.removeAll { $0 == key }
    }

    /// The types the app's own image decoder already draws for avatars. No
    /// `svg`: a mark is drawn OUTSIDE the locked web view, and iOS has no
    /// native SVG renderer to hand it to anyway.
    private static func markMime(_ path: String) -> String? {
        switch (path.components(separatedBy: ".").last ?? "").lowercased() {
        case "png": return "image/png"
        case "webp": return "image/webp"
        default: return nil
        }
    }
}

/// A hash mismatch seen inside the sanitiser's fetches, carried back out.
///
/// The sanitiser drops whatever it could not fetch and carries on, which is
/// right for a missing file and wrong for a substituted one; this is how the
/// second case gets back to the caller without teaching the sanitiser about
/// error kinds. Locked because the reader closure runs off the actor.
private final class TamperWitness: @unchecked Sendable {
    private let lock = NSLock()
    private var hit = false

    func saw() {
        lock.lock()
        hit = true
        lock.unlock()
    }

    var sawTampering: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hit
    }
}

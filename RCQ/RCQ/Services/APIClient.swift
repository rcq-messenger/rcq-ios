import Foundation

enum APIError: Error, LocalizedError {
    case http(Int, String?)
    case transport(Error)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .http(let code, let body): return "HTTP \(code): \(body ?? "")"
        case .transport(let e): return e.localizedDescription
        case .decoding(let e): return "decode: \(e.localizedDescription)"
        }
    }
}

actor APIClient {
    static let shared = APIClient()

    static let prodBaseURL = "https://api.rcq.app"

    static let builtInProxyURL = "https://gateway.app-edge-relay.workers.dev"

    /// Computed (not stored) so UserDefaults changes — namely the
    /// censorship-fallback `rcq.proxyURL` flipped from Settings —
    /// take effect on the next request without an app relaunch. The
    /// nonisolated marker keeps existing call sites
    /// (`APIClient.shared.baseURL`) drop-in.
    nonisolated var baseURL: URL { APIClient.defaultBaseURL() }
    private var token: String?
    /// Pre-shared masquerade token sent as `X-RCQ-Auth` on every
    /// request when set. Owned by `AppState` per active account —
    /// flipped on account switch via `setServerToken`. nil means no
    /// gate is in front of this backend (public deployments like
    /// api.rcq.app) and we don't send the header at all.
    private var serverToken: String?
    private var session: URLSession
    private var probeSession: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    enum BaseReachability { case primary, proxy, unreachable }

    init() {
        let proxy = SingBoxTransport.proxyDictionary()
        self.session = Self.makeMainSession(proxy: proxy)
        self.probeSession = Self.makeProbeSession(proxy: proxy)

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom(Self.parseDateForExternal)
        self.decoder = dec

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc
    }

    private static func makeMainSession(proxy: [String: Any]?) -> URLSession {
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = true
        cfg.timeoutIntervalForRequest = 20
        // Hard ceiling on the WHOLE request including connectivity-wait.
        // Without this, timeoutIntervalForResource defaults to 7 days, and
        // because waitsForConnectivity=true a POST through a wedged
        // sing-box proxy (typical right after an iOS background-suspend,
        // before the transport is re-pumped) hangs effectively forever —
        // the message bubble stays on the .sending spinner until the user
        // force-quits, and the text is lost on relaunch. 30s lets a
        // genuinely slow relay through while guaranteeing a stuck send
        // surfaces as .failed → tap-to-retry, text intact.
        cfg.timeoutIntervalForResource = 30
        if let proxy { cfg.connectionProxyDictionary = proxy }
        return URLSession(configuration: cfg)
    }

    private static func makeProbeSession(proxy: [String: Any]?) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.waitsForConnectivity = false
        cfg.timeoutIntervalForRequest = 6
        cfg.timeoutIntervalForResource = 8
        if let proxy { cfg.connectionProxyDictionary = proxy }
        return URLSession(configuration: cfg)
    }

    func applyTransportProxy() {
        let proxy = SingBoxTransport.proxyDictionary()
        self.session = Self.makeMainSession(proxy: proxy)
        self.probeSession = Self.makeProbeSession(proxy: proxy)
    }

    private static let dateFormatters: [DateFormatter] = {
        let formats = [
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ssXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
            "yyyy-MM-dd'T'HH:mm:ss.SSS",
            "yyyy-MM-dd'T'HH:mm:ss",
        ]
        return formats.map { fmt in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(secondsFromGMT: 0)
            f.dateFormat = fmt
            return f
        }
    }()

    private static let isoFormatters: [ISO8601DateFormatter] = {
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return [withFrac, plain]
    }()

    static func parseDate(decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let str = try container.decode(String.self)

        for f in isoFormatters {
            if let d = f.date(from: str) { return d }
        }
        for f in dateFormatters {
            if let d = f.date(from: str) { return d }
        }
        if let cut = trimFraction(str), let d = isoFormatters[0].date(from: cut) { return d }

        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Couldn't parse date string: \(str)"
        )
    }

    static let parseDateForExternal: @Sendable (Decoder) throws -> Date = { decoder in
        try APIClient.parseDate(decoder: decoder)
    }

    private static func trimFraction(_ s: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\.(\d{3})\d+"#) else { return nil }
        let mutable = NSMutableString(string: s)
        let range = NSRange(location: 0, length: mutable.length)
        let count = regex.replaceMatches(in: mutable, range: range, withTemplate: ".$1")
        return count > 0 ? (mutable as String) : nil
    }

    /// `rcq.proxyURL` wins when set — Settings exposes a free-form
    /// override the user enables when `api.rcq.app` is blocked
    /// (typically a Cloudflare Worker URL we publish out-of-band).
    /// `rcq.baseURL` is the dev / closed-beta override pointing at
    /// staging. Falls back to prod when neither is set. Trailing
    /// slash is stripped so `baseURL.appendingPathComponent` works.
    private static func defaultBaseURL() -> URL {
        if let proxy = UserDefaults.standard.string(forKey: "rcq.proxyURL")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !proxy.isEmpty,
           let url = URL(string: proxy) {
            return url
        }
        if let override = UserDefaults.standard.string(forKey: "rcq.baseURL"),
           let url = URL(string: override) {
            return url
        }
        if UserDefaults.standard.bool(forKey: "rcq.autoProxyActive"),
           let url = URL(string: builtInProxyURL) {
            return url
        }
        return URL(string: prodBaseURL)!
    }

    private static var hasManualProxy: Bool {
        let p = UserDefaults.standard.string(forKey: "rcq.proxyURL")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !(p ?? "").isEmpty
    }

    @discardableResult
    func refreshActiveBase() async -> BaseReachability {
        if Self.hasManualProxy {
            return await probe(Self.defaultBaseURL().absoluteString) ? .proxy : .unreachable
        }
        let key = "rcq.autoProxyActive"

        // ALWAYS prefer the direct path and re-check it every boot — even when
        // a previous boot fell back to the built-in proxy. A single transient
        // /health failure (cold radio after an iOS background-suspend, a
        // momentary upstream blip) used to flip `autoProxyActive` on and then
        // STICK: subsequent boots probed the proxy FIRST and rode the relay for
        // the whole session, recovering to direct only via a detached probe
        // that took effect a boot later. For a user whose direct path works
        // fine (e.g. an uncensored network abroad — Israel) that produced a slow
        // login, a stale "Без сети" badge (the 15s boot watchdog firing on the
        // slow relay path), and occasional tap-to-resend — all while direct
        // would have been instant. Probing prod first self-heals the moment
        // direct is reachable again; the proxy stays purely as a fallback.
        if await probe(Self.prodBaseURL) {
            if UserDefaults.standard.bool(forKey: key) {
                UserDefaults.standard.set(false, forKey: key)
            }
            return .primary
        }
        // Direct genuinely unreachable — fall back to the embedded proxy.
        if await probe(Self.builtInProxyURL) {
            UserDefaults.standard.set(true, forKey: key)
            print("[APIClient] primary unreachable — switched to built-in proxy")
            return .proxy
        }
        return .unreachable
    }

    private func probe(_ base: String) async -> Bool {
        guard let url = URL(string: base + "/health") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        req.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (_, resp) = try await probeSession.data(for: req)
            return (resp as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
        } catch {
            return false
        }
    }

    /// Fast DIRECT reachability of the prod backend, forced through NO proxy
    /// (a dedicated ephemeral session, never the transport). Used by the
    /// first-launch registration boot to decide whether to pre-engage the
    /// embedded transport BEFORE the very first /auth/register call — a
    /// blocked user can't reach Settings to flip the proxy on, and without
    /// this their first request goes out direct, times out, and they wrongly
    /// conclude they need a VPN just to sign up (mirrors Android's
    /// ensureTransportForHost). 5s so a DPI'd network that hangs doesn't
    /// stall onboarding.
    func probeDirectReachable() async -> Bool {
        guard let url = URL(string: Self.prodBaseURL + "/health") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]   // force a direct connection
        cfg.waitsForConnectivity = false
        cfg.timeoutIntervalForRequest = 5
        cfg.timeoutIntervalForResource = 6
        let direct = URLSession(configuration: cfg)
        defer { direct.invalidateAndCancel() }
        do {
            let (_, resp) = try await direct.data(for: req)
            return (resp as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
        } catch {
            return false
        }
    }

    func setToken(_ token: String?) { self.token = token }
    func currentToken() -> String? { token }

    /// Set the pre-shared masquerade token applied to every request as
    /// `X-RCQ-Auth`. AppState flips this on account switch so each
    /// backend gets its own opt-in header. Pass nil to disable for
    /// public backends.
    func setServerToken(_ token: String?) { self.serverToken = token }

    /// Federation Layer B (F1): PUT a pre-serialized signed home-island record.
    /// The body is raw Data because the record is built as `[String: Any]` and
    /// its exact bytes carry the Ed25519 signature. Best-effort: returns false
    /// instead of throwing so a failed publish never disrupts login.
    func publishIslandRecord(_ jsonBody: Data) async -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent("/federation/island-record"))
        req.httpMethod = "PUT"
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let serverToken { req.setValue(serverToken, forHTTPHeaderField: "X-RCQ-Auth") }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = jsonBody
        guard let (_, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return false }
        return true
    }

    func request<T: Decodable>(
        _ method: String,
        _ path: String,
        body: Encodable? = nil,
        query: [String: String] = [:],
        authenticated: Bool = true,
        retries: Int = 0
    ) async throws -> T {
        let data = try await rawRequest(method, path, body: body, query: query, authenticated: authenticated, retries: retries)
        if T.self == EmptyResponse.self {
            return EmptyResponse() as! T
        }
        if data.isEmpty {
            let typeName = String(reflecting: T.self)
            if typeName.contains("EmptyResponse") {
                for candidate in [Data("null".utf8), Data("{}".utf8)] {
                    if let synthetic = try? decoder.decode(T.self, from: candidate) {
                        return synthetic
                    }
                }
            }
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? "<binary>"
            print("[APIClient] decode \(T.self) failed: \(error)\nraw body: \(raw)")
            throw APIError.decoding(error)
        }
    }

    func rawRequest(
        _ method: String,
        _ path: String,
        body: Encodable? = nil,
        query: [String: String] = [:],
        authenticated: Bool = true,
        retries: Int = 0
    ) async throws -> Data {
        var comp = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            comp.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var req = URLRequest(url: comp.url!)
        req.httpMethod = method
        if authenticated, let token {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let serverToken {
            req.setValue(serverToken, forHTTPHeaderField: "X-RCQ-Auth")
        }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try encoder.encode(AnyEncodable(body))
        }
        // `retries` > 0 only from callers whose request is dedup-safe to repeat
        // (sealed sends: the recipient dedups by envelope UUID, so re-POSTing
        // the identical body is harmless). On cellular a transport failure is
        // usually a dead pooled connection the server already dropped; a quick
        // retry opens a fresh one and lands — automating the manual resend.
        // HTTP errors and cancellation are never retried.
        var lastError: Error = URLError(.unknown)
        for attempt in 0...max(0, retries) {
            do {
                let (data, resp) = try await session.data(for: req)
                guard let http = resp as? HTTPURLResponse else { throw APIError.http(-1, nil) }
                guard (200..<300).contains(http.statusCode) else {
                    throw APIError.http(http.statusCode, String(data: data, encoding: .utf8))
                }
                return data
            } catch let err as APIError {
                throw err
            } catch is CancellationError {
                // Re-throw raw so callers can detect cancellation.
                throw CancellationError()
            } catch let urlError as URLError where urlError.code == .cancelled {
                throw urlError
            } catch {
                lastError = error
                if attempt < max(0, retries) {
                    try? await Task.sleep(nanoseconds: UInt64((attempt + 1) * 400) * 1_000_000)
                    continue
                }
                throw APIError.transport(error)
            }
        }
        throw APIError.transport(lastError)
    }

    func uploadBlob<T: Decodable>(
        _ path: String,
        field: String,
        filename: String,
        contentType: String,
        data blob: Data,
        authenticated: Bool = false,
        extraFields: [String: String] = [:],
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> T {
        let boundary = "----RCQBoundary\(UUID().uuidString)"
        var body = Data()
        for (name, value) in extraFields {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append(value.data(using: .utf8)!)
            body.append("\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(field)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
        body.append(blob)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        // Always attach the bearer when available — the server uses it
        // for traffic-pay accounting on big uploads. Anonymous uploads
        // (no token set) still pass; the server just falls through to
        // the free-tier path.
        if let token {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let serverToken {
            req.setValue(serverToken, forHTTPHeaderField: "X-RCQ-Auth")
        }
        let localDecoder = self.decoder
        let localSession = self.session
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            let box = UploadObservationBox()
            let task = localSession.uploadTask(with: req, from: body) { responseData, resp, error in
                _ = box.observation
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                guard let http = resp as? HTTPURLResponse, let responseData else {
                    cont.resume(throwing: APIError.http(-1, nil))
                    return
                }
                guard (200..<300).contains(http.statusCode) else {
                    cont.resume(throwing: APIError.http(http.statusCode, String(data: responseData, encoding: .utf8)))
                    return
                }
                do {
                    let value = try localDecoder.decode(T.self, from: responseData)
                    cont.resume(returning: value)
                } catch {
                    cont.resume(throwing: APIError.decoding(error))
                }
            }
            if let onProgress {
                box.observation = task.progress.observe(\.fractionCompleted) { progress, _ in
                    let v = progress.fractionCompleted
                    DispatchQueue.main.async { onProgress(v) }
                }
            }
            task.resume()
        }
    }

    func downloadBlob(_ path: String) async throws -> Data {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "GET"
        if let serverToken {
            req.setValue(serverToken, forHTTPHeaderField: "X-RCQ-Auth")
        }
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.http(-1, nil) }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(http.statusCode, String(data: data, encoding: .utf8))
        }
        return data
    }

    func multipartUpload<T: Decodable>(
        path: String,
        formFields: [String: String],
        fileFieldName: String,
        fileName: String,
        fileMime: String,
        fileBytes: Data
    ) async throws -> T {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        for (name, value) in formFields {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append(value.data(using: .utf8)!)
            body.append("\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(fileFieldName)\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(fileMime)\r\n\r\n".data(using: .utf8)!)
        body.append(fileBytes)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let serverToken {
            req.setValue(serverToken, forHTTPHeaderField: "X-RCQ-Auth")
        }
        req.httpBody = body
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.http(-1, nil) }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(http.statusCode, String(data: data, encoding: .utf8))
        }
        return try decoder.decode(T.self, from: data)
    }
}

struct EmptyResponse: Codable {}

private struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ value: Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

private final class UploadObservationBox: @unchecked Sendable {
    var observation: NSKeyValueObservation?
}

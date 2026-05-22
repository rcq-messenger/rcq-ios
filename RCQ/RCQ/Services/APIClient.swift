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

        if UserDefaults.standard.bool(forKey: key) {
            if await probe(Self.builtInProxyURL) {
                Task.detached { [weak self] in
                    guard let self else { return }
                    if await self.probe(Self.prodBaseURL) {
                        UserDefaults.standard.set(false, forKey: key)
                    }
                }
                return .proxy
            }
            if await probe(Self.prodBaseURL) {
                UserDefaults.standard.set(false, forKey: key)
                return .primary
            }
            return .unreachable
        }

        if await probe(Self.prodBaseURL) { return .primary }
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

    func setToken(_ token: String?) { self.token = token }
    func currentToken() -> String? { token }

    func request<T: Decodable>(
        _ method: String,
        _ path: String,
        body: Encodable? = nil,
        query: [String: String] = [:],
        authenticated: Bool = true
    ) async throws -> T {
        let data = try await rawRequest(method, path, body: body, query: query, authenticated: authenticated)
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
        authenticated: Bool = true
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
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try encoder.encode(AnyEncodable(body))
        }
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
            throw APIError.transport(error)
        }
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
        req.httpBody = body
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.http(-1, nil) }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(http.statusCode, String(data: data, encoding: .utf8))
        }
        return try decoder.decode(T.self, from: data)
    }
}

// MARK: - Reputation

struct ReputationGrantOut: Decodable {
    let targetUIN: Int
    let targetReputation: Int
    let donorBalance: Int

    enum CodingKeys: String, CodingKey {
        case targetUIN = "target_uin"
        case targetReputation = "target_reputation"
        case donorBalance = "donor_balance"
    }
}

/// `grantReputation` returns this on failure — already-localized
/// error string so call sites just display `.message` to the user.
struct ReputationGrantError: Error {
    let message: String
}

extension APIClient {
    /// Grant `amount` reputation to `targetUIN`, burning `amount` jettons
    /// from the caller's wallet. Returns the post-grant authoritative
    /// totals on success, or a human-readable error string on failure
    /// (already mapped from the typed server error codes).
    func grantReputation(
        targetUIN: Int,
        amount: Int,
        anonymous: Bool
    ) async -> Result<ReputationGrantOut, ReputationGrantError> {
        struct Body: Encodable {
            let target_uin: Int
            let amount: Int
            let anonymous: Bool
        }
        do {
            let out: ReputationGrantOut = try await request(
                "POST", "/reputation/grant",
                body: Body(target_uin: targetUIN, amount: amount, anonymous: anonymous),
            )
            return .success(out)
        } catch APIError.http(402, let body) {
            // Server distinguishes insufficient_tokens, but a single
            // "not enough jettons" line covers the only case where we
            // hit 402 from this path (the wallet check is the only
            // gate). Carry the typed code through for future error UI.
            _ = body
            return .failure(.init(message: "reputation.give.error_insufficient".localized))
        } catch APIError.http(404, _) {
            return .failure(.init(message: "reputation.give.error_target_missing".localized))
        } catch APIError.http(429, _) {
            return .failure(.init(message: "reputation.give.error_rate_limited".localized))
        } catch APIError.http(400, let body) where (body ?? "").contains("self_grant") {
            return .failure(.init(message: "reputation.give.error_self".localized))
        } catch {
            return .failure(.init(message: "reputation.give.error_generic".localized))
        }
    }
}

// MARK: - Jeton reactions

struct JetonReactOut: Decodable {
    let messageID: String
    let totalJetons: Int
    let reactorBalance: Int

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case totalJetons = "total_jetons"
        case reactorBalance = "reactor_balance"
    }
}

struct JetonTotalRow: Decodable {
    let messageID: String
    let totalJetons: Int

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case totalJetons = "total_jetons"
    }
}

struct JetonReactError: Error {
    let message: String
}

extension APIClient {
    func jetonReact(
        groupID: Int,
        messageID: String,
        targetUIN: Int,
        amount: Int
    ) async -> Result<JetonReactOut, JetonReactError> {
        struct Body: Encodable {
            let target_uin: Int
            let amount: Int
        }
        do {
            let out: JetonReactOut = try await request(
                "POST", "/groups/\(groupID)/messages/\(messageID)/jeton-react",
                body: Body(target_uin: targetUIN, amount: amount)
            )
            return .success(out)
        } catch APIError.http(402, _) {
            return .failure(.init(message: "jeton.react.error_insufficient".localized))
        } catch APIError.http(404, _) {
            return .failure(.init(message: "jeton.react.error_target_missing".localized))
        } catch APIError.http(429, _) {
            return .failure(.init(message: "jeton.react.error_rate_limited".localized))
        } catch APIError.http(403, _) {
            return .failure(.init(message: "jeton.react.error_not_member".localized))
        } catch APIError.http(400, let body) where (body ?? "").contains("self_react") {
            return .failure(.init(message: "jeton.react.error_self".localized))
        } catch {
            return .failure(.init(message: "jeton.react.error_generic".localized))
        }
    }

    func fetchGroupJetons(groupID: Int) async throws -> [JetonTotalRow] {
        try await request("GET", "/groups/\(groupID)/jetons")
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

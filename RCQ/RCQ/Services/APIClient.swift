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

    /// Production API host. Both simulator and real-device builds hit this by
    /// default — we've moved off the dev/prod split. To run against a local
    /// backend during development, set the UserDefaults override:
    ///
    ///   xcrun simctl spawn booted defaults write app.rcq.client rcq.baseURL "http://localhost:8000"
    ///
    /// or write the same key from inside a debug Settings screen.
    static let prodBaseURL = "https://api.rcq.app"

    nonisolated let baseURL: URL = APIClient.defaultBaseURL()
    private var token: String?
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = true
        cfg.timeoutIntervalForRequest = 20
        self.session = URLSession(configuration: cfg)

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom(Self.parseDateForExternal)
        self.decoder = dec

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc
    }

    /// Comprehensive date parser. Handles every flavour of ISO8601 / Python isoformat
    /// FastAPI/Pydantic might emit — with or without fractional seconds (3 or 6
    /// digits), with or without timezone, with `Z` or `+00:00` for UTC. Strict
    /// `.iso8601` strategy chokes on microsecond-precision dates, which is what
    /// SQLAlchemy's `datetime.now(timezone.utc)` produces by default.
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
        // Last-ditch: trim fractional digits down to 3 and retry ISO.
        if let cut = trimFraction(str), let d = isoFormatters[0].date(from: cut) { return d }

        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Couldn't parse date string: \(str)"
        )
    }

    /// Sendable wrapper exposing the date parser to non-actor decoders
    /// (e.g. WebSocketService's per-payload group decoding).
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

    private static func defaultBaseURL() -> URL {
        if let override = UserDefaults.standard.string(forKey: "rcq.baseURL"),
           let url = URL(string: override) {
            return url
        }
        return URL(string: prodBaseURL)!
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
        // 204 No Content / any other empty body. Synthesize an
        // empty result for the special-case decodable shapes we
        // commonly use (`EmptyResponse`, `Optional<EmptyResponse>`)
        // so the typical fire-and-forget pattern
        // `let _: EmptyResponse? = try? await ...` doesn't spam the
        // console with "Unexpected end of file" decode failures.
        if data.isEmpty {
            let typeName = String(reflecting: T.self)
            if typeName.contains("EmptyResponse") {
                // `Optional<EmptyResponse>` decodes from `null`
                // (yields `.none`); a non-optional `EmptyResponse`
                // wants `{}`. Try both — first match wins.
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
            // Surface the raw response body so problems like an unexpected date
            // format are visible in Xcode's console without rebuilding instrumentation.
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
        } catch {
            throw APIError.transport(error)
        }
    }

    /// Multipart upload with a single binary field. Returns decoded JSON. Anonymous
    /// upload (no auth header) for sealed media — server stores opaque bytes.
    /// `onProgress` (called on the main queue) ticks 0…1 for the lifetime of the
    /// upload — the bubble UI binds it to a circular progress overlay so the
    /// user sees forward motion instead of a silent void.
    func uploadBlob<T: Decodable>(
        _ path: String,
        field: String,
        filename: String,
        contentType: String,
        data blob: Data,
        authenticated: Bool = false,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> T {
        let boundary = "----RCQBoundary\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(field)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
        body.append(blob)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if authenticated, let token {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        // The async `URLSession.upload(for:from:)` doesn't expose
        // the underlying task, which means there's no handle for
        // KVO progress observation. Drop down to the
        // completion-handler API + `withCheckedThrowingContinuation`
        // so we can observe `task.progress.fractionCompleted` for
        // the lifetime of the upload. The observation is held by
        // the completion-handler closure capture so it stays
        // alive until the task finishes.
        let localDecoder = self.decoder
        let localSession = self.session
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            // Observation lives in a heap box (declared at file scope
            // — generic functions can't host nested class types) so
            // the @Sendable completion closure can hold it without
            // triggering the "captured var mutated after capture"
            // warning. The box is captured into the closure (keeping
            // it alive until the task fires); mutating
            // `box.observation` after task creation is safe because
            // the closure is dormant until the upload completes —
            // there is no concurrent access.
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

    /// Plain GET → raw bytes, no auth. For media downloads (server has only opaque
    /// ciphertext, recipient has the key, they decrypt locally).
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

    /// One-piece multipart upload. Each `formFields` entry becomes a
    /// `name=value` text field; `fileName` / `fileMime` / `fileBytes`
    /// describe the single binary attachment (current callers only
    /// need one — report-with-evidence uses this for the decrypted
    /// media + reason form-pair).
    ///
    /// Returns the decoded response body. Auth header is attached
    /// automatically the same way `request(...)` does.
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

struct EmptyResponse: Codable {}

private struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ value: Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

/// Heap holder for the upload-progress KVO observation. Lives at
/// file scope (not nested in a generic function) and is `@unchecked
/// Sendable` so it can ride inside the `@Sendable` URLSession
/// completion closure without tripping strict-concurrency. See the
/// uploadBlob continuation for the full rationale.
private final class UploadObservationBox: @unchecked Sendable {
    var observation: NSKeyValueObservation?
}

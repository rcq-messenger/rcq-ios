import CryptoKit
import Foundation

@MainActor
final class RelayConfigStore {
    static let shared = RelayConfigStore()

    private static let signingPublicKeyB64 =
        "TY834OFcBvtUqHcnVw/QrPBOaEAZo7a1GAmABMhjkT8="

    private static let endpoint = URL(string: "https://relay.rcq.app/v1/config")!
    private static let cacheFile = "relay-config.json"

    struct RelayEntry: Codable, Equatable {
        let tag: String
        let server: String
        let port: Int
        let uuid: String
        let sni: String
        let publicKey: String
        let shortID: String
        let flow: String
        let priority: Int

        enum CodingKeys: String, CodingKey {
            case tag, server, port, uuid, sni, flow, priority
            case publicKey = "public_key"
            case shortID = "short_id"
        }
    }

    struct Payload: Codable {
        let version: Int
        let issuedAt: String
        let relays: [RelayEntry]

        enum CodingKeys: String, CodingKey {
            case version, relays
            case issuedAt = "issued_at"
        }
    }

    private var cached: [RelayEntry]?

    private init() {
        if let onDisk = Self.loadFromDisk() {
            cached = onDisk.relays.sorted { $0.priority < $1.priority }
        }
    }

    func currentRelays() -> [RelayEntry] {
        if let cached, !cached.isEmpty { return cached }
        return Self.bundledFallback
    }

    func refreshInBackground() {
        Task { await self.refresh() }
    }

    private func refresh() async {
        var req = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let session = URLSession(configuration: .ephemeral)
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            guard let payload = Self.verifyAndDecode(data) else { return }
            let sorted = payload.relays.sorted { $0.priority < $1.priority }
            cached = sorted
            Self.saveToDisk(data)
        } catch {
        }
    }

    // MARK: - Signature verification

    static func verifyAndDecode(_ data: Data) -> Payload? {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard
            let sigB64 = raw["sig"] as? String,
            let sigBytes = Data(base64Encoded: sigB64)
        else { return nil }
        var signedPart = raw
        signedPart.removeValue(forKey: "sig")
        guard let canonical = try? JSONSerialization.data(
            withJSONObject: signedPart,
            options: [.sortedKeys, .withoutEscapingSlashes],
        ) else { return nil }
        let pubKeyBytes = Data(base64Encoded: signingPublicKeyB64) ?? Data()
        guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: pubKeyBytes) else {
            return nil
        }
        guard publicKey.isValidSignature(sigBytes, for: canonical) else {
            return nil
        }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }

    // MARK: - Disk cache

    private static var cacheURL: URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask,
        ).first else { return nil }
        let dir = appSupport.appendingPathComponent("RCQ", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(cacheFile)
    }

    private static func saveToDisk(_ data: Data) {
        guard let url = cacheURL else { return }
        try? data.write(to: url, options: [.atomic])
    }

    private static func loadFromDisk() -> Payload? {
        guard let url = cacheURL, let data = try? Data(contentsOf: url) else { return nil }
        return verifyAndDecode(data)
    }

    // MARK: - Bundled fallback

    private static let bundledFallback: [RelayEntry] = [
        RelayEntry(
            tag: "relay-oracle-il",
            server: "129.159.143.135",
            port: 443,
            uuid: "ff005e0c-175e-4475-a166-eeac88f514e2",
            sni: "www.microsoft.com",
            publicKey: "_Hhc-2pjkvR914mddMdmuoOVaT74vWR8Gby7KmJp9F8",
            shortID: "318567678ac9878e",
            flow: "xtls-rprx-vision",
            priority: 1,
        ),
        RelayEntry(
            tag: "relay-gcp",
            server: "35.238.53.96",
            port: 443,
            uuid: "8e3b35d3-18a6-406d-9ac6-c5558a806663",
            sni: "www.apple.com",
            publicKey: "mQZ8CJeMWyf7oYGWJG8oOI52or2kx4yTthl6AGZkSTw",
            shortID: "b5b8979af1f27aab",
            flow: "xtls-rprx-vision",
            priority: 2,
        ),
        RelayEntry(
            tag: "relay-aws-sg",
            server: "47.129.249.170",
            port: 443,
            uuid: "2b0a3318-7bfc-4ff2-83ae-2f322cb91ef8",
            sni: "www.amazon.com",
            publicKey: "xxasGveo2BtMx4doxftb-AJcvIXL-9LpymZcV9tIRxo",
            shortID: "533142a04b016a00",
            flow: "xtls-rprx-vision",
            priority: 3,
        ),
    ]
}

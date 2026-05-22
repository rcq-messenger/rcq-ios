import Foundation
@preconcurrency import Rcqbox

@MainActor
final class SingBoxTransport {
    static let shared = SingBoxTransport()

    static let localPort = 1089

    private enum Keys {
        static let enabled = "rcq.singbox.enabled"
        static let activePort = "rcq.singbox.activePort"
    }

    private var box: RcqboxBoxService?
    private(set) var isActive = false

    private init() {}

    nonisolated static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Keys.enabled)
    }

    nonisolated static func proxyDictionary() -> [String: Any]? {
        let port = UserDefaults.standard.integer(forKey: Keys.activePort)
        guard port > 0 else { return nil }
        return [
            "SOCKSEnable": 1,
            "SOCKSProxy": "127.0.0.1",
            "SOCKSPort": port,
        ]
    }

    func start() async throws {
        guard !isActive else { return }
        let service = RcqboxBoxService()
        let configJSON = Self.buildConfig(port: Self.localPort)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try service.start(configJSON)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
        box = service
        isActive = true
        UserDefaults.standard.set(Self.localPort, forKey: Keys.activePort)
        print("[SingBoxTransport] started — local proxy 127.0.0.1:\(Self.localPort)")
    }

    func stop() {
        UserDefaults.standard.removeObject(forKey: Keys.activePort)
        isActive = false
        guard let service = box else { return }
        box = nil
        DispatchQueue.global(qos: .utility).async {
            try? service.stop()
        }
        print("[SingBoxTransport] stopped")
    }

    func setEnabled(_ on: Bool) async {
        UserDefaults.standard.set(on, forKey: Keys.enabled)
        if on {
            do { try await start() }
            catch { print("[SingBoxTransport] start failed: \(error)") }
        } else {
            stop()
        }
        await APIClient.shared.applyTransportProxy()
    }

    // MARK: - Config

    private struct Relay {
        let server = "35.238.53.96"
        let port = 443
        let uuid = "8e3b35d3-18a6-406d-9ac6-c5558a806663"
        let sni = "www.microsoft.com"
        let publicKey = "mQZ8CJeMWyf7oYGWJG8oOI52or2kx4yTthl6AGZkSTw"
        let shortID = "b5b8979af1f27aab"
    }

    private static func buildConfig(port: Int) -> String {
        let r = Relay()
        let config: [String: Any] = [
            "log": ["level": "warn"],
            "inbounds": [[
                "type": "mixed",
                "tag": "in",
                "listen": "127.0.0.1",
                "listen_port": port,
            ]],
            "outbounds": [[
                "type": "vless",
                "tag": "out",
                "server": r.server,
                "server_port": r.port,
                "uuid": r.uuid,
                "flow": "xtls-rprx-vision",
                "tls": [
                    "enabled": true,
                    "server_name": r.sni,
                    "utls": ["enabled": true, "fingerprint": "chrome"],
                    "reality": [
                        "enabled": true,
                        "public_key": r.publicKey,
                        "short_id": r.shortID,
                    ],
                ],
            ]],
        ]
        let data = try! JSONSerialization.data(withJSONObject: config)
        return String(decoding: data, as: UTF8.self)
    }
}

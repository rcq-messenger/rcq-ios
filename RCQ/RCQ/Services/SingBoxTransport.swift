import Foundation
import Network
@preconcurrency import Rcqbox

@MainActor
final class SingBoxTransport {
    static let shared = SingBoxTransport()

    static let localPort = 1089

    private enum Keys {
        static let enabled = "rcq.singbox.enabled"
        static let activePort = "rcq.singbox.activePort"
        static let lastGoodRelay = "rcq.singbox.lastGoodRelayTag"
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
        Task.detached(priority: .utility) {
            await Self.refreshLastGoodInBackground()
        }
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

    typealias Relay = RelayConfigStore.RelayEntry

    private static func orderedRelays() -> [Relay] {
        let base = RelayConfigStore.shared.currentRelays()
        guard
            let tag = UserDefaults.standard.string(forKey: Keys.lastGoodRelay),
            let idx = base.firstIndex(where: { $0.tag == tag }),
            idx > 0
        else { return base }
        var out = base
        out.insert(out.remove(at: idx), at: 0)
        return out
    }

    private static func refreshLastGoodInBackground() async {
        let probeOrder = RelayConfigStore.shared.currentRelays()
        let winner: String? = await withTaskGroup(of: String?.self) { group in
            for r in probeOrder {
                group.addTask { await Self.probeTCP(host: r.server, port: r.port) ? r.tag : nil }
            }
            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }
        guard let winner else { return }
        UserDefaults.standard.set(winner, forKey: Keys.lastGoodRelay)
    }

    private static func probeTCP(host: String, port: Int, timeoutSec: Double = 4) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let conn = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(integerLiteral: UInt16(port)),
                using: .tcp,
            )
            let gate = ProbeGate()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if gate.tryClaim() {
                        conn.cancel()
                        cont.resume(returning: true)
                    }
                case .failed, .cancelled:
                    if gate.tryClaim() {
                        cont.resume(returning: false)
                    }
                default: break
                }
            }
            conn.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSec) {
                if gate.tryClaim() {
                    conn.cancel()
                    cont.resume(returning: false)
                }
            }
        }
    }

    private final class ProbeGate: @unchecked Sendable {
        private var claimed = false
        private let lock = NSLock()
        func tryClaim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }
    }

    private static func buildConfig(port: Int) -> String {
        // The bundled Rcqbox.xcframework was built without the
        // `with_quic` Go tag, so any hysteria2 outbound makes
        // sing-box panic at start() with "QUIC is not included in
        // this build". Filter those entries out until the framework
        // is rebuilt; otherwise a single hy2 entry leaking in via a
        // cached signed-config from before the v6 rotation would
        // break stealth for everyone.
        let ordered = orderedRelays().filter { $0.proto == .vless }
        let outbounds: [[String: Any]] = {
            var out: [[String: Any]] = []
            out.append([
                "type": "urltest",
                "tag": "out",
                "outbounds": ordered.map { $0.tag },
                "url": "https://api.rcq.app/health",
                "interval": "5m",
                "tolerance": 50,
            ])
            for r in ordered {
                switch r.proto {
                case .vless:
                    out.append(vlessOutbound(for: r))
                case .hysteria2:
                    continue  // unreachable — filtered above
                }
            }
            return out
        }()
        let config: [String: Any] = [
            "log": ["level": "warn"],
            "inbounds": [[
                "type": "mixed",
                "tag": "in",
                "listen": "127.0.0.1",
                "listen_port": port,
            ]],
            "outbounds": outbounds,
        ]
        let data = try! JSONSerialization.data(withJSONObject: config)
        return String(decoding: data, as: UTF8.self)
    }

    private static func vlessOutbound(for r: Relay) -> [String: Any] {
        [
            "type": "vless",
            "tag": r.tag,
            "server": r.server,
            "server_port": r.port,
            "uuid": r.uuid ?? "",
            "flow": r.flow ?? "xtls-rprx-vision",
            "tls": [
                "enabled": true,
                "server_name": r.sni,
                "utls": ["enabled": true, "fingerprint": "chrome"],
                "reality": [
                    "enabled": true,
                    "public_key": r.publicKey ?? "",
                    "short_id": r.shortID ?? "",
                ],
            ],
        ]
    }

    /// Hysteria2 outbound. UDP transport with Salamander obfuscation
    /// wrapping every QUIC packet so DPI cannot fingerprint the
    /// handshake. `insecure: true` because the relay carries a self-
    /// signed certificate; auth is established out-of-band through the
    /// user password + obfs password rather than via PKI.
    private static func hysteria2Outbound(for r: Relay) -> [String: Any] {
        var node: [String: Any] = [
            "type": "hysteria2",
            "tag": r.tag,
            "server": r.server,
            "server_port": r.port,
            "password": r.password ?? "",
            "tls": [
                "enabled": true,
                "server_name": r.sni,
                "insecure": true,
            ],
        ]
        if let obfs = r.obfsPassword, !obfs.isEmpty {
            node["obfs"] = [
                "type": "salamander",
                "password": obfs,
            ]
        }
        return node
    }
}

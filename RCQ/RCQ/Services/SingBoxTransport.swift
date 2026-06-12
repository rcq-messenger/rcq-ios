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
        /// Last error message from `start()`, persisted so the
        /// diagnostics view can surface it. Cleared on next successful
        /// start. Without this any sing-box init failure is invisible
        /// past the splash and there's no signal for "why is stealth
        /// not engaging".
        static let lastError = "rcq.singbox.lastError"
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
        do {
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
        } catch {
            UserDefaults.standard.set(
                String(describing: error).prefix(400).description,
                forKey: Keys.lastError,
            )
            throw error
        }
        box = service
        isActive = true
        UserDefaults.standard.set(Self.localPort, forKey: Keys.activePort)
        UserDefaults.standard.removeObject(forKey: Keys.lastError)
        print("[SingBoxTransport] started — local proxy 127.0.0.1:\(Self.localPort)")
        Task.detached(priority: .utility) {
            await Self.refreshLastGoodInBackground()
        }
    }

    /// Exposes the last `start()` error string to the diagnostics view.
    /// Nil when the last start succeeded (or no start has been
    /// attempted yet).
    nonisolated static var lastStartError: String? {
        let s = UserDefaults.standard.string(forKey: Keys.lastError)
        return (s?.isEmpty ?? true) ? nil : s
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
        let ordered = orderedRelays()
        let vless = ordered.filter { $0.proto == .vless }
        let outbounds: [[String: Any]] = {
            var out: [[String: Any]] = []
            // ONION (M3): when the signed config turns it on AND we have ≥2 VLESS
            // relays, route through a 2-hop chain so no single relay sees the
            // client IP AND the destination island together. A STICKY entry (the
            // first VLESS relay — O4 refines selection) carries opaque tunnels to
            // EXIT relays (each `detour`ed through the entry); a urltest races the
            // EXIT chains so the exit rotates while the entry stays sticky (Tor
            // guard lesson). Falls back to single-hop below when off or <2 VLESS,
            // so connectivity is never worse. Proven via a local sing-box
            // prototype + Android emulator (RCQ/docs/onion-design.md).
            if RelayConfigStore.onionEnabled, vless.count >= 2 {
                let entry = vless[0]
                let exits = Array(vless.dropFirst())
                out.append([
                    "type": "urltest",
                    "tag": "out",
                    "outbounds": exits.map { "onion-\($0.tag)" },
                    "url": "https://api.rcq.app/health",
                    "interval": "5m",
                    "tolerance": 50,
                ])
                var entryOut = vlessOutbound(for: entry)
                entryOut["tag"] = "onion-entry"
                out.append(entryOut)
                for ex in exits {
                    var exOut = vlessOutbound(for: ex)
                    exOut["tag"] = "onion-\(ex.tag)"
                    exOut["detour"] = "onion-entry"
                    out.append(exOut)
                }
                return out
            }
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
                    out.append(hysteria2Outbound(for: r))
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

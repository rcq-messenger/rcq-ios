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
        /// Sticky onion ENTRY guard tag (O4): pin the entry across launches,
        /// rotate only on confirmed block (Tor guard lesson).
        static let onionEntry = "rcq.singbox.onionEntryTag"
        /// Legacy per-device onion opt-in (O5); migrated into transportMode.
        static let onionOptIn = "rcq.singbox.onionOptIn"
        /// Unified transport topology (once enabled): relays | onion | localProxy.
        static let transportMode = "rcq.singbox.transportMode"
        static let lpHost = "rcq.singbox.lpHost"
        static let lpPort = "rcq.singbox.lpPort"
        static let lpType = "rcq.singbox.lpType"   // socks | http
    }

    enum TransportMode: String { case relays, onion, localProxy }

    /// The selected transport topology. `transportMode` is the source of truth;
    /// the first read after upgrade migrates the legacy onion opt-in bool.
    nonisolated static var transportMode: TransportMode {
        if let s = UserDefaults.standard.string(forKey: Keys.transportMode),
           let m = TransportMode(rawValue: s) { return m }
        return UserDefaults.standard.bool(forKey: Keys.onionOptIn) ? .onion : .relays
    }
    nonisolated static func setTransportMode(_ m: TransportMode) {
        UserDefaults.standard.set(m.rawValue, forKey: Keys.transportMode)
    }

    /// Route everything through the user's OWN local SOCKS5/HTTP proxy (Tor/i2p);
    /// exclusive of relays/onion.
    static var localProxyMode: Bool { transportMode == .localProxy }
    nonisolated static var lpHost: String { UserDefaults.standard.string(forKey: Keys.lpHost) ?? "127.0.0.1" }
    nonisolated static var lpPort: Int { let p = UserDefaults.standard.integer(forKey: Keys.lpPort); return p > 0 ? p : 9050 }
    nonisolated static var lpType: String { UserDefaults.standard.string(forKey: Keys.lpType) ?? "socks" }
    nonisolated static func setLocalProxy(host: String, port: Int, type: String) {
        UserDefaults.standard.set(host.trimmingCharacters(in: .whitespaces), forKey: Keys.lpHost)
        UserDefaults.standard.set(port, forKey: Keys.lpPort)
        UserDefaults.standard.set(type == "http" ? "http" : "socks", forKey: Keys.lpType)
    }

    // Legacy onion opt-in shims (the existing onion Settings toggle): route
    // through the unified mode so they can never disagree.
    nonisolated static var onionOptIn: Bool { transportMode == .onion }
    nonisolated static func setOnionOptIn(_ on: Bool) { setTransportMode(on ? .onion : .relays) }

    /// Onion routing is ON when this device selected it OR the signed config
    /// enables it (cohort flip) — EXCEPT an explicit local-proxy choice always
    /// wins (never silently route a Tor-only user through relays). Default OFF.
    static var onionMode: Bool {
        transportMode == .onion || (RelayConfigStore.onionEnabled && transportMode != .localProxy)
    }

    /// Sticky onion ENTRY guard. Returns the persisted entry if it's still a
    /// VLESS relay in `pool`; else picks the highest-priority VLESS (pool is
    /// priority-sorted), persists it, and returns that.
    private static func stickyEntry(_ pool: [Relay]) -> Relay {
        if let tag = UserDefaults.standard.string(forKey: Keys.onionEntry),
           let hit = pool.first(where: { $0.tag == tag }) {
            return hit
        }
        let pick = pool[0]
        UserDefaults.standard.set(pick.tag, forKey: Keys.onionEntry)
        return pick
    }

    /// Rotate the onion ENTRY guard to the next VLESS relay (round-robin),
    /// persisting it. Called when the current entry is confirmed blocked (the
    /// whole onion path dies with its single entry). Returns true when a
    /// different entry was chosen; the caller restarts the transport.
    static func rotateEntry() -> Bool {
        guard !localProxyMode else { return false }   // no onion entry under a user proxy
        let vless = poolRelays().filter { $0.proto == .vless }
        guard vless.count >= 2 else { return false }
        let cur = UserDefaults.standard.string(forKey: Keys.onionEntry)
        let idx = vless.firstIndex(where: { $0.tag == cur }) ?? -1
        let next = vless[(idx + 1) % vless.count]
        guard next.tag != cur else { return false }
        UserDefaults.standard.set(next.tag, forKey: Keys.onionEntry)
        print("[SingBoxTransport] onion entry rotated -> \(next.tag)")
        return true
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

    /// Switch to / from local-proxy transport (route through the user's OWN
    /// local Tor/i2p). Persists mode + the proxy, then rebuilds sing-box
    /// (`start()` only reads `buildConfig` fresh, so stop first when switching
    /// while engaged) and re-points the app proxy — the same serialized path as
    /// `setEnabled`. NO auto-fallback to relays if the proxy is down (that would
    /// leak around Tor); the connect just fails and the user switches back.
    func setLocalProxyEnabled(_ on: Bool, host: String, port: Int, type: String) async {
        if on {
            Self.setLocalProxy(host: host, port: port, type: type)
            Self.setTransportMode(.localProxy)
            UserDefaults.standard.set(true, forKey: Keys.enabled)
        } else {
            Self.setTransportMode(.relays)
            UserDefaults.standard.set(false, forKey: Keys.enabled)
        }
        if isActive { stop() }
        if on {
            do { try await start() }
            catch { print("[SingBoxTransport] local-proxy start failed: \(error)") }
        }
        await APIClient.shared.applyTransportProxy()
    }

    /// One-shot reachability check of a user proxy WITHOUT touching the live
    /// transport: dial the proxy directly via an ephemeral URLSession and GET
    /// /health (judging a 2xx, not a bare socket-open — a SOCKS port can accept
    /// yet the Tor circuit be down). Hard timeout; a dead/DPI'd proxy hangs.
    nonisolated static func testLocalProxy(host: String, port: Int, type: String) async -> Bool {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty, port > 0, port <= 65535 else { return false }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 6
        cfg.timeoutIntervalForResource = 6
        if type == "http" {
            cfg.connectionProxyDictionary = [
                "HTTPEnable": 1, "HTTPProxy": h, "HTTPPort": port,
                "HTTPSEnable": 1, "HTTPSProxy": h, "HTTPSPort": port,
            ]
        } else {
            cfg.connectionProxyDictionary = [
                "SOCKSEnable": 1, "SOCKSProxy": h, "SOCKSPort": port,
            ]
        }
        guard let url = URL(string: "https://api.rcq.app/health") else { return false }
        do {
            let (_, resp) = try await URLSession(configuration: cfg).data(from: url)
            return (resp as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
        } catch {
            return false
        }
    }

    // MARK: - Config

    typealias Relay = RelayConfigStore.RelayEntry

    /// The full relay pool: the verified/bundled signed-config relays PLUS any
    /// relays a contact shared / the user imported (ContactRelayStore). Shared
    /// relays carry priority 1000 so they sort at the BACK = extra fallback
    /// capacity that never displaces a canary-verified relay nor becomes the
    /// onion sticky entry; if every signed-config relay is blocked, the urltest
    /// race lets a working shared relay win. See RCQ/docs/bridge-sharing-design.md.
    static func poolRelays() -> [Relay] {
        let combined = RelayConfigStore.shared.currentRelays()
            + ContactRelayStore.shared.relays()
            + BrokerRelayStore.shared.relays()
        var seen = Set<String>()
        var out: [Relay] = []
        for r in combined where seen.insert("\(r.proto.rawValue):\(r.server):\(r.port)").inserted {
            out.append(r)
        }
        return out
    }

    private static func orderedRelays() -> [Relay] {
        let base = poolRelays()
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
        let probeOrder = poolRelays()
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
            // LOCAL PROXY: a single socks/http outbound to the user's OWN Tor/i2p;
            // no relays, no urltest, no onion. The user's proxy IS the
            // circumvention + metadata layer. Reuse the same mixed inbound so the
            // rest of the pipeline is untouched. NO fallback to relays (that would
            // leak traffic around the user's Tor).
            if Self.localProxyMode {
                var lp: [String: Any] = [
                    "type": Self.lpType == "http" ? "http" : "socks",
                    "tag": "out",
                    "server": Self.lpHost,
                    "server_port": Self.lpPort,
                ]
                if Self.lpType != "http" { lp["version"] = "5" }
                out.append(lp)
                return out
            }
            // ONION (M3): when the signed config turns it on AND we have ≥2 VLESS
            // relays, route through a 2-hop chain so no single relay sees the
            // client IP AND the destination island together. A STICKY entry (the
            // first VLESS relay — O4 refines selection) carries opaque tunnels to
            // EXIT relays (each `detour`ed through the entry); a urltest races the
            // EXIT chains so the exit rotates while the entry stays sticky (Tor
            // guard lesson). Falls back to single-hop below when off or <2 VLESS,
            // so connectivity is never worse. Proven via a local sing-box
            // prototype + Android emulator (RCQ/docs/onion-design.md).
            if Self.onionMode, vless.count >= 2 {
                let entry = stickyEntry(vless)          // O4: persisted guard, not just vless[0]
                let exits = vless.filter { $0.tag != entry.tag }
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

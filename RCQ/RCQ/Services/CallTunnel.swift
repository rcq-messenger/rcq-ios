import Foundation
import Network

/// Carries call media over the same tunnel that carries the messages.
///
/// ⚠⚠ The problem this exists for: the obfuscated connection is applied to this
/// app's URLSession configurations, and WebRTC does not use them. It opens its
/// own sockets. So on a network that blocks RCQ, someone turns on обход, their
/// chats start working, and their calls stay dead — the voice goes out beside
/// the tunnel, into the same block the tunnel exists to get around. No setting
/// could fix it and nothing in the app said so.
///
/// WebRTC takes no proxy, but it does take any address we like and speaks TURN
/// over TCP. So the tunnel is put where it will be used: a listener on loopback
/// that WebRTC dials as if it were the relay next door, forwarding every byte
/// through sing-box's SOCKS inbound to the real one. WebRTC sees a TURN server;
/// the network sees the same tunnel it already lets through.
///
/// ★ Plain `turn:` over TCP on 3478, deliberately, not `turns:` on 443. The
/// tunnel already encrypts and obfuscates what it carries, and the media inside
/// is SRTP either way; a second TLS layer would buy nothing and would break the
/// transparent byte-for-byte forwarding this depends on.
///
/// Android parity: `call/TurnTunnel.kt`.
final class CallTunnel: @unchecked Sendable {

    static let shared = CallTunnel()

    private static let turnTCPPort: UInt16 = 3478

    /// How long [ensureRunning] waits for the listener to come up before giving
    /// the caller an answer. The listener is local, so this is generous.
    private static let readyTimeout: TimeInterval = 2

    private let queue = DispatchQueue(label: "app.rcq.call-tunnel")
    private let lock = NSLock()

    private var listener: NWListener?
    private var upstreamHost: String?
    /// `turn:` URL to hand WebRTC, or nil when the tunnel is not carrying calls
    /// (transport off, no TURN host known yet, or the listener failed).
    private var urlString: String?

    private init() {}

    /// The SOCKS inbound sing-box is listening on, or nil when the transport is
    /// down. Read the same way `SingBoxTransport.proxyDictionary()` reads it, so
    /// this stays callable off the main actor: the key is written on start,
    /// removed on stop, and cleared at launch.
    private static func socksPort() -> UInt16? {
        let p = UserDefaults.standard.integer(forKey: "rcq.singbox.activePort")
        guard p > 0, p <= 65_535 else { return nil }
        return UInt16(p)
    }

    /// The URL to offer ALONGSIDE the island's, or nil to use the island's only.
    ///
    /// Nil is the common case and the right default: with no transport in the
    /// way, going straight to the relay is faster and cheaper for everyone.
    func activeURL() -> String? {
        guard Self.socksPort() != nil else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return urlString
    }

    /// Point the tunnel at the relay the island handed out, and make sure a
    /// listener is up. Cheap to call repeatedly — it only acts on a change.
    func ensureRunning(turnHost: String?) async {
        guard Self.socksPort() != nil, let turnHost, !turnHost.isEmpty else {
            stop()
            return
        }
        lock.lock()
        let unchanged = listener != nil && upstreamHost == turnHost && urlString != nil
        lock.unlock()
        if unchanged { return }

        stop()

        let params = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        // Loopback only. Nothing outside this device may use us as an open
        // relay into the tunnel.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        params.allowLocalEndpointReuse = true

        let created: NWListener
        do {
            created = try NWListener(using: params)
        } catch {
            print("[CallTunnel] listener failed: \(error)")
            return
        }

        lock.lock()
        listener = created
        upstreamHost = turnHost
        lock.unlock()

        created.newConnectionHandler = { [weak self] conn in
            self?.bridge(conn)
        }

        // The port is only known once the listener is ready, so the caller waits
        // for it rather than being handed a URL with no port in it.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let once = TunnelOnce()
            created.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = created.port {
                        self.lock.lock()
                        self.urlString = "turn:127.0.0.1:\(port.rawValue)?transport=tcp"
                        self.lock.unlock()
                        print("[CallTunnel] tunnelling calls: \(port.rawValue) -> \(turnHost):\(Self.turnTCPPort)")
                    }
                    if once.claim() { cont.resume() }
                case .failed(let err):
                    print("[CallTunnel] listener failed: \(err)")
                    if once.claim() { cont.resume() }
                case .cancelled:
                    if once.claim() { cont.resume() }
                default:
                    break
                }
            }
            created.start(queue: queue)
            queue.asyncAfter(deadline: .now() + Self.readyTimeout) {
                if once.claim() { cont.resume() }
            }
        }
    }

    func stop() {
        lock.lock()
        let l = listener
        listener = nil
        urlString = nil
        upstreamHost = nil
        lock.unlock()
        l?.cancel()
    }

    // MARK: - measuring the road

    /// Can a call actually reach TURN through the tunnel right now?
    ///
    /// ⚠⚠ The SOCKS connect is NOT the measurement. sing-box answers a SOCKS
    /// request before it has established the leg outwards, so "connected"
    /// through it says nothing about whether anything is on the other end — a
    /// diagnostic built on that reports a green line for a road nothing can
    /// drive on. Only a byte coming back proves it, so this asks TURN for one:
    /// a STUN Binding Request, answered by a Binding Success.
    func probeThroughTunnel(host: String, timeout: TimeInterval = 8) async -> Bool {
        guard let socks = Self.socksPort(), let socksPort = NWEndpoint.Port(rawValue: socks) else { return false }
        let params = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        let conn = NWConnection(host: .ipv4(.loopback), port: socksPort, using: params)

        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let once = TunnelOnce()
            @Sendable func finish(_ ok: Bool) {
                guard once.claim() else { return }
                conn.cancel()
                cont.resume(returning: ok)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    self.socksConnect(conn, host: host, port: Self.turnTCPPort) { ok in
                        guard ok else { finish(false); return }
                        var req = Data([0x00, 0x01, 0x00, 0x00])          // Binding Request, length 0
                        req.append(contentsOf: [0x21, 0x12, 0xA4, 0x42])  // magic cookie
                        req.append(contentsOf: (0..<12).map { _ in UInt8.random(in: 0...255) })
                        conn.send(content: req, completion: .contentProcessed { err in
                            guard err == nil else { finish(false); return }
                            conn.receive(minimumIncompleteLength: 2, maximumLength: 512) { data, _, _, error in
                                guard error == nil, let data, data.count >= 2 else { finish(false); return }
                                let bytes = [UInt8](data.prefix(2))
                                finish(bytes[0] == 0x01 && bytes[1] == 0x01)  // Binding Success
                            }
                        })
                    }
                case .failed, .cancelled:
                    finish(false)
                default:
                    break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    // MARK: - one connection

    private func bridge(_ client: NWConnection) {
        lock.lock()
        let host = upstreamHost
        lock.unlock()
        guard let host, let socks = Self.socksPort(), let socksPort = NWEndpoint.Port(rawValue: socks) else {
            client.cancel()
            return
        }
        let params = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        // TURN carries latency-sensitive media.
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }
        let upstream = NWConnection(host: .ipv4(.loopback), port: socksPort, using: params)

        client.start(queue: queue)
        upstream.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.socksConnect(upstream, host: host, port: Self.turnTCPPort) { ok in
                    guard ok else {
                        print("[CallTunnel] tunnel leg refused by the relay")
                        client.cancel()
                        upstream.cancel()
                        return
                    }
                    print("[CallTunnel] upstream connected via tunnel")
                    self.pump(client, upstream)
                    self.pump(upstream, client)
                }
            case .failed(let err):
                print("[CallTunnel] upstream failed: \(err)")
                client.cancel()
                upstream.cancel()
            case .cancelled:
                client.cancel()
            default:
                break
            }
        }
        upstream.start(queue: queue)
    }

    /// SOCKS5 CONNECT, with the destination sent as a DOMAIN NAME.
    ///
    /// ★★ The name matters and is the whole reason this is hand-rolled rather
    /// than handed to the system. Every relay's routing table ends in `reject`
    /// and lets through a domain_suffix of rcq.app plus a short list of ip_cidr
    /// — the islands, the fleet, four resolvers. The TURN host's ADDRESS is on
    /// none of those lists, so resolving it here and sending ATYP=1 gets the
    /// connection dropped at the relay, silently and with no bytes back. Sent as
    /// ATYP=3 it matches the rule that was always there.
    ///
    /// Measured on Android before this was ported: a STUN Binding Request
    /// through a relay gets a Binding Success by name and a closed connection by
    /// address, over one and the same tunnel, on all fourteen endpoints of the
    /// signed fleet.
    private func socksConnect(
        _ conn: NWConnection,
        host: String,
        port: UInt16,
        completion: @escaping (Bool) -> Void
    ) {
        let hostBytes = Array(host.utf8)
        guard !hostBytes.isEmpty, hostBytes.count <= 255 else { completion(false); return }

        // Greeting: SOCKS5, one method, "no authentication".
        conn.send(content: Data([0x05, 0x01, 0x00]), completion: .contentProcessed { err in
            guard err == nil else { completion(false); return }
            self.receiveExactly(conn, 2) { greeting in
                guard let greeting, greeting.count == 2,
                      greeting[greeting.startIndex] == 0x05,
                      greeting[greeting.index(after: greeting.startIndex)] == 0x00
                else { completion(false); return }

                var req = Data([0x05, 0x01, 0x00, 0x03, UInt8(hostBytes.count)])
                req.append(contentsOf: hostBytes)
                req.append(UInt8(port >> 8))
                req.append(UInt8(port & 0xFF))

                conn.send(content: req, completion: .contentProcessed { err in
                    guard err == nil else { completion(false); return }
                    // Reply head: VER REP RSV ATYP. Everything after it is the
                    // bound address, whose length depends on ATYP, and it has to
                    // be drained or it would arrive as the first bytes of media.
                    self.receiveExactly(conn, 4) { head in
                        guard let head, head.count == 4 else { completion(false); return }
                        let bytes = [UInt8](head)
                        guard bytes[1] == 0x00 else { completion(false); return }
                        switch bytes[3] {
                        case 0x01:
                            self.receiveExactly(conn, 4 + 2) { completion($0 != nil) }
                        case 0x04:
                            self.receiveExactly(conn, 16 + 2) { completion($0 != nil) }
                        case 0x03:
                            self.receiveExactly(conn, 1) { lenByte in
                                guard let lenByte, let len = lenByte.first else { completion(false); return }
                                self.receiveExactly(conn, Int(len) + 2) { completion($0 != nil) }
                            }
                        default:
                            completion(false)
                        }
                    }
                })
            }
        })
    }

    private func receiveExactly(_ conn: NWConnection, _ n: Int, _ completion: @escaping (Data?) -> Void) {
        conn.receive(minimumIncompleteLength: n, maximumLength: n) { data, _, isComplete, error in
            guard error == nil, !isComplete, let data, data.count == n else {
                completion(nil)
                return
            }
            completion(data)
        }
    }

    private func pump(_ from: NWConnection, _ to: NWConnection) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                to.send(content: data, completion: .contentProcessed { _ in })
            }
            if isComplete || error != nil {
                // Either end closing is the normal way a call ends.
                from.cancel()
                to.cancel()
                return
            }
            self?.pump(from, to)
        }
    }
}

/// One-shot claim, so a continuation is resumed exactly once whichever of
/// ready / failed / timeout gets there first. Same shape as `Once` in
/// NetworkAudit: the lock made it safe all along, but the compiler cannot see
/// that through a closure and Swift 6 rejects a captured `var`.
private final class TunnelOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

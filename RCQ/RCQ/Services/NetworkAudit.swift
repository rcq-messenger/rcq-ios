import Foundation
import Network

/// What this network actually lets through, measured with raw connections.
///
/// The iOS half of the Android `NetworkAudit`, written for the reports that
/// say RCQ does not work under a whitelist. The ordinary diagnostics answer
/// "is the island reachable", which is the one thing already known by the time
/// someone complains. What decides whether anything is worth building is WHY:
///
///   * filtering by NAME (SNI) → another name in front of the same bytes gets
///     through, so fronting and name rotation are worth the work;
///   * filtering by ADDRESS → nothing we claim about ourselves matters, only
///     being hosted somewhere the network already permits;
///   * a permitted control host dead too → the device has no usable internet
///     and none of this is about us.
///
/// The discriminator is what `NWError` already gives us for free: a `.posix`
/// or `.dns` failure means the packets never landed, while a `.tls` failure
/// means our bytes reached a real server and were rejected there. Two crossed
/// probes then settle it:
///
///   A. permitted address + OUR name   → reached ⇒ our name is not what is cut
///   B. our address + permitted name   → reached ⇒ our address is not what is cut
///
/// Deliberately not routed through `APIClient` or the tunnel: this measures
/// the bare network the app is sitting on. Runs only when the user asks, and
/// produces one short line they can copy out, because a device under a
/// whitelist cannot send us anything at the moment it matters.
enum NetworkAudit {

    /// One-shot latch. A continuation must be resumed exactly once, and every
    /// probe here has three racing ways to finish: ready, failed, timeout.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if fired { return false }
            fired = true
            return true
        }
    }


    /// Hosts a network is expected to permit even under a whitelist. If these
    /// are dead the device simply has no internet and nothing else means
    /// anything. Two of them so one operator's quirk does not decide it.
    private static let controlHosts = ["ya.ru", "dzen.ru"]

    enum Verdict: String {
        case allFine = "ALL_FINE"
        /// Messages get through, calls do not. Its own verdict because the two
        /// used to be one, and the one they were was "everything is fine".
        case callsBlocked = "CALLS_BLOCKED"
        case noInternet = "NO_INTERNET"
        case byName = "BY_NAME"
        case byAddress = "BY_ADDRESS"
        case unclear = "UNCLEAR"
    }

    /// Coarse on purpose: the only distinction that matters is whether the
    /// bytes crossed the filter.
    enum Reach: String {
        /// TLS handshake completed.
        case open
        /// Connected and TLS spoke, then failed. It crossed.
        case reached
        /// Never got a usable connection: refused, timed out, or no DNS.
        case blocked

        var short: String {
            switch self {
            case .open: return "ok"
            case .reached: return "reach"
            case .blocked: return "block"
            }
        }
    }

    struct Line: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
        let ok: Bool?
    }

    struct Report {
        let lines: [Line]
        let verdict: Verdict
        let compact: String
    }

    /// One connection attempt to `host:port`, presenting `sni` if given.
    /// Certificate validity is irrelevant to "did the bytes get there", and
    /// the crossed probes deliberately present a name the peer has no
    /// certificate for, so verification is accepted unconditionally. Never
    /// used for real traffic.
    private static func probe(
        host: String,
        port: UInt16,
        sni: String?,
        timeout: TimeInterval = 6
    ) async -> (Reach, String) {
        await withCheckedContinuation { cont in
            let params: NWParameters
            if let sni {
                let tls = NWProtocolTLS.Options()
                sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, sni)
                sec_protocol_options_set_verify_block(
                    tls.securityProtocolOptions,
                    { _, _, complete in complete(true) },
                    DispatchQueue.global()
                )
                params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
            } else {
                params = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
            }
            let conn = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port)!,
                using: params
            )
            // The "did we already answer" flag lives in a reference type, not
            // in a captured `var`: the lock made it safe all along, but the
            // compiler cannot see that through a closure and Swift 6 rejects it.
            let once = Once()
            @Sendable func finish(_ r: Reach, _ detail: String) {
                guard once.claim() else { return }
                conn.cancel()
                cont.resume(returning: (r, detail))
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(.open, sni == nil ? "tcp" : "tls")
                case .failed(let err), .waiting(let err):
                    switch err {
                    case .tls(let status):
                        // Reached a server and was rejected by it, which is a
                        // pass for the question being asked.
                        finish(.reached, "tls \(status)")
                    case .posix(let code):
                        finish(.blocked, "\(code)")
                    case .dns(let code):
                        finish(.blocked, "dns \(code)")
                    default:
                        // Anything else that carries an error is still a
                        // failure to reach, which is all this asks.
                        finish(.blocked, "unknown")
                    }
                default:
                    break
                }
            }
            conn.start(queue: DispatchQueue.global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish(.blocked, "timeout")
            }
        }
    }

    private static func resolve(_ host: String) async -> String? {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                var hints = addrinfo(
                    ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM,
                    ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil
                )
                var res: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else {
                    cont.resume(returning: nil); return
                }
                defer { freeaddrinfo(res) }
                var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let ok = getnameinfo(
                    first.pointee.ai_addr, first.pointee.ai_addrlen,
                    &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST
                ) == 0
                cont.resume(returning: ok ? String(cString: buf) : nil)
            }
        }
    }

    static func run(islandHost: String) async -> Report {
        var lines: [Line] = []

        // 1. Is there any usable internet at all.
        var controlOK = false
        for h in controlHosts {
            let r = await probe(host: h, port: 443, sni: h)
            if r.0 == .open { controlOK = true }
            lines.append(Line(title: "audit.control".localized(h), detail: "\(r.0.rawValue) (\(r.1))", ok: r.0 == .open))
        }

        // 2. Does the name resolve. A whitelist that works via DNS shows here
        //    and nowhere else.
        let islandIP = await resolve(islandHost)
        lines.append(Line(
            title: "audit.dns".localized(islandHost),
            detail: islandIP ?? "audit.dns.fail".localized,
            ok: islandIP != nil
        ))

        // 3. The paths the app itself would take.
        let direct = await probe(host: islandHost, port: 443, sni: islandHost)
        lines.append(Line(title: "audit.direct".localized, detail: "\(direct.0.rawValue) (\(direct.1))", ok: direct.0 == .open))

        let front = RelayConfigStore.frontHost ?? "cdn.rcq.app"
        let frontR = await probe(host: front, port: 443, sni: front)
        lines.append(Line(title: "audit.front".localized(front), detail: "\(frontR.0.rawValue) (\(frontR.1))", ok: frontR.0 == .open))

        let relays = await RelayConfigStore.shared.currentRelays()
        var relaysOpen = 0
        for r in relays {
            let res = await probe(host: r.server, port: UInt16(r.port), sni: nil, timeout: 4)
            if res.0 == .open { relaysOpen += 1 }
        }
        lines.append(Line(
            title: "audit.relays".localized,
            detail: "audit.relays.detail".localized(relaysOpen, relays.count),
            ok: relaysOpen > 0
        ))

        // 4. The crossed pair that names the filter.
        let controlIP = await resolve(controlHosts[0])
        var crossName: (Reach, String)?
        if let ip = controlIP {
            crossName = await probe(host: ip, port: 443, sni: islandHost)
            lines.append(Line(title: "audit.cross.name".localized, detail: "\(crossName!.0.rawValue) (\(crossName!.1))", ok: crossName!.0 != .blocked))
        }
        var crossAddr: (Reach, String)?
        if let ip = islandIP {
            crossAddr = await probe(host: ip, port: 443, sni: controlHosts[0])
            lines.append(Line(title: "audit.cross.addr".localized, detail: "\(crossAddr!.0.rawValue) (\(crossAddr!.1))", ok: crossAddr!.0 != .blocked))
        }

        // 5. The one host every call depends on, which nothing above tests.
        //
        // ⚠⚠ Everything so far measures whether MESSAGES get through. Calls do
        // not use any of it: WebRTC opens its own sockets, straight to the media
        // relay. So a phone that could not place a single call still came back
        // ALL_FINE, and the report that arrived carried that line as proof that
        // nothing was wrong (report #468). A verdict that cannot see the thing
        // that is broken is worse than no verdict.
        var turnOK: Bool?
        // Which road was measured, so the one line a tester sends says so.
        var turnViaTunnel = false
        if let th = CallDiagnostics.turnHost {
            // ⚠ Measure the road the call will actually take. With the tunnel up
            // the media is forwarded through it (CallTunnel), so testing the
            // direct path would condemn a set-up that works; with the tunnel
            // down the media does go straight out, so the direct path is the
            // truth. Same reason either way: report what calls will do, not what
            // some other configuration would have done.
            if await SingBoxTransport.shared.isActive {
                turnViaTunnel = true
                let viaTunnel = await CallTunnel.shared.probeThroughTunnel(host: th)
                turnOK = viaTunnel
                lines.append(Line(
                    title: "audit.turn".localized,
                    detail: (viaTunnel ? "audit.turn.tunnel.ok" : "audit.turn.tunnel.fail").localized,
                    ok: viaTunnel
                ))
            } else {
                // 443 first: it is the port most likely to survive a filter, and
                // the one the island advertises for TURN-over-TLS.
                let tls = await probe(host: th, port: 443, sni: th, timeout: 5)
                let plain = await probe(host: th, port: 3478, sni: nil, timeout: 4)
                let ok = tls.0 != .blocked || plain.0 != .blocked
                turnOK = ok
                lines.append(Line(
                    title: "audit.turn".localized,
                    detail: ok
                        ? String(format: "audit.turn.direct.ok".localized, tls.0.short, plain.0.short)
                        : "audit.turn.direct.fail".localized,
                    ok: ok
                ))
                if !ok {
                    lines.append(Line(
                        title: "audit.turn.advice.title".localized,
                        detail: "audit.turn.advice".localized,
                        ok: nil
                    ))
                }
            }
        }

        let verdict: Verdict
        if !controlOK && direct.0 == .blocked {
            verdict = .noInternet
        } else if direct.0 == .open && turnOK == false {
            // The island answers and the relay does not: messages work, calls
            // cannot. This is the case that used to round up to ALL_FINE.
            verdict = .callsBlocked
        } else if direct.0 == .open {
            verdict = .allFine
        } else if let ca = crossAddr, ca.0 != .blocked {
            // Our address answers under another name → the address is
            // permitted and the name is what gets cut.
            verdict = .byName
        } else if let ca = crossAddr, ca.0 == .blocked, let cn = crossName, cn.0 != .blocked {
            // Our address is dead under any name while a permitted address
            // takes our name → the filter is on the address.
            verdict = .byAddress
        } else {
            verdict = .unclear
        }

        // Short enough to retype off a screen if it comes to that.
        // ⚠ /3 because the line now reports whether CALLS can work, which is
        // what the number tracks across clients. iOS still lacks /2's carrier
        // and udp fields and /3's last-call fields; a field it does not measure
        // is simply absent, as `turn:` is until the first credential fetch.
        let compact = "RCQ-NET/3 "
            + (controlOK ? "ctl:ok " : "ctl:dead ")
            + "dns:\(islandIP != nil ? "ok" : "fail") "
            + "dir:\(direct.0.short) "
            + "front:\(frontR.0.short) "
            + "relay:\(relaysOpen)/\(relays.count) "
            + "xname:\(crossName?.0.short ?? "-") "
            + "xaddr:\(crossAddr?.0.short ?? "-") "
            + (turnOK.map { "turn:\($0 ? (turnViaTunnel ? "tunnel" : "ok") : "BLOCKED") " } ?? "")
            + "=> \(verdict.rawValue)"

        return Report(lines: lines, verdict: verdict, compact: compact)
    }
}

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
    nonisolated static var localProxyMode: Bool { transportMode == .localProxy }
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
    /// VLESS relay in `pool`; else falls back to the highest-priority VLESS
    /// (pool is priority-sorted). The actual SELECTION among trusted entries
    /// (nearest + spread) happens in `selectEntryIfNeeded()` before the config
    /// is built — this reader just resolves the pinned tag into a Relay.
    private static func stickyEntry(_ pool: [Relay]) -> Relay {
        // An account with its own nodes pins one of THOSE, even when a public
        // relay was pinned first. The pin predates the purchase, and honouring it
        // is precisely how a paid endpoint ends up carrying nothing.
        let mineTags = Set(privateVlessEntries().map { $0.tag })
        let mine = pool.filter { mineTags.contains($0.tag) }
        let field = mine.isEmpty ? pool : mine
        if let tag = UserDefaults.standard.string(forKey: Keys.onionEntry),
           let hit = field.first(where: { $0.tag == tag }) {
            return hit
        }
        let pick = field[0]
        UserDefaults.standard.set(pick.tag, forKey: Keys.onionEntry)
        return pick
    }

    /// The account's own paid VLESS endpoints, which outrank every public
    /// candidate for the onion guard.
    ///
    /// The ENTRY is the only relay address the client's network operator ever
    /// sees, so it is the only one worth owning. Every public entry is listed in
    /// the signed config, which is a plain unauthenticated fetch — a blocklist
    /// covering the whole pool costs one download. A private endpoint appears in
    /// no such list (the broker never serves it outside its tenant), so it
    /// outlives that blocklist. The EXIT deliberately stays public: it is
    /// invisible from the client's side, so owning it buys nothing, and it is
    /// where a paying customer's traffic mixes with everybody else's.
    static func privateVlessEntries() -> [Relay] {
        BrokerRelayStore.shared.privateRelays().filter { $0.proto == .vless }
    }

    /// VLESS relays eligible to be the onion ENTRY (hydra step 3). An entry sees
    /// the client IP (but never the destination), so it must be VETTED — which
    /// reads as "curated by us OR owned by you": the account's own paid endpoints
    /// first, then the signed-config relays (Ed25519-curated = trusted by
    /// provenance), then broker relays the operator promoted to `tier=trusted`.
    /// Social-shared relays (ContactRelayStore) are deliberately excluded — they
    /// only ever serve as exits / fallback. Dedup by server:port keeps the first
    /// occurrence, so the paid ordering survives it.
    static func trustedVlessEntries() -> [Relay] {
        let combined = privateVlessEntries()
            + RelayConfigStore.shared.currentRelays()
            + BrokerRelayStore.shared.trustedRelays()
        var seen = Set<String>()
        var out: [Relay] = []
        for r in combined where r.proto == .vless && seen.insert("\(r.server):\(r.port)").inserted {
            out.append(r)
        }
        return out
    }

    /// Hydra step 3: pick the onion ENTRY among TRUSTED VLESS relays by
    /// reachability + NEAREST-with-SPREAD, persisted as the sticky guard. Run
    /// once before building the onion config. A no-op when a valid trusted entry
    /// is already pinned — that preserves the Tor-guard property (pick once,
    /// keep; don't reshuffle every launch). Only the FIRST pick (or a pick after
    /// the pinned entry leaves the trusted set) probes; confirmed-block rotation
    /// is handled separately by `rotateEntry()`. With a single trusted entry this
    /// degrades to today's behaviour; it spreads only once >1 trusted entry
    /// exists (e.g. гидра promotes more domestic relays to trusted).
    ///
    /// An account with its own paid endpoints draws the guard from THOSE, and
    /// only falls back to the public pool when none of them answer — the paid
    /// entry is the product, but a formed chain outranks owning it.
    static func selectEntryIfNeeded() async {
        onionEntryReachable = false
        guard onionMode, !localProxyMode else { return }
        let all = trustedVlessEntries()
        guard !all.isEmpty else { return }   // no trusted entry -> onion can't form -> single-hop fallback
        let mine = privateVlessEntries()
        let field = mine.isEmpty ? all : mine
        // Keep the pinned guard if it's still an eligible candidate, but confirm
        // it's reachable (gates onion-vs-single-hop; a blocked guard => single-hop).
        // A pinned PAID node that went silent falls through to re-selection (its
        // siblings, then the public pool) instead of collapsing the whole chain
        // onto one dead address. Note a public pin under a paying account never
        // matches `field` at all, so the purchase re-pins on its own.
        if let tag = UserDefaults.standard.string(forKey: Keys.onionEntry),
           let pinned = field.first(where: { $0.tag == tag }) {
            onionEntryReachable = await Self.probeLatencyMS(host: pinned.server, port: pinned.port) != nil
            if onionEntryReachable || mine.isEmpty { return }
        }
        var (pickTag, reachable) = await Self.probeAndPick(field)
        if !reachable, !mine.isEmpty {
            (pickTag, reachable) = await Self.probeAndPick(all)
        }
        UserDefaults.standard.set(pickTag, forKey: Keys.onionEntry)
        // Reachable only if the chosen entry answered a probe; an all-probes-failed
        // pick is NOT reachable -> single-hop fallback.
        onionEntryReachable = reachable
        print("[SingBoxTransport] onion entry selected -> \(pickTag) (trusted=\(all.count), paid=\(mine.count), reachable=\(reachable))")
    }

    /// Probe `candidates` in parallel and choose a guard among them. Returns the
    /// chosen tag plus whether that candidate actually answered: an
    /// all-probes-failed pick is a spread guess, not a live entry, and the caller
    /// needs to tell the two apart.
    private static func probeAndPick(_ candidates: [Relay]) async -> (String, Bool) {
        let measured: [(tag: String, ms: Double)] = await withTaskGroup(of: (String, Double?).self) { group in
            for c in candidates {
                group.addTask { (c.tag, await Self.probeLatencyMS(host: c.server, port: c.port)) }
            }
            var ok: [(tag: String, ms: Double)] = []
            for await (tag, ms) in group { if let ms { ok.append((tag: tag, ms: ms)) } }
            return ok
        }
        // Every probe failed (probing the relay port may itself be filtered):
        // still SPREAD — a random candidate beats always camping on [0].
        if measured.isEmpty { return (candidates.randomElement()!.tag, false) }
        // NEAREST with SPREAD: pick at random among entries within `tolerance`
        // of the fastest, so near-equals share load while a clearly-closer
        // (e.g. domestic) entry still wins.
        let best = measured.map { $0.ms }.min()!
        let tolerance = 50.0   // ms — mirrors the urltest tolerance
        return (measured.filter { $0.ms <= best + tolerance }.randomElement()!.tag, true)
    }

    /// Rotate the onion ENTRY guard to the next VLESS relay (round-robin),
    /// persisting it. Called when the current entry is confirmed blocked (the
    /// whole onion path dies with its single entry). Returns true when a
    /// different entry was chosen; the caller restarts the transport.
    static func rotateEntry() -> Bool {
        guard !localProxyMode else { return false }   // no onion entry under a user proxy
        let cur = UserDefaults.standard.string(forKey: Keys.onionEntry)
        // Rotate only among TRUSTED entries — never onto a community/shared relay
        // that would then see the client IP. A paying account rotates within its
        // OWN nodes while it still has a spare: leaving the paid entry on its
        // first failure would hand it back to the pool it was bought to escape.
        // With one paid node and that node confirmed blocked, the public trusted
        // entries are next in line — connectivity outranks ownership.
        let mine = privateVlessEntries()
        let candidates = (mine.count >= 2 && mine.contains { $0.tag == cur }) ? mine : trustedVlessEntries()
        guard candidates.count >= 2 else { return false }
        let idx = candidates.firstIndex(where: { $0.tag == cur }) ?? -1
        let next = candidates[(idx + 1) % candidates.count]
        guard next.tag != cur else { return false }
        UserDefaults.standard.set(next.tag, forKey: Keys.onionEntry)
        print("[SingBoxTransport] onion entry rotated -> \(next.tag)")
        return true
    }

    // Onion single-hop-first (parity with Android `onionEntryReachable`): set by
    // selectEntryIfNeeded()'s reachability probe; buildConfig degrades onion -> single-hop
    // over TRUSTED relays only when the sticky entry can't carry traffic.
    nonisolated(unsafe) static var onionEntryReachable = false

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
        // Hydra step 3: settle the sticky onion ENTRY (nearest trusted, spread)
        // before the config is built. A no-op when an entry is already pinned or
        // onion is off, so it adds latency only on the first onion engage.
        await Self.selectEntryIfNeeded()
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

    /// What every reachability check fetches: whatever the signed config last
    /// named, else the compiled-in flagship health endpoint.
    ///
    /// ⚠ This one is fetched THROUGH each relay by the selector, so a relay's
    /// allow-list has to permit the host before a payload names it. Relays
    /// derive that list from the same payload but on a timer, and a probe they
    /// do not yet allow makes urltest pick NOTHING — no tunnel at all, for
    /// everyone, exactly when it is needed. Move the relays first
    /// (`relay-lockdown.sh --check`).
    nonisolated static var probeURL: String {
        RelayConfigStore.probeURL ?? "https://api.rcq.app/health"
    }

    /// One-shot reachability check of a user proxy WITHOUT touching the live
    /// transport: dial the proxy directly via an ephemeral URLSession and GET
    /// /health (judging a 2xx, not a bare socket-open — a SOCKS port can accept
    /// yet the Tor circuit be down). Hard timeout; a dead/DPI'd proxy hangs.
    nonisolated static func testLocalProxy(host: String, port: Int, type: String) async -> Bool {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty, port > 0, port <= 65535 else { return false }
        let cfg = URLSessionConfiguration.ephemeral
        // 25s, not 6s: i2p/Tor can take many seconds to build the first circuit, so
        // a too-short Test wrongly reports a WORKING proxy as unreachable (the i2p
        // "works in Telegram but the RCQ Test fails" report).
        cfg.timeoutIntervalForRequest = 25
        cfg.timeoutIntervalForResource = 25
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
        guard let url = URL(string: Self.probeURL) else { return false }
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

    /// Like `probeTCP` but returns the TCP-connect latency in milliseconds (nil
    /// on failure/timeout). Used to rank trusted onion-entry candidates.
    private static func probeLatencyMS(host: String, port: Int, timeoutSec: Double = 4) async -> Double? {
        await withCheckedContinuation { (cont: CheckedContinuation<Double?, Never>) in
            let conn = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(integerLiteral: UInt16(port)),
                using: .tcp,
            )
            let gate = ProbeGate()
            let start = DispatchTime.now()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if gate.tryClaim() {
                        let ms = Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
                        conn.cancel()
                        cont.resume(returning: ms)
                    }
                case .failed, .cancelled:
                    if gate.tryClaim() { cont.resume(returning: nil) }
                default: break
                }
            }
            conn.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSec) {
                if gate.tryClaim() {
                    conn.cancel()
                    cont.resume(returning: nil)
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
            if Self.onionMode, vless.count >= 2, Self.onionEntryReachable {
                let entry = stickyEntry(vless)          // O4: persisted guard, not just vless[0]
                // The EXITS stay public even for an account that owns nodes.
                // Nothing on the client's side of the wire ever sees an exit
                // address, so a private one buys no reachability; what it costs is
                // the mixing — a private exit would carry one tenant's traffic and
                // nobody else's, which is the opposite of what the second hop is
                // for. It also keeps the chain buildable with no change to the
                // public relays: the paid ENTRY is the only machine that has to be
                // allowed to forward onward.
                let ownTags = Set(Self.privateVlessEntries().map { $0.tag })
                let others = vless.filter { $0.tag != entry.tag }
                let publicExits = others.filter { !ownTags.contains($0.tag) }
                let exits = publicExits.isEmpty ? others : publicExits
                out.append([
                    "type": "urltest",
                    "tag": "out",
                    "outbounds": exits.map { "onion-\($0.tag)" },
                    "url": Self.probeURL,
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
            // Onion DESIRED but the 2-hop chain can't form (sticky entry unreachable,
            // or <2 VLESS): single-hop race over the TRUSTED signed-config/bundled relays
            // ONLY. Connectivity-first (a trusted single hop beats a dead chain), but it
            // NEVER races the untrusted shared/community pool here — single-hopping an
            // onion user through a relay they didn't vouch for would expose their IP +
            // destination island. The domestic bundled entry keeps this reachable for a
            // blocked user even when the foreign trusted relays are down.
            //
            // The account's OWN endpoints lead this race. Without them a paying
            // customer whose chain failed to form would single-hop over exactly
            // the signed-config addresses a censor downloads in one request — the
            // pool they bought their way out of — while the nodes nobody can
            // enumerate sat unused at the one moment they were needed.
            if Self.onionMode {
                var seenTrusted = Set<String>()
                let trusted = (BrokerRelayStore.shared.privateRelays() + RelayConfigStore.shared.currentRelays())
                    .filter { seenTrusted.insert("\($0.proto):\($0.server):\($0.port)").inserted }
                out.append([
                    "type": "urltest",
                    "tag": "out",
                    "outbounds": trusted.map { $0.tag },
                    "url": Self.probeURL,
                    "interval": "5m",
                    "tolerance": 50,
                ])
                for r in trusted {
                    switch r.proto {
                    case .vless: out.append(vlessOutbound(for: r))
                    case .hysteria2: out.append(hysteria2Outbound(for: r))
                    }
                }
                return out
            }
            // PAID NODES FIRST. Somebody who buys private endpoints was getting
            // them thrown into one latency race against the fourteen everybody
            // has, and losing it about as often as winning: the thing they paid
            // for carried a minority of their traffic. What is sold is a route
            // nobody else is on, so it IS the route.
            //
            // The shared pool stays in the config underneath rather than being
            // dropped: a private node that dies or is blocked must not leave a
            // paying customer worse off than a free one. urltest picks the best
            // LIVE member, so racing the paid nodes against one entry that is
            // itself the shared race gives exactly "theirs while any of theirs
            // answers, everyone's when none do".
            let mineTags = Set(BrokerRelayStore.shared.privateRelays().map { $0.tag })
            let mine = ordered.filter { mineTags.contains($0.tag) }
            let shared = ordered.filter { !mineTags.contains($0.tag) }
            if !mine.isEmpty && !shared.isEmpty {
                out.append([
                    "type": "urltest",
                    "tag": "shared",
                    "outbounds": shared.map { $0.tag },
                    "url": Self.probeURL,
                    "interval": "5m",
                    "tolerance": 50,
                ])
                out.append([
                    "type": "urltest",
                    "tag": "out",
                    "outbounds": mine.map { $0.tag } + ["shared"],
                    "url": Self.probeURL,
                    "interval": "5m",
                    // Wide, so a shared node a few tens of milliseconds quicker
                    // cannot pull a paying customer off their own node. Only a
                    // real failure should.
                    "tolerance": 3000,
                ])
            } else {
                out.append([
                    "type": "urltest",
                    "tag": "out",
                    "outbounds": ordered.map { $0.tag },
                    "url": Self.probeURL,
                    "interval": "5m",
                    "tolerance": 50,
                ])
            }
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

extension SingBoxTransport {
    /// Bring the tunnel up for a destination that is unreachable DIRECTLY, for
    /// callers that reach an island other than the active one.
    ///
    /// The boot ladder in `AppState` only ever probes the ACTIVE base, and the
    /// Cloudflare front only proxies the flagship. So when a network blocks a
    /// DIFFERENT island — a backup home, a visited island, the island hosting a
    /// cross-island group — nothing engaged the transport for it and that island
    /// simply stayed unreachable while everything else looked healthy (a tester
    /// hit exactly this: "the main server started working, is2 did not", with
    /// is2 answering fine from other networks).
    ///
    /// Same guards as the boot-time auto-engage: never against the user's
    /// opt-out, and never in local-proxy mode, where their own proxy is the only
    /// allowed route and stacking sing-box under it would be a leak.
    @discardableResult
    static func engageForBlockedDestination(_ reason: String) async -> Bool {
        if shared.isActive { return true }
        guard !localProxyMode else { return false }
        guard !UserDefaults.standard.bool(forKey: "rcq.singbox.autoDisabled") else { return false }
        do {
            try await shared.start()
        } catch {
            return false
        }
        print("[SingBoxTransport] engaged the tunnel for \(reason) (direct route blocked)")
        return shared.isActive
    }
}

/// HTTP to an island that is not the active one (and to the small number of
/// out-of-band fetches that feed island discovery).
///
/// Every cross-island call used to go through `URLSession.shared`, which carries
/// no proxy configuration at all: on a censored network those calls failed even
/// while the tunnel was up, and they also put the foreign host and our real IP
/// outside a tunnel the user had deliberately engaged. This routes them through
/// the transport when it is active, and — for island hosts — engages it when the
/// direct route to that specific host turns out to be blocked.
enum IslandHTTP {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var session: URLSession?
        /// Separate session for media: same proxy, far longer resource ceiling.
        var transferSession: URLSession?
        /// sing-box local port the cached sessions were built for; -1 = none yet.
        var port = -1
        /// Hosts whose direct route already failed, so the wasted direct attempt
        /// is paid once per host rather than once per call.
        var blocked = Set<String>()
    }

    private static let state = State()

    /// A session carrying the circumvention proxy when it is up. Rebuilt when
    /// the transport starts or stops, which `URLSession.shared` could never do.
    ///
    /// `transfer: true` is for media blobs: the request ceilings that keep a
    /// stuck API call from hanging a chat bubble forever would fail a perfectly
    /// healthy 40 MB deposit over a slow relay, and `URLSession.shared` (which
    /// these calls used before) had no ceiling worth speaking of.
    static func session(transfer: Bool = false) -> URLSession {
        let port = UserDefaults.standard.integer(forKey: "rcq.singbox.activePort")
        state.lock.lock()
        defer { state.lock.unlock() }
        if state.port != port {
            state.session = nil
            state.transferSession = nil
            state.port = port
        }
        if let cached = transfer ? state.transferSession : state.session { return cached }
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = false
        let slowProxy = SingBoxTransport.localProxyMode
        cfg.timeoutIntervalForRequest = slowProxy ? 30 : 20
        cfg.timeoutIntervalForResource = transfer ? (slowProxy ? 300 : 120) : (slowProxy ? 90 : 30)
        if let proxy = SingBoxTransport.proxyDictionary() { cfg.connectionProxyDictionary = proxy }
        let built = URLSession(configuration: cfg)
        if transfer { state.transferSession = built } else { state.session = built }
        return built
    }

    static func data(
        for request: URLRequest,
        allowTunnelFallback: Bool = true,
        transfer: Bool = false,
    ) async throws -> (Data, URLResponse) {
        try await run(host: request.url?.host, allowTunnelFallback: allowTunnelFallback, transfer: transfer) {
            try await $0.data(for: request)
        }
    }

    static func data(
        from url: URL,
        allowTunnelFallback: Bool = true,
        transfer: Bool = false,
    ) async throws -> (Data, URLResponse) {
        try await run(host: url.host, allowTunnelFallback: allowTunnelFallback, transfer: transfer) {
            try await $0.data(from: url)
        }
    }

    static func upload(
        for request: URLRequest,
        from body: Data,
        allowTunnelFallback: Bool = true,
    ) async throws -> (Data, URLResponse) {
        try await run(host: request.url?.host, allowTunnelFallback: allowTunnelFallback, transfer: true) {
            try await $0.upload(for: request, from: body)
        }
    }

    /// `allowTunnelFallback: false` for hosts that are not islands (the signed
    /// island catalogue on GitHub): route them through an already-running tunnel,
    /// but never turn one ON because a third party is unreachable.
    private static func run(
        host: String?,
        allowTunnelFallback: Bool,
        transfer: Bool,
        _ call: (URLSession) async throws -> (Data, URLResponse),
    ) async throws -> (Data, URLResponse) {
        // The second chokepoint (see `APIClient.rawRequest`). Everything
        // cross-island goes through here: guest registrations and mailbox
        // drains on visited islands, backup-island polls, §5e profile
        // broadcasts, media transfers, deposit tokens. All of it signs with or
        // addresses the REAL identity, so a duress session must not reach it.
        try DuressGate.check()
        let key = host ?? ""
        if allowTunnelFallback, isKnownBlocked(key),
           await SingBoxTransport.engageForBlockedDestination(key) {
            return try await call(session(transfer: transfer))
        }
        do {
            return try await call(session(transfer: transfer))
        } catch {
            // A cancelled request says nothing about the route: the caller gave
            // up (the `ring` probe in `CrossIslandSender` races its request
            // against a 5 s sleep and cancels the loser), and turning that into
            // "blocked", with sing-box started and the host marked for the life
            // of the process, would punish a slow island for being slow.
            if Task.isCancelled || error is CancellationError
                || (error as? URLError)?.code == .cancelled { throw error }
            // Already tunnelled: this is the island or the relay path, and a
            // second attempt would only double the wait. A thrown error here is
            // always transport-level — an HTTP status comes back in the response.
            guard allowTunnelFallback,
                  SingBoxTransport.proxyDictionary() == nil,
                  await SingBoxTransport.engageForBlockedDestination(key)
            else { throw error }
            markBlocked(key)
            return try await call(session(transfer: transfer))
        }
    }

    private static func isKnownBlocked(_ host: String) -> Bool {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.blocked.contains(host)
    }

    private static func markBlocked(_ host: String) {
        state.lock.lock()
        defer { state.lock.unlock() }
        state.blocked.insert(host)
    }
}

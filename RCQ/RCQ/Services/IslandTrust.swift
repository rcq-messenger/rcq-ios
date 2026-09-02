import Combine
import CryptoKit
import Foundation
import Security

/// An island trusted by its fingerprint, not by a certificate authority.
///
/// The one place every TLS connection to an island passes through
/// (docs/island-fingerprint-design.md §1-§5, §7.2): a `URLSessionDelegate`
/// that every island session is built with, the pin store behind it, and the
/// pure rule both are made of. A chain the platform trusts is accepted as
/// before, so Let's Encrypt renewals never warn; the store governs the
/// certificates the platform does NOT trust, and there it is SSH's rule: the
/// first certificate seen for `host:port` is remembered and said out loud once,
/// a different one later is REFUSED until the person decides.
///
/// ⚠⚠ `decide` runs on BOTH outcomes of platform validation, and the success
/// branch WRITES a `ca` record. That write is the whole point: a client that
/// consults the store only when the platform refuses has no `ca` records, and
/// for it every island used for months over Let's Encrypt is still an unknown
/// island that an attacker's self-signed certificate takes on first use. So
/// the success branch never answers `.performDefaultHandling`, which would
/// skip `decide` and the write with it.
///
/// ⚠⚠ A typed fingerprint wins over an authority. `host#fp` is the island's
/// identity handed over out of band, and nothing that arrives over the network,
/// a CA's signature included, overrides it: whoever can obtain a certificate
/// the platform trusts for the address (Let's Encrypt issues for IP literals)
/// would otherwise replace the typed pin silently and take the session token.
///
/// ⚠⚠ A refusal is a refusal, and NOT a blocked route. A `.rcq` page renders
/// under a changed key with a banner because a reader can judge a page; a
/// connection that carries a session token cannot be judged, so the challenge
/// is cancelled and not a byte of the request goes out. The transport layer
/// learns it as "reachable, refused" (`Refused`) and must not engage a relay
/// or a front for it, retry it, or report it to the broker as censorship.
///
/// ⚠ Never for relays, the broker, the catalogue, DNS-over-HTTPS or `rcq.app`
/// itself: those sessions are not built with this delegate, and the flagship
/// and the front are CA-only here even when they are, because the one host an
/// attacker would most like to be trusted on first use is the flagship.
///
/// Not `@MainActor`: the challenge arrives on the session's delegate queue in
/// the middle of a handshake, and a pin is a dictionary lookup under a lock,
/// like `SitePins`. Only the published fields are touched on the main thread,
/// for the banner; the refusals the transport layer reads live under the lock.
final class IslandTrust: NSObject, URLSessionDelegate, ObservableObject {
    static let shared = IslandTrust()

    // MARK: - The record (§4)

    enum Mode: String { case ca, pinned }
    enum Source: String { case tofu, typed, accepted }

    /// `{mode: "ca" | "pinned", fp?, source?, since, noticed?}`, keyed
    /// `host:port` in lowercase. Not per account, same reasoning as `SitePins`:
    /// a pin is a statement about an island, not about the reader, and a
    /// per-account store would reset every warning on an account switch, which
    /// is the one moment a warning is worth most.
    struct Record: Equatable {
        var mode: Mode
        var fp: String?
        var source: Source?
        var since: Int
        var noticed: Bool

        init(mode: Mode, fp: String? = nil, source: Source? = nil, since: Int, noticed: Bool) {
            self.mode = mode
            self.fp = fp
            self.source = source
            self.since = since
            self.noticed = noticed
        }

        init?(_ dict: [String: Any]) {
            guard let m = dict["mode"] as? String, let mode = Mode(rawValue: m) else { return nil }
            self.mode = mode
            self.fp = dict["fp"] as? String
            self.source = (dict["source"] as? String).flatMap(Source.init(rawValue:))
            self.since = dict["since"] as? Int ?? 0
            self.noticed = dict["noticed"] as? Bool ?? false
        }

        var dictionary: [String: Any] {
            var d: [String: Any] = ["mode": mode.rawValue, "since": since, "noticed": noticed]
            if let fp { d["fp"] = fp }
            if let source { d["source"] = source.rawValue }
            return d
        }
    }

    enum Decision: Equatable {
        case accept
        case acceptFirstUse(fp: String)
        case refuseCAOnly
        /// `old` is nil when the island validated through a CA before: a known
        /// island cannot be downgraded silently. `typed` when the pin on file
        /// was entered by hand (§3), which is a different sentence to show.
        /// `ca` when the refused chain was CA-valid, which can only happen over
        /// a typed pin: accepting that records `ca`, because pinning a leaf an
        /// authority rotates would bring the banner back at the next renewal.
        case refuseChanged(old: String?, new: String, typed: Bool, ca: Bool)
    }

    /// One island refused on this run. `host` is the authority a person reads
    /// (`host[:port]`), `key` the store's. `entered` says the NEW value came
    /// from an address form (§3), not from the network: accepting it records
    /// `typed`, the source the person meant.
    struct Change: Equatable, Identifiable {
        let key: String
        let host: String
        let old: String?
        let new: String
        let typed: Bool
        let ca: Bool
        let entered: Bool
        var id: String { key }

        /// The typed address with its fragment replaced by what was just
        /// accepted, so a form's next attempt agrees with the record: a
        /// fragment left over from before the choice would be refused again
        /// on the very next tap. A `ca` acceptance carries no fragment.
        func rewriting(_ typedAddress: String) -> String {
            let address = IslandTrust.splitAddress(typedAddress).address
            return ca ? address : "\(address)#\(new)"
        }
    }

    struct FirstUse: Equatable, Identifiable {
        let key: String
        let host: String
        let fp: String
        var id: String { key }
    }

    /// The task error behind a cancelled challenge, once the caller has asked
    /// `refusal(for:url:)`: what `APIClient.probeDirectReachable` turns into
    /// `.refused` and what `IslandHTTP` and the socket stop retrying on.
    struct Refused: Error, LocalizedError, Equatable {
        let host: String
        let old: String?
        let new: String
        let ca: Bool
        var errorDescription: String? { "island \(host) refused: certificate changed" }
    }

    /// Islands refused for presenting a certificate other than the one on
    /// file, keyed like the store. The banner draws from here and nothing else
    /// in the app has to remember to check. In memory only: the next connection
    /// refuses again and fills it back in.
    @Published private(set) var changed: [String: Change] = [:]
    /// First uses not yet dismissed, oldest first. Survives a relaunch through
    /// the record's `noticed` flag, so a notice the person never saw is not
    /// lost with the process.
    @Published private(set) var firstUses: [FirstUse] = []
    /// Bumped on every store write, so a Settings row reading the store
    /// redraws when a handshake behind it changes what is on file.
    @Published private(set) var revision: Int = 0

    // MARK: - The store

    private static let storeKey = "rcq.islandPins.v1"
    private let defaults: UserDefaults
    private let lock = NSLock()
    /// The same refusals as `changed`, readable off the main thread: the
    /// delegate queue records one here first, and the task's failure callback,
    /// wherever it lands, finds it.
    private var refusals: [String: Change] = [:]

    /// The hosts never trusted on first use beyond the `rcq.app` suffix rule:
    /// the flagship, the built-in front and the front the signed config last
    /// named. A closure rather than a direct read of `APIClient` and
    /// `RelayConfigStore`, so this file compiles on its own for the check under
    /// `Tools/IslandTrustCheck`; `RCQApp.init` sets it once. Read at decision
    /// time, so a config push that moves the front takes effect without a
    /// relaunch, exactly like `APIClient.proxyURL`.
    nonisolated(unsafe) static var caOnlyHostsProvider: () -> [String] = { [] }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        // Notices the person has not dismissed yet. No subscribers exist at
        // this point, so the published field can be set from any thread.
        firstUses = read().compactMap { key, rec in
            guard rec.mode == .pinned, rec.source == .tofu, !rec.noticed, let fp = rec.fp,
                  let end = Self.endpoint(fromKey: key) else { return nil }
            return FirstUse(key: key, host: end.authority, fp: fp)
        }
        .sorted { $0.key < $1.key }
    }

    // MARK: - The fingerprint (§2)

    /// SHA-256 over the DER of the leaf exactly as presented: what
    /// `openssl x509 -noout -fingerprint -sha256` prints. Not the SPKI hash,
    /// which survives a re-issue with the same key; that matters for a CA
    /// certificate that rotates every two months and not for a ten-year
    /// self-signed one, and when an operator re-issues they announce the new
    /// fingerprint like an SSH host key.
    static func fingerprint(of leafDER: Data) -> String {
        SHA256.hash(data: leafDER).map { String(format: "%02x", $0) }.joined()
    }

    /// Canonical form from anything a person pastes: uppercase, colons and
    /// spaces straight from openssl are fine; anything else is not a
    /// fingerprint. 64 lowercase hex characters out, or nil.
    static func parseFingerprint(_ raw: String) -> String? {
        var out = ""
        out.reserveCapacity(64)
        for ch in raw.lowercased() {
            if ch == ":" || ch.isWhitespace { continue }
            guard ch.isASCII, ch.isHexDigit else { return nil }
            out.append(ch)
        }
        return out.count == 64 ? out : nil
    }

    /// 16 groups of 4, four groups to a line, for a monospace label.
    static func displayFingerprint(_ fp: String) -> String {
        displayGroups(fp).chunked(4).map { $0.joined(separator: " ") }.joined(separator: "\n")
    }

    /// The same groups on one line, for a fingerprint set inside a sentence.
    static func inlineFingerprint(_ fp: String) -> String {
        displayGroups(fp).joined(separator: " ")
    }

    private static func displayGroups(_ fp: String) -> [String] {
        Array(fp).chunked(4).map { String($0) }
    }

    // MARK: - The address (§3)

    /// What was typed, with the fragment taken off.
    struct Split: Equatable {
        let address: String
        /// The fragment as a canonical fingerprint; nil when there was none or
        /// when it was not one, and `badFragment` tells the two apart. A
        /// fragment that is present and not a fingerprint is a typo in the one
        /// part of the address that must never be guessed at.
        let fingerprint: String?
        let fragment: String?
        var badFragment: Bool { fragment != nil && fingerprint == nil }
    }

    /// `island.example:8443#AB:12:…`, `https://203.0.113.5/#ab12…`: the fragment
    /// comes off FIRST, then the rest is normalised by whoever asked. A pasted
    /// URL keeps working because its fragment is the same character.
    ///
    /// ⚠ First, and by hand: `URL.host` and `URLComponents` drop a fragment
    /// without a word, which would take a first-use pin while the person
    /// believes they pinned, and on a hostile network that pins the attacker
    /// under the cover of the careful path.
    static func splitAddress(_ raw: String) -> Split {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let hash = t.firstIndex(of: "#") else {
            return Split(address: t, fingerprint: nil, fragment: nil)
        }
        let address = String(t[..<hash]).trimmingCharacters(in: .whitespacesAndNewlines)
        let fragment = String(t[t.index(after: hash)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return Split(address: address, fingerprint: parseFingerprint(fragment), fragment: fragment)
    }

    /// One island as the store sees it. `host` is lowercase and carries no
    /// brackets; the two spellings below put them back for an IPv6 literal.
    struct Endpoint: Equatable {
        let host: String
        let port: Int
        var isIPv6: Bool { host.contains(":") }
        private var bracketed: String { isIPv6 ? "[\(host)]" : host }
        /// The store key: `host:port`, the port always written.
        var key: String { "\(bracketed):\(port)" }
        /// What a person types and is handed: `host[:port]`, the port only when
        /// it is not 443, which is the form `install.sh` prints.
        var authority: String { port == 443 ? bracketed : "\(bracketed):\(port)" }
    }

    static func endpoint(host: String, port: Int) -> Endpoint {
        var h = host.lowercased()
        if h.hasPrefix("["), h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        return Endpoint(host: h, port: port)
    }

    /// `is2.rcq.app`, `HTTPS://Island.Example:8443/x/`, `[::1]:8443#fp` → the
    /// endpoint, or nil when there is no host in it. The port defaults to 443
    /// whatever the scheme says: an island speaks TLS or it is not reached.
    ///
    /// ⚠ The host has to come out in the ASCII form the handshake will show.
    /// `protectionSpace.host` is punycode, and `URLComponents.host` hands back
    /// the Unicode spelling of an internationalised name (it even decodes a
    /// punycode input back to it), so keying the store from that filed a typed
    /// pin for `пример.рф` under `пример.рф:443` while every challenge looked
    /// up `xn--e1afmkfd.xn--p1ai:443` and found nothing: the careful path of §3
    /// silently became trust on first use, and a CA-valid certificate an
    /// on-path attacker holds for the address was accepted without a word.
    /// `URL.host` is already punycode and is the same parser the address forms
    /// judge the address with, so the two cannot disagree about what parses.
    static func endpoint(fromAddress raw: String) -> Endpoint? {
        let s = splitAddress(raw).address
        guard !s.isEmpty else { return nil }
        let withScheme = s.contains("://") ? s : "https://\(s)"
        if let url = URL(string: withScheme), let host = url.host, !host.isEmpty {
            return endpoint(host: host, port: url.port ?? 443)
        }
        // `encodedHost`, never `host`: same reason, and it is what the older
        // parser answers when `URL(string:)` refuses a non-ASCII address.
        guard let comps = URLComponents(string: withScheme),
              let host = comps.encodedHost ?? comps.host, !host.isEmpty else { return nil }
        return endpoint(host: host, port: comps.port ?? 443)
    }

    /// The address a form dials, from what was typed: the fragment off, the
    /// scheme put back when there is none, the trailing slash gone. nil when
    /// there is no host in it.
    ///
    /// ⚠ `host[:port]#fp` carries NO scheme: it is what `install.sh` prints
    /// for the operator to hand out and what the Settings row copies (§3, §5.3),
    /// so a form that demanded `https://` refused the exact string we hand out.
    /// The parse is `endpoint(fromAddress:)`, so a form's verdict on an address
    /// and the store key derived from it can never disagree.
    static func dialAddress(_ raw: String) -> String? {
        let s = splitAddress(raw).address
        guard endpoint(fromAddress: s) != nil else { return nil }
        var out = s.contains("://") ? s : "https://\(s)"
        while out.hasSuffix("/") { out.removeLast() }
        return out
    }

    /// The store key read back: `[::1]:8443` → `::1`, 8443.
    static func endpoint(fromKey key: String) -> Endpoint? {
        guard let colon = key.lastIndex(of: ":"), let port = Int(key[key.index(after: colon)...]) else { return nil }
        let host = String(key[..<colon])
        guard !host.isEmpty else { return nil }
        return endpoint(host: host, port: port)
    }

    /// `host[:port]#fp`, ready to hand to somebody.
    static func shareAddress(_ endpoint: Endpoint, fingerprint: String) -> String {
        "\(endpoint.authority)#\(fingerprint)"
    }

    // MARK: - The rule (§1)

    /// `rcq.app` and everything under it, plus whatever `extra` names (the
    /// flagship, the fronts). The suffix rule is deliberate: a host list can be
    /// forgotten, the apex cannot.
    static func isCAOnly(_ host: String, extra: [String]) -> Bool {
        let h = endpoint(host: host, port: 443).host
        if h == "rcq.app" || h.hasSuffix(".rcq.app") { return true }
        return extra.contains { endpoint(fromAddress: $0)?.host == h }
    }

    /// The whole rule, over a dictionary the caller owns. Writes the store
    /// record where §1 says so and nowhere else: a refusal changes nothing on
    /// disk, so the banner keeps appearing until the person decides.
    ///
    /// `caValid` means BOTH gates, chain and name for the host that was
    /// dialled; the delegate below gets it that way from the platform.
    static func decide(
        endpoint: Endpoint,
        fingerprint fp: String,
        caValid: Bool,
        caOnly: Bool,
        now: Int,
        records: inout [String: Record],
    ) -> Decision {
        let key = endpoint.key
        // The flagship is never pinned, typed or not.
        if caOnly { return caValid ? .accept : .refuseCAOnly }
        let rec = records[key]
        if let rec, rec.source == .typed {
            // The fingerprint the person was handed; caValid changes nothing.
            // An authority's signature is not the identity they typed.
            if rec.fp == fp { return .accept }
            return .refuseChanged(old: rec.fp, new: fp, typed: true, ca: caValid)
        }
        if caValid {
            // Overwrite a tofu or accepted pin too: the island moved to a CA,
            // and a private certificate for it from now on is a CHANGE.
            if rec?.mode != .ca {
                records[key] = Record(mode: .ca, since: now, noticed: true)
            }
            return .accept
        }
        guard let rec else {
            records[key] = Record(mode: .pinned, fp: fp, source: .tofu, since: now, noticed: false)
            return .acceptFirstUse(fp: fp)
        }
        // A CA island now shows a private cert.
        if rec.mode == .ca { return .refuseChanged(old: nil, new: fp, typed: false, ca: false) }
        if rec.fp == fp { return .accept }
        return .refuseChanged(old: rec.fp, new: fp, typed: false, ca: false)
    }

    /// The rule over the real store, and the banner state it feeds.
    @discardableResult
    func decide(host: String, port: Int, leafDER: Data, caValid: Bool) -> Decision {
        let end = Self.endpoint(host: host, port: port)
        let fp = Self.fingerprint(of: leafDER)
        let caOnly = Self.isCAOnly(end.host, extra: Self.caOnlyHostsProvider())
        lock.lock()
        var records = read()
        let before = records
        let decision = Self.decide(
            endpoint: end, fingerprint: fp, caValid: caValid, caOnly: caOnly,
            now: Self.now(), records: &records
        )
        let wrote = records != before
        if wrote { write(records) }
        switch decision {
        case .refuseChanged(let old, let new, let typed, let ca):
            refusals[end.key] = Change(key: end.key, host: end.authority, old: old, new: new,
                                       typed: typed, ca: ca, entered: false)
        case .accept, .acceptFirstUse:
            // Back to what is on file (or a CA): the refusal has nothing left
            // to say.
            refusals.removeValue(forKey: end.key)
        case .refuseCAOnly:
            break
        }
        let mirror = refusals
        lock.unlock()

        onMain { [self] in
            if wrote { revision &+= 1 }
            if changed != mirror { changed = mirror }
            if case .acceptFirstUse(let fp) = decision,
               !firstUses.contains(where: { $0.key == end.key }) {
                firstUses.append(FirstUse(key: end.key, host: end.authority, fp: fp))
            }
        }
        return decision
    }

    // MARK: - URLSessionDelegate

    /// `SecTrustEvaluateWithError` on the challenge's trust, whose SSL policy
    /// already names `protectionSpace.host`, so its verdict is chain AND name
    /// together → `caValid`. Then, on BOTH outcomes, the leaf's SHA-256 meets
    /// the rule. An ACCEPT is answered with the trust itself, never with
    /// `.performDefaultHandling`: that would skip `decide`, and with it the
    /// `ca` write a known island's downgrade protection is made of. A REFUSE
    /// cancels the challenge, and the request with it, before a byte is sent.
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void,
    ) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = space.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let caValid = SecTrustEvaluateWithError(trust, nil)
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            // No leaf means nothing to hash and nothing to pin: a handshake
            // without a certificate is not an island.
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let der = SecCertificateCopyData(leaf) as Data
        switch decide(host: space.host, port: space.port, leafDER: der, caValid: caValid) {
        case .accept, .acceptFirstUse:
            completionHandler(.useCredential, URLCredential(trust: trust))
        case .refuseCAOnly, .refuseChanged:
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    // MARK: - What the transport layer asks

    /// The refusal behind a failed task, or nil when the failure was something
    /// else (a dead network, a timeout, the flagship's own TLS). A refusal is
    /// the challenge cancelled by the delegate above, which the loader reports
    /// as a cancelled-authentication or secure-connection error, AND a
    /// refusal on record for that `host:port`. Both, so a plain outage on an
    /// island whose banner is up still reads as an outage.
    func refusal(for error: Error, url: URL?) -> Refused? {
        guard let url, let host = url.host else { return nil }
        let end = Self.endpoint(host: host, port: url.port ?? 443)
        lock.lock()
        let change = refusals[end.key]
        lock.unlock()
        guard let change else { return nil }
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return nil }
        switch URLError.Code(rawValue: ns.code) {
        case .userCancelledAuthentication, .secureConnectionFailed, .serverCertificateUntrusted,
             .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .clientCertificateRejected, .cancelled:
            return Refused(host: change.host, old: change.old, new: change.new, ca: change.ca)
        default:
            return nil
        }
    }

    /// Whether `host:port` of `url` is refused right now, for a caller with no
    /// error in hand (the socket deciding whether to redial).
    func isRefused(url: URL?) -> Bool {
        guard let url, let host = url.host else { return false }
        return change(forKey: Self.endpoint(host: host, port: url.port ?? 443).key) != nil
    }

    /// The refusal on record for an address a form is about to dial, if any.
    func change(forAddress address: String) -> Change? {
        guard let end = Self.endpoint(fromAddress: address) else { return nil }
        return change(forKey: end.key)
    }

    func change(forKey key: String) -> Change? {
        lock.lock()
        defer { lock.unlock() }
        return refusals[key]
    }

    // MARK: - What the forms and the banner call

    /// The address forms' verdict on what was typed.
    enum Admission: Equatable {
        /// The address without its fragment and with the scheme put back
        /// (`dialAddress`), ready to dial as it stands. When there was a
        /// fragment it is on file as `typed` now, so the first request has to
        /// MATCH and there is no trust on first use at all.
        case admitted(address: String)
        /// A fragment that is not 64 hex: the form says so and dials nothing.
        /// Dropping it and connecting anyway would take a first-use pin while
        /// the person believes they pinned.
        case notAFingerprint
        /// A fragment on a host the rule never pins (§1): an address error.
        case caOnlyHost
        /// The record on file disagrees with the fragment (another
        /// fingerprint, or a CA): the banner, and nothing dialled until the
        /// person chooses. An address that arrives in a chat or an invite for
        /// an island this device already trusts must not be able to replace
        /// that trust because somebody opened it.
        case changed(Change)
    }

    /// The address forms' door (§3). Only a NULL record is pre-pinned, and
    /// silently; a fragment equal to what is on file is a no-op.
    func admit(typed raw: String) -> Admission {
        let split = Self.splitAddress(raw)
        if split.badFragment { return .notAFingerprint }
        let dial = Self.dialAddress(split.address) ?? split.address
        guard let fp = split.fingerprint else { return .admitted(address: dial) }
        // No host in it: the form's own address check says so, in its words,
        // and it cannot disagree with this one -- both parse through
        // `endpoint(fromAddress:)`.
        guard let end = Self.endpoint(fromAddress: split.address) else { return .admitted(address: dial) }
        if Self.isCAOnly(end.host, extra: Self.caOnlyHostsProvider()) { return .caOnlyHost }
        lock.lock()
        var records = read()
        if let rec = records[end.key] {
            if rec.mode == .pinned, rec.fp == fp {
                lock.unlock()
                return .admitted(address: dial)
            }
            let change = Change(key: end.key, host: end.authority,
                                old: rec.mode == .ca ? nil : rec.fp, new: fp,
                                typed: rec.source == .typed, ca: false, entered: true)
            refusals[end.key] = change
            let mirror = refusals
            lock.unlock()
            onMain { [self] in if changed != mirror { changed = mirror } }
            return .changed(change)
        }
        records[end.key] = Record(mode: .pinned, fp: fp, source: .typed, since: Self.now(), noticed: true)
        write(records)
        refusals.removeValue(forKey: end.key)
        let mirror = refusals
        lock.unlock()
        onMain { [self] in
            revision &+= 1
            if changed != mirror { changed = mirror }
        }
        return .admitted(address: dial)
    }

    /// The banner's button: the new fingerprint becomes the one on file, as
    /// `typed` when it came from an address form, as `accepted` when the
    /// island presented it, and as `ca` when the refused chain was CA-valid
    /// (§5.2): pinning a leaf an authority rotates would bring the banner back
    /// at the next renewal.
    func accept(_ change: Change) {
        let rec: Record
        if change.ca {
            rec = Record(mode: .ca, since: Self.now(), noticed: true)
        } else {
            rec = Record(mode: .pinned, fp: change.new, source: change.entered ? .typed : .accepted,
                         since: Self.now(), noticed: true)
        }
        lock.lock()
        var records = read()
        records[change.key] = rec
        write(records)
        refusals.removeValue(forKey: change.key)
        let mirror = refusals
        lock.unlock()
        onMain { [self] in
            revision &+= 1
            if changed != mirror { changed = mirror }
        }
    }

    /// The first-use notice was dismissed: never again for that host.
    func markNoticed(_ notice: FirstUse) {
        lock.lock()
        var records = read()
        if var rec = records[notice.key] {
            rec.noticed = true
            records[notice.key] = rec
            write(records)
        }
        lock.unlock()
        onMain { [self] in firstUses.removeAll { $0.key == notice.key } }
    }

    /// How the island at `address` is trusted, for the Settings row. Nil until
    /// this device has completed a handshake with it.
    func status(forAddress address: String) -> (endpoint: Endpoint, record: Record)? {
        guard let end = Self.endpoint(fromAddress: address) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let rec = read()[end.key] else { return nil }
        return (end, rec)
    }

    func record(forKey key: String) -> Record? {
        lock.lock()
        defer { lock.unlock() }
        return read()[key]
    }

    /// Forget an island: its next connection is a first use again.
    func forget(key: String) {
        lock.lock()
        var records = read()
        records.removeValue(forKey: key)
        write(records)
        refusals.removeValue(forKey: key)
        let mirror = refusals
        lock.unlock()
        onMain { [self] in
            revision &+= 1
            if changed != mirror { changed = mirror }
            firstUses.removeAll { $0.key == key }
        }
    }

    /// The burn. Host-keyed like `IslandLogoStore`, so an account switch never
    /// touches it and the one path that says everything is erased does.
    func wipe() {
        lock.lock()
        defaults.removeObject(forKey: Self.storeKey)
        refusals = [:]
        lock.unlock()
        onMain { [self] in
            revision &+= 1
            changed = [:]
            firstUses = []
        }
    }

    // MARK: - Plumbing

    private static func now() -> Int { Int(Date().timeIntervalSince1970) }

    private func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread { body() } else { DispatchQueue.main.async(execute: body) }
    }

    private func read() -> [String: Record] {
        let raw = defaults.dictionary(forKey: Self.storeKey) as? [String: [String: Any]] ?? [:]
        return raw.reduce(into: [:]) { out, entry in
            if let rec = Record(entry.value) { out[entry.key] = rec }
        }
    }

    private func write(_ records: [String: Record]) {
        defaults.set(records.mapValues { $0.dictionary }, forKey: Self.storeKey)
    }
}

private extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

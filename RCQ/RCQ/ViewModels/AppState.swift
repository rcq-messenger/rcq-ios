import Combine
import CryptoKit
import Foundation
import Network
import SwiftUI

/// Top-level state holder. Wires the WS event stream into services and surfaces
/// pending deep-link targets that views consume.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var booted: Bool = false
    @Published var bootError: String? = nil
    @Published var isOffline: Bool = false
    @Published var bootStatus: BootStatus = .connecting

    // boot() single-flight. AppState is @MainActor but boot() suspends at every
    // await, so concurrent boot() calls (account switch + the error-screen
    // auto-retry every 5s + path-reconnect) interleaved and stomped APIClient's
    // SHARED base — flipping a custom-island boot back to the flagship mid-flight
    // so the island never connected (founder log: base flip-flopped project26 ↔
    // api.rcq.app, UIN 911 booted instead of project26). Run at most ONE boot at a
    // time; concurrent callers are dropped (they retry on their own cadence). No
    // re-run loop (that churned connections → iOS "Cannot allocate memory").
    private var booting = false

    enum BootStatus {
        case connecting
        case engagingStealth
        case stealthActive
    }
    /// Capabilities advertised by the active server via `/server/info`.
    /// Defaults to the permissive "legacy backend" set so pre-flag
    /// servers (and the brief window between boot start and the fetch
    /// landing) keep the same surfaces as before. Reset to
    /// `.defaultLegacy` on every account switch and re-populated by
    /// the next boot.
    @Published var serverCapabilities: ServerCapabilities = .defaultLegacy
    @Published var typingByUIN: [Int: Bool] = [:]
    @Published var pendingAddUIN: Int? = nil
    /// Island host from a contact link's `?h=` (spec §5) — set BEFORE
    /// pendingAddUIN so the observer reads both; nil = same-island link.
    @Published var pendingAddHost: String? = nil
    @Published var pendingOpenChatUIN: Int? = nil
    @Published var pendingOpenGroupID: Int? = nil
    /// Drives the `GroupJoinSheet` when a user taps a shared-group
    /// card from chat. Same deep-link mechanism as the marketplace +
    /// UIN-share flows; cleared by the sheet when it dismisses.
    @Published var pendingJoinGroupID: Int? = nil
    /// §5c: the host island for `pendingJoinGroupID` when the invite link
    /// carried one (`/g/<id>@<host>`); nil = own island.
    @Published var pendingJoinGroupHost: String? = nil
    @Published var pendingOpenPending: Bool = false
    /// Set when a "we answered your report" push is tapped: the reports screen
    /// is opened directly rather than making the user find it in Settings.
    @Published var pendingOpenReports: Bool = false
    /// Tap target for @mentions in group chat. ContactListView shows
    /// `UserInfoView` for the UIN as a sheet.
    @Published var pendingOpenUserProfile: Int? = nil

    /// Server-join request captured from an `rcq://server/<host>?invite=<code>`
    /// deep link (the QR an operator of an invite-only island shares). The root
    /// view presents a confirmation sheet that adds the account with the invite.
    @Published var pendingServerJoin: ServerJoinRequest? = nil

    /// A pending invite-only server join. `host` is a bare domain
    /// (e.g. "island.example.com"); `invite` is nil for an open server link.
    struct ServerJoinRequest: Identifiable, Equatable {
        let id = UUID()
        let host: String
        let invite: String?
    }

    /// Connect-to-web request captured from a scanned `rcq://link?t=<token>&k=<webEphPub>`
    /// QR (shown on chat.rcq.app). The root view presents a confirmation sheet
    /// that seals this account into the one-time relay so the web logs in.
    @Published var pendingWebLink: WebLinkRequest? = nil

    struct WebLinkRequest: Identifiable, Equatable {
        let id = UUID()
        let token: String
        let webPub: String
        /// Client kind from the QR's `c` param ("Desktop"/"Web"), shown in the
        /// phone's Linked-devices list. Defaults to "Web" for old QRs.
        var clientLabel: String = "Web"
    }

    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "rcq.path-monitor")
    private var pendingOnlineSync: Task<Void, Never>?
    /// Fingerprint of the last seen network path (status + interface set).
    /// A VPN drop with Wi-Fi still up keeps `status == .satisfied` so the
    /// offline flag never moves — but the interface list changes, and the
    /// socket left behind is bound to a dead route. Any change while
    /// online forces a redial (debounced below).
    private var lastPathSignature: String?
    private var pendingPathReconnect: Task<Void, Never>?

    /// UserDefaults key for a referral inviter UIN captured before
    /// register. Consumed by the fresh-register path; ignored for
    /// existing accounts.
    static let pendingInviterKey = "rcq.pendingInviterUIN"

    /// UserDefaults key for a server-join invite token, stashed by
    /// `addAccount` and consumed once by the next `/auth/register` (required
    /// only by servers running REGISTRATION_POLICY=invite; ignored otherwise).
    static let pendingServerInviteKey = "rcq.pendingServerInvite"

    /// Seal THIS account into the relay slot for the scanned web client so the
    /// web logs in as the same identity. Builds the LinkBlob (same wire shape as
    /// LinkWebView + web-chat auth.ts), seals it to the web's ephemeral pubkey,
    /// and POSTs it to the one-time relay. Returns false on any failure (no
    /// keys, bad pubkey, expired/taken slot, network). The blob carries recovery
    /// material, so the CALLER must confirm with the user before calling this.
    func linkWeb(_ req: WebLinkRequest) async -> Bool {
        guard let uin = AuthService.shared.ownUIN,
              let identityPrivBytes = KeychainStore.data(KeychainStore.Keys.identityPriv),
              let signingPrivBytes = KeychainStore.data(KeychainStore.Keys.signingPriv),
              let identityPriv = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: identityPrivBytes),
              let signingPriv = try? Curve25519.Signing.PrivateKey(rawRepresentation: signingPrivBytes),
              let webPub = Data(base64Encoded: req.webPub)
        else { return false }
        // Mint a SEPARATE revocable session token for the web device (it also
        // flips the account to multi-device → the server serves v=1). The web
        // carries this token, not the phone's own.
        struct LinkDeviceBody: Encodable { let label: String }
        struct LinkDeviceResp: Decodable { let device_id: String; let token: String }
        let jwt: String
        do {
            let resp: LinkDeviceResp = try await APIClient.shared.request(
                "POST", "/devices/link", body: LinkDeviceBody(label: req.clientLabel)
            )
            jwt = resp.token
        } catch { return false }
        let apiBase = APIClient.shared.baseURL.absoluteString
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let payload: [String: Any] = [
            "uin": uin,
            "jwt": jwt,
            "api_base": apiBase,
            "identity_priv": identityPrivBytes.base64EncodedString(),
            "identity_pub": identityPriv.publicKey.rawRepresentation.base64EncodedString(),
            "signing_priv": signingPrivBytes.base64EncodedString(),
            "signing_pub": signingPriv.publicKey.rawRepresentation.base64EncodedString(),
            "iat": Int(Date().timeIntervalSince1970),
        ]
        do {
            let blobJSON = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            let sealed = try SignalCryptoService.sealForWebLink(blobJSON, recipientWebPub: webPub)
            struct Body: Encodable { let blob: String }
            let _: EmptyResponse = try await APIClient.shared.request(
                "POST", "/link/\(req.token)", body: Body(blob: sealed)
            )
            return true
        } catch {
            return false
        }
    }

    private static func queryParam(_ u: URL, _ name: String) -> String? {
        let v = URLComponents(url: u, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == name })?.value?
            .trimmingCharacters(in: .whitespaces)
        return (v?.isEmpty == false) ? v : nil
    }

    /// True when `url` is one of RCQ's own deep-link forms (rcq:// or an
    /// https rcq.app /s/ /r/ /u/ /g/ path) that `handle(deepLink:)` consumes.
    /// The in-app browser uses this to keep deep links out of the web view.
    nonisolated static func isDeepLink(_ url: URL) -> Bool {
        if url.scheme == "rcq" { return true }
        guard url.scheme == "https" || url.scheme == "http",
              url.host == "rcq.app",
              url.pathComponents.count >= 3 else { return false }
        return ["s", "r", "u", "g"].contains(url.pathComponents[1])
    }

    func handle(deepLink url: URL) {
        // ⚠ Every branch below acts FOR THE REAL ACCOUNT: `rcq://link` seals a
        // web session onto it (handing a browser the whole history), `rcq://add`
        // and `/u/<uin>` send a real contact request under the real uin,
        // `rcq://server` joins an island, `rcq://r` stamps a referrer. A duress
        // session must not be able to do any of it — and a coercer who can open
        // a link (a QR code, a message in another app) can reach all of them
        // without ever touching RCQ's own UI. Dropped silently: a link that
        // does nothing is what a link looks like on a phone with no network.
        guard !PanicPINService.shared.isDecoy else { return }
        // Invite-only server join — rcq://server/<host>?invite=<code> (the
        // QR/link an island operator shares) or https://rcq.app/s/<host>?invite=.
        // `invite` is omitted for an open-server link.
        func inviteParam(_ u: URL) -> String? {
            URLComponents(url: u, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "invite" })?.value
        }
        if url.scheme == "rcq", url.host == "server",
           let host = url.pathComponents.dropFirst().first(where: { !$0.isEmpty }) {
            pendingServerJoin = ServerJoinRequest(host: host, invite: inviteParam(url))
            return
        }
        if (url.scheme == "https" || url.scheme == "http"), url.host == "rcq.app",
           url.pathComponents.count >= 3, url.pathComponents[1] == "s",
           !url.pathComponents[2].isEmpty {
            pendingServerJoin = ServerJoinRequest(host: url.pathComponents[2], invite: inviteParam(url))
            return
        }
        // Connect-to-web — rcq://link?t=<token>&k=<webEphPub> (the QR shown on
        // chat.rcq.app, scanned with the phone's camera). Captures both query
        // params; the root view confirms before sealing the account in.
        if url.scheme == "rcq", url.host == "link" {
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            if let token = q?.first(where: { $0.name == "t" })?.value, !token.isEmpty,
               let webPub = q?.first(where: { $0.name == "k" })?.value, !webPub.isEmpty {
                let c = q?.first(where: { $0.name == "c" })?.value?.trimmingCharacters(in: .whitespaces)
                let label = (c?.isEmpty == false) ? String(c!.prefix(24)) : "Web"
                pendingWebLink = WebLinkRequest(token: token, webPub: webPub, clientLabel: label)
            }
            return
        }
        // Referral link — rcq://r/<uin> or https://rcq.app/r/<uin>.
        if (url.scheme == "rcq" && url.host == "r"),
           let last = url.pathComponents.last, let uin = Int(last), uin > 0 {
            UserDefaults.standard.set(uin, forKey: Self.pendingInviterKey)
            return
        }
        if (url.scheme == "https" || url.scheme == "http"),
           url.host == "rcq.app",
           url.pathComponents.count >= 3,
           url.pathComponents[1] == "r",
           let uin = Int(url.pathComponents[2]), uin > 0 {
            UserDefaults.standard.set(uin, forKey: Self.pendingInviterKey)
            return
        }
        if url.scheme == "rcq", url.host == "add" {
            let uinStr = url.pathComponents.last ?? ""
            if let uin = Int(uinStr), uin > 0 {
                // Spec §5: ?h=<island> makes one scan/tap add a cross-island
                // contact; bare links stay same-island.
                pendingAddHost = Self.queryParam(url, "h")
                pendingAddUIN = uin
            }
            return
        }
        if (url.scheme == "https" || url.scheme == "http"),
           url.host == "rcq.app",
           url.pathComponents.count >= 3,
           url.pathComponents[1] == "u" {
            let uinStr = url.pathComponents[2]
            if let uin = Int(uinStr), uin > 0 {
                pendingAddHost = Self.queryParam(url, "h")
                pendingAddUIN = uin
            }
            return
        }
        // Group share — `rcq://group/<id>` (custom scheme from in-app
        // taps on the share-card) or `https://rcq.app/g/<id>` (the
        // text-paste / browser path). Both route to the same
        // `pendingJoinGroupID`; the JoinSheet handles already-member
        // by jumping the user straight into the group chat instead.
        // §5c: the id segment may carry the group's island as `<id>@<host>`.
        func setJoin(_ seg: String) {
            let at = seg.firstIndex(of: "@")
            let idPart = at.map { String(seg[seg.startIndex..<$0]) } ?? seg
            let hostPart = at.map { String(seg[seg.index(after: $0)...]) }
            guard let gid = Int(idPart), gid > 0 else { return }
            pendingJoinGroupID = gid
            pendingJoinGroupHost = (hostPart?.isEmpty == false) ? hostPart?.lowercased() : nil
        }
        if url.scheme == "rcq", url.host == "group" {
            if let last = url.pathComponents.last { setJoin(last) }
            return
        }
        if (url.scheme == "https" || url.scheme == "http"),
           url.host == "rcq.app",
           url.pathComponents.count >= 3,
           url.pathComponents[1] == "g" {
            setJoin(url.pathComponents[2])
            return
        }
    }

    private var cancellables = Set<AnyCancellable>()
    private var typingTimers: [Int: Timer] = [:]

    private init() {
        WebSocketService.shared.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in self?.handle(event) }
            .store(in: &cancellables)
        // `linkUp` rather than `isConnected`: the latter flips true at
        // task.resume(), before the upgrade even completes, so it says "up" on a
        // route that is being blocked. The ladder must react to the link that
        // carried a frame, not to one we merely opened.
        WebSocketService.shared.$linkUp
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] up in self?.socketStateChanged(up: up) }
            .store(in: &cancellables)
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let offline = path.status != .satisfied
            let signature = "\(path.status)|"
                + path.availableInterfaces.map(\.name).sorted().joined(separator: ",")
            Task { @MainActor in
                self?.handlePathChange(offline: offline, signature: signature)
            }
        }
        pathMonitor.start(queue: pathQueue)
    }

    private func handlePathChange(offline: Bool, signature: String) {
        let wasOffline = isOffline
        let routeChanged = lastPathSignature != nil && lastPathSignature != signature
        lastPathSignature = signature
        isOffline = offline
        // Coming back online after an offline boot — replay the network
        // half of the boot sequence so caches/contacts/wallet sync up.
        if wasOffline && !offline && booted {
            pendingOnlineSync?.cancel()
            pendingOnlineSync = Task { [weak self] in
                await self?.runOnlineSync()
            }
        } else if routeChanged && !offline && booted {
            // Still "online" but the route itself changed (VPN on/off,
            // Wi-Fi ↔ cellular). Redial through the new route instead of
            // letting the old socket sit half-dead for the full watchdog
            // window. Debounced: NWPathMonitor fires several updates during
            // one transition.
            pendingPathReconnect?.cancel()
            pendingPathReconnect = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self, !Task.isCancelled, !self.isOffline else { return }
                WebSocketService.shared.reconnectNow()
            }
        }
    }

    private func runOnlineSync() async {
        guard !PanicPINService.shared.isDecoy else { return }
        guard let uin = AuthService.shared.ownUIN,
              let token = KeychainStore.string(KeychainStore.Keys.token) else { return }
        let baseURL = APIClient.shared.baseURL
        let serverToken = AccountManager.shared.active?.serverToken
        WebSocketService.shared.connect(uin: uin, token: token, baseURL: baseURL, serverToken: serverToken)
        await syncOwnPresenceFromServer(uin: uin)
        await ContactService.shared.refresh()
        await GroupService.shared.refresh()
        await MessageService.shared.fetchOfflineQueue()
    }

    /// elapsedRealtime-ish stamp of the last ladder walk, so a flapping socket
    /// cannot spend the session probing instead of talking.
    private var lastLadderAt: Date?
    /// When the socket first went down, or nil while it is up.
    private var socketDownSince: Date?
    private var ladderTask: Task<Void, Never>?

    /// How long the socket must stay down before the route is reconsidered. The
    /// socket's own backoff handles a blip; this is for a network that has
    /// STARTED blocking us, which backoff alone never recovers from.
    private static let offlineBeforeLadder: TimeInterval = 90
    /// Floor between two walks. A walk costs several probes and can tear the
    /// tunnel down and back up.
    private static let ladderCooldown: TimeInterval = 300

    /// Called by the socket whenever it goes up or down.
    ///
    /// Until now iOS reconsidered its route at launch and, in one narrow case,
    /// on the fourth failed reconnect — which raised the tunnel but never
    /// re-probed the front and never came back to direct. A network that started
    /// blocking mid-session was otherwise retried forever against the dead
    /// route, which from the outside is "RCQ broke" while the bypass sits unused.
    func socketStateChanged(up: Bool) {
        if up {
            socketDownSince = nil
            return
        }
        if socketDownSince == nil { socketDownSince = Date() }
        guard ladderTask == nil else { return }
        ladderTask = Task { [weak self] in
            defer { Task { @MainActor in self?.ladderTask = nil } }
            try? await Task.sleep(nanoseconds: UInt64(Self.offlineBeforeLadder * 1_000_000_000))
            guard let self else { return }
            await self.walkLadderIfStillDown()
        }
    }

    private func walkLadderIfStillDown() async {
        guard let down = socketDownSince, Date().timeIntervalSince(down) >= Self.offlineBeforeLadder else { return }
        if let last = lastLadderAt, Date().timeIntervalSince(last) < Self.ladderCooldown { return }
        lastLadderAt = Date()
        print("[route] offline \(Int(Date().timeIntervalSince(down)))s — walking the route ladder again")
        let changed = await runRouteLadder()
        print("[route] ladder done, changed=\(changed) tunnel=\(SingBoxTransport.shared.isActive)")
        if changed { WebSocketService.shared.reconnectNow() }
    }

    /// Direct probe, then the tunnel, then a post-engage check that can drop back
    /// to direct. The same sequence boot runs, pulled out so it can run AGAIN.
    ///
    /// Returns whether the route CHANGED, so the caller knows the socket has to
    /// be rebuilt against it.
    @discardableResult
    func runRouteLadder() async -> Bool {
        let before = SingBoxTransport.shared.isActive
        let autoDisabled = UserDefaults.standard.bool(forKey: "rcq.singbox.autoDisabled")
        var reach = await APIClient.shared.refreshActiveBase()

        if reach == .unreachable, !SingBoxTransport.shared.isActive, !autoDisabled,
           !SingBoxTransport.localProxyMode {
            do {
                try await SingBoxTransport.shared.start()
                await APIClient.shared.applyTransportProxy()
                reach = await APIClient.shared.refreshActiveBase()
            } catch {
                print("[route] transport failed to start: \(error)")
            }
        }

        // Tunnel up and still nothing, while direct works: drop back rather than
        // sit inside a broken tunnel. Never under the user's own local proxy
        // (the Tor-leak rule) or a deliberate onion opt-in, and only when a FRESH
        // direct probe succeeds — a genuinely blocked user must never be silently
        // de-tunnelled.
        if reach == .unreachable, SingBoxTransport.shared.isActive,
           !SingBoxTransport.localProxyMode, !SingBoxTransport.onionOptIn,
           await APIClient.shared.probeDirectReachable() {
            print("[route] tunnel unreachable, direct works — falling back to direct")
            SingBoxTransport.shared.stop()
            await APIClient.shared.useDirectSession()
            reach = await APIClient.shared.refreshActiveBase()
        }

        if reach != .unreachable { isOffline = false }
        return SingBoxTransport.shared.isActive != before
    }

    private func scheduleTransportRetry() {
        guard SingBoxTransport.shared.isActive else { return }
        pendingOnlineSync?.cancel()
        pendingOnlineSync = Task { [weak self] in
            var deadStreak = 0
            for _ in 0..<18 {  // ~3 minutes of 10s retries
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if Task.isCancelled { return }
                guard let self, self.isOffline else { return }
                let reach = await APIClient.shared.refreshActiveBase()
                if reach != .unreachable {
                    self.isOffline = false
                    await self.runOnlineSync()
                    return
                }
                // O4b onion ENTRY-guard rotation: if onion is on and the route
                // has stayed dead for ~1 min, the sticky ENTRY is likely blocked
                // (the whole 2-hop path dies with its single entry) — rotate to
                // the next entry and rebuild the transport so a blocked guard
                // self-heals. Dormant unless onion is enabled (off by default).
                deadStreak += 1
                if SingBoxTransport.onionMode, deadStreak >= 6, SingBoxTransport.rotateEntry() {
                    deadStreak = 0
                    SingBoxTransport.shared.stop()
                    try? await SingBoxTransport.shared.start()
                    await APIClient.shared.applyTransportProxy()
                }
            }
        }
    }

    func boot(suggestedNickname: String? = nil) async {
        // Single-flight: drop a boot request while one is already running. The
        // root view is booted → bootError → splash, so a successful boot dismisses
        // the error screen on its own; we must NOT clear bootError on entry (that
        // flipped error↔loading every retry — the rapid flicker — and the churn
        // exhausted iOS network flows).
        if booting { return }
        booting = true
        defer { booting = false }
        await doBoot(suggestedNickname: suggestedNickname)
    }

    private func doBoot(suggestedNickname: String? = nil) async {
        // ⚠ FIRST, AND WITH NO CONDITIONS. The decoy arm used to ride on the
        // offline branch further down, which additionally required a non-nil
        // `KeychainStore.string(.token)` — the LEGACY unprefixed slot. An
        // account whose token lives only in its per-account slot (any
        // self-host account, or any account past the first) answers nil there,
        // so a decoy session fell straight through to the full network boot
        // and connected the socket with the REAL account's credentials.
        //
        // `isOffline = false` because the duress view presents as connected:
        // it has no server account, and a messenger that permanently advertises
        // "offline" is the tell the decoy exists to remove.
        if PanicPINService.shared.isDecoy {
            isOffline = false
            MessageService.shared.configure(ownUIN: AuthService.shared.ownUIN ?? 0)
            booted = true
            return
        }

        // (relay-list + broker refresh moved BELOW the transport-engage block so a
        // blocked user pulls them THROUGH the tunnel — see after the reachability
        // gate. Android orders it the same way.)
        // Push the active account's masquerade token to APIClient
        // BEFORE any HTTP fires. Defaults to nil for public backends
        // (api.rcq.app), set per-account by the operator at add-time
        // for self-host instances behind a Caddy `X-RCQ-Auth` gate.
        // Without this header, those backends serve a decoy static
        // site instead of FastAPI — `/health` and `/auth/register`
        // would both 404 to the scanner, and to us too if we forget
        // the token.
        await APIClient.shared.setServerToken(AccountManager.shared.active?.serverToken)

        // Offline-first path. If we already have a local identity AND no
        // network is available, skip every server-touching call and let
        // the app launch into the local-only surfaces (Radio Chat over
        // Bluetooth, settings, history). The online sync runs as soon
        // as connectivity returns via the NWPathMonitor handler.
        let cachedUIN = AuthService.shared.ownUIN
        let cachedToken = KeychainStore.string(KeychainStore.Keys.token)
        let pathSatisfied = pathMonitor.currentPath.status == .satisfied

        // Fresh install still on the onboarding deck: no account in the roster
        // and no legacy identity to validate. Do NOT auto-register a throwaway
        // identity here — the user hasn't yet chosen "new account" vs "restore
        // from phrase". Registration is minted explicitly when they finish
        // onboarding (RCQApp re-runs boot on `didOnboard`) or recovered by
        // `recoverAccount`. Without this gate a fresh launch registered a UIN
        // into the legacy unprefixed Keychain slot before that choice, leaving
        // an orphan account and poisoning the legacy→account migration for a
        // restored identity. Returning users (roster populated, or a legacy
        // identity AccountManager already wrapped as Account[0]) skip the gate.
        if AccountManager.shared.active == nil, cachedUIN == nil {
            return
        }

        if !pathSatisfied, let uin = cachedUIN, cachedToken != nil {
            isOffline = true
            MessageService.shared.configure(ownUIN: uin)
            booted = true
            return
        }

        // Watchdog: the network branch below can hang on a wedged
        // sing-box start, a dead upstream proxy or a slow TLS
        // handshake against a degraded relay. If 15s pass without
        // booted=true, surrender to offline mode (when we have a
        // cached identity) or surface the unreachable error. Keeps
        // the loading spinner from spinning forever.
        // First-launch registration over a censored network legitimately
        // takes longer (probe direct → engage transport → register through
        // the tunnel), so give a registration boot a longer leash before the
        // watchdog surrenders. Returning users keep the snappy 15s.
        let watchdogSeconds: UInt64 = cachedUIN == nil ? 25 : 15
        let watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: watchdogSeconds * 1_000_000_000)
            guard let self else { return }
            await MainActor.run {
                guard !self.booted else { return }
                if cachedUIN != nil && cachedToken != nil {
                    // Only claim offline if the socket has not already proved
                    // otherwise. The boot chain overrunning fifteen seconds is
                    // a slow server, not a dead network, and this flag is
                    // sticky: nothing here clears it, so one slow start left
                    // the header reading "Offline" with an orange dot long
                    // after the connection was fine, and the client kept
                    // redialing on the strength of it.
                    if !WebSocketService.shared.linkUp {
                        self.isOffline = true
                        self.scheduleTransportRetry()
                    }
                    if let uin = cachedUIN {
                        MessageService.shared.configure(ownUIN: uin)
                    }
                    self.booted = true
                } else {
                    self.bootError = "boot.error.unreachable".localized
                }
            }
        }
        defer { watchdog.cancel() }

        do {
            // First-launch registration over a censored network: bring the
            // embedded transport up BEFORE the first /auth/register if the
            // direct path is blocked, so a brand-new user doesn't have to
            // switch on a VPN just to sign up (mirrors Android's
            // ensureTransportForHost). Only for a fresh install (no cached
            // identity); returning users fall through to the probe chain
            // below, which already auto-engages on an unreachable direct path.
            if cachedUIN == nil,
               !SingBoxTransport.shared.isActive,
               !SingBoxTransport.isEnabled,
               !UserDefaults.standard.bool(forKey: "rcq.singbox.autoDisabled") {
                let directOK = await APIClient.shared.probeDirectReachable()
                if !directOK {
                    bootStatus = .engagingStealth
                    do {
                        try await SingBoxTransport.shared.start()
                        await APIClient.shared.applyTransportProxy()
                    } catch {
                        print("[boot] pre-register transport engage failed: \(error)")
                    }
                }
            }
            bootStatus = .connecting
            if SingBoxTransport.isEnabled {
                bootStatus = .engagingStealth
                do {
                    try await SingBoxTransport.shared.start()
                    await APIClient.shared.applyTransportProxy()
                } catch {
                    print("[boot] sing-box transport failed to start: \(error)")
                }
            }
            // A directly-reachable CUSTOM ISLAND (user-picked rcq.baseURL) must
            // connect DIRECT. The relays/onion exist to reach a BLOCKED flagship;
            // forcing a reachable custom island through a flagship relay stalls the
            // heavier register/sync over the SOCKS proxy past the 25s watchdog,
            // even though a quick /health probe slipped through (the "reachable=true,
            // then Couldn't connect" bug). The flagship keeps its normal behavior.
            let activeBase = APIClient.activeDirectBase()
            if activeBase != APIClient.prodBaseURL, await APIClient.shared.probeDirectReachable() {
                print("[boot] custom island \(activeBase) reachable direct — API session DIRECT (bypassing relays)")
                await APIClient.shared.useDirectSession()
            }
            var reach = await APIClient.shared.refreshActiveBase()
            // Auto-engage when direct is unreachable — unless the user
            // explicitly opted out (they route through their own proxy
            // / VPN and don't want our embedded sing-box on top of
            // theirs). The explicit toggle still wins above; this
            // gates only the "fall back when nothing works" branch.
            let autoDisabled = UserDefaults.standard.bool(forKey: "rcq.singbox.autoDisabled")
            if reach == .unreachable, !SingBoxTransport.shared.isActive, !autoDisabled {
                bootStatus = .engagingStealth
                do {
                    try await SingBoxTransport.shared.start()
                    await APIClient.shared.applyTransportProxy()
                    reach = await APIClient.shared.refreshActiveBase()
                } catch {
                    print("[boot] auto sing-box transport failed: \(error)")
                }
            }
            if reach == .unreachable, SingBoxTransport.shared.isActive {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                reach = await APIClient.shared.refreshActiveBase()
            }
            // Tunnel engaged but STILL unreachable, while a DIRECT connection
            // works — the "Резерв включён, туннель сломан, работает только с VPN"
            // trap for the FLAGSHIP (the useDirectSession bypass above only covers
            // a reachable custom island, not prod). Drop to direct. Mirrors the
            // Android boot fallback. Gated so a genuinely-blocked user is NEVER
            // silently de-tunnelled: only when a fresh direct probe SUCCEEDS, and
            // NEVER under the user's own local proxy (Tor-leak rule) or an explicit
            // onion opt-in (keep the metadata-resistance they deliberately chose).
            if reach == .unreachable, SingBoxTransport.shared.isActive,
               !SingBoxTransport.localProxyMode, !SingBoxTransport.onionOptIn,
               await APIClient.shared.probeDirectReachable() {
                print("[boot] tunnel unreachable, direct works — falling back to direct")
                SingBoxTransport.shared.stop()
                await APIClient.shared.useDirectSession()
                reach = await APIClient.shared.refreshActiveBase()
                bootStatus = .connecting
            }
            if reach != .unreachable, SingBoxTransport.shared.isActive {
                bootStatus = .stealthActive
            }
            if reach == .unreachable {
                if let uin = cachedUIN, cachedToken != nil {
                    isOffline = true
                    MessageService.shared.configure(ownUIN: uin)
                    booted = true
                    scheduleTransportRetry()
                } else {
                    bootError = "boot.error.unreachable".localized
                }
                return
            }
            // Pull the fresh signed-config + broker bridges NOW (not at the top of
            // doBoot) so a BLOCKED user — whose direct fetch to the mirrors/broker
            // would fail — pulls them THROUGH the now-engaged tunnel (both stores
            // route via SingBoxTransport.proxyDictionary() when isActive). Android
            // already orders it this way (Session.kt after engage). Best-effort.
            RelayConfigStore.shared.refreshInBackground()
            BrokerRelayStore.shared.refreshInBackground()   // anti-enumeration bridges -> transport pool
            // Report which known relays are reachable from this network so the
            // broker serves them region-by-region (throttled hourly inside).
            BrokerRelayStore.shared.reportReachabilityInBackground()
            print("[boot] bootstrapIfNeeded… (base=\(APIClient.shared.baseURL.absoluteString))")
            try await AuthService.shared.bootstrapIfNeeded(suggestedNickname: suggestedNickname)
            guard let uin = AuthService.shared.ownUIN,
                  let bootToken = KeychainStore.string(KeychainStore.Keys.token) else {
                throw NSError(domain: "boot", code: 1)
            }
            print("[boot] identity ok uin=\(uin) — syncing")
            MessageService.shared.configure(ownUIN: uin)

            // Name this install to the server if the token predates the claim,
            // BEFORE the websocket dials: the socket authenticates with the
            // token it is handed here, and a token with no `dev` keys it as
            // "primary" — the name every other install of the account uses, so
            // two of them supersede each other's socket in a loop and share one
            // offline-queue cursor.
            let token = await claimInstallTokenIfNeeded(bootToken) ?? bootToken

            // Capability fetch. Failure is non-fatal — we keep the
            // permissive defaultLegacy set, which matches every
            // backend's behaviour before v0.4 added /server/info.
            // Self-host backends running rcq-server-ref return
            // {uin_shop: false} here and SettingsView drops the row
            // entirely; api.rcq.app returns {uin_shop: true} and the
            // surface stays.
            if let caps = await ServerInfoService.fetch() {
                serverCapabilities = caps
                AccountManager.serverMaxAccounts = caps.maxAccountsPerDevice
            }

            let baseURL = APIClient.shared.baseURL
            WebSocketService.shared.connect(
                uin: uin, token: token, baseURL: baseURL,
                serverToken: AccountManager.shared.active?.serverToken
            )

            // Only what the first screen genuinely cannot be drawn without.
            // Contacts because the list IS the first screen; presence because
            // the header renders the person's own status. Both are small.
            await syncOwnPresenceFromServer(uin: uin)
            await ContactService.shared.refresh()

            print("[boot] complete — booted")
            booted = true

            // Everything else finishes behind the interface.
            //
            // These nine calls used to run one after another with `booted`
            // waiting at the end of them, so the splash stayed up for the sum
            // of the whole chain. Two of them are why that hurt: `/groups`
            // serialises every member of every group with their keys and takes
            // seconds, and `requestAuthorization` waits on a system permission
            // dialog, which on a first launch means it waits on a human. None
            // of it is needed to show a list of chats, and the pieces are
            // independent, so they go concurrently rather than in single file.
            Task { @MainActor in
                async let groups: Void = GroupService.shared.refresh()
                async let queue: Void = MessageService.shared.fetchOfflineQueue()
                async let caps: Void = MessageService.shared.advertiseSenderKeysCapability()
                _ = await (groups, queue, caps)
            }
            Task { @MainActor in
                // Kept in order among themselves: authorisation has to be
                // answered before a token exists to submit.
                await NotificationService.shared.requestAuthorization()
                await NotificationService.shared.refreshTokenSubmission()
                await NotificationPrefsService.shared.refresh()
                await VoIPPushService.shared.refreshTokenSubmission()
            }
        } catch {
            // If we have a cached identity, fall back to offline-mode
            // boot rather than blocking the UI on a transport error.
            if let uin = cachedUIN, cachedToken != nil {
                isOffline = true
                MessageService.shared.configure(ownUIN: uin)
                booted = true
            } else {
                bootError = error.localizedDescription
            }
        }
    }


    // MARK: - install identity

    /// Swap a pre-claim session token for one that names this install.
    ///
    /// Tokens minted before the client sent a device id carry no `dev` claim,
    /// so the server cannot tell this install from any other of the account.
    /// One call fixes that; the server copies the offline-queue drain cursor
    /// onto the new id so nothing is re-downloaded. Returns the new token, or
    /// nil to keep the old one (already claimed, island too old, offline).
    private func claimInstallTokenIfNeeded(_ token: String) async -> String? {
        guard !Self.tokenNamesAnInstall(token) else { return nil }
        struct Body: Encodable { let device_id: String }
        struct Out: Decodable { let token: String }
        do {
            let out: Out = try await APIClient.shared.request(
                "POST", "/auth/device", body: Body(device_id: KeychainStore.deviceID())
            )
            guard !out.token.isEmpty else { return nil }
            KeychainStore.setString(KeychainStore.Keys.token, out.token)
            await APIClient.shared.setToken(out.token)
            print("[boot] install claimed its own device id")
            return out.token
        } catch {
            // 404 on an island that predates the route, or simply offline.
            return nil
        }
    }

    /// Does this JWT already carry a `dev` claim? Payload peek only — the
    /// signature is the server's business.
    static func tokenNamesAnInstall(_ token: String) -> Bool {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return false }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dev = obj["dev"] as? String else { return false }
        return !dev.isEmpty
    }

    // MARK: - migration

    enum MigrationResult: Equatable {
        case success(newUIN: Int)
        case cooldown
        case taken
        case other(String)
    }

    // Suppresses the `.accountBurned` handler on THIS session during
    // an in-flight migrate; the server fans `account_burned` to every
    // WS under the old uin, including this one.
    private var migratingAccount: Bool = false

    /// Migrate the account to a freshly-allocated UIN. Server keeps
    /// profile + contacts + groups; identity + signing keys are
    /// reused server-side so peers' stage-2 sessions survive;
    /// stage-3 material is dropped and re-handshakes on next message.
    func migrateAccount() async -> MigrationResult {
        return await performMigration {
            try await APIClient.shared.request("POST", "/account/migrate")
        }
    }

    /// One number held but not in use.
    struct OwnedUIN: Decodable, Identifiable, Equatable {
        let uin: Int
        let length: Int
        var id: Int { uin }
    }

    struct MyUINs: Decodable, Equatable {
        /// The number this account answers as right now.
        let active: Int
        let owned: [OwnedUIN]
        /// How many one account may hold on this island. Defaults to 10 so an
        /// island too old to send it still gives a sane number to show.
        var maxOwned: Int = 10

        enum CodingKeys: String, CodingKey {
            case active, owned
            case maxOwned = "max_owned"
        }
    }

    /// Everything this account holds. Answers whether or not the island runs
    /// a shop: closing a shop stops new sales, it does not hide from people
    /// what they already own. An island too old to know the endpoint 404s and
    /// this returns nil, which the UI reads as "no vault here".
    func myUINs() async -> MyUINs? {
        try? await APIClient.shared.request("GET", "/uin/mine")
    }

    /// Take a UIN into the collection WITHOUT becoming it. The account keeps
    /// answering as it does; moving onto the number is `activateUIN`.
    ///
    /// Not a migration, so it does not go through `performMigration`: nothing
    /// local changes except the collection.
    func holdUIN(_ uin: Int) async -> MigrationResult {
        struct Body: Encodable {
            let uin: Int
            let `switch`: Bool
        }
        do {
            let _: PurchaseOut = try await APIClient.shared.request(
                "POST", "/uin/purchase",
                body: Body(uin: uin, switch: false)
            )
            return .success(newUIN: uin)
        } catch APIError.http(409, _) {
            return .taken
        } catch APIError.http(429, _) {
            return .cooldown
        } catch APIError.http(_, let body) {
            return .other(body ?? "Server refused")
        } catch {
            return .other(error.localizedDescription)
        }
    }

    /// Answer as a number already in the collection. The number in use goes
    /// into the collection in its place, so this is reversible and never
    /// loses one. Server-side this IS a migration, so it reuses the same
    /// wipe + re-boot pipeline (and the `account_burned` suppression).
    func activateUIN(_ uin: Int) async -> MigrationResult {
        struct Body: Encodable { let uin: Int }
        return await performMigration {
            let out: PurchaseOut = try await APIClient.shared.request(
                "POST", "/uin/activate",
                body: Body(uin: uin)
            )
            guard let newUIN = out.new_uin, let token = out.token else {
                throw APIError.http(500, "activate did not switch")
            }
            return MigrateOut(new_uin: newUIN, token: token)
        }
    }

    /// Superset of `MigrateOut`: `new_uin`/`token` are filled exactly when the
    /// server was asked to switch onto the number.
    private struct PurchaseOut: Decodable {
        let new_uin: Int?
        let token: String?
        let switched: Bool?
        let owned: [Int]?
    }

    private struct MigrateOut: Decodable {
        let new_uin: Int
        let token: String
    }

    private func performMigration(
        _ call: () async throws -> MigrateOut
    ) async -> MigrationResult {
        let resp: MigrateOut
        // Must be set before the POST: server fires `account_burned`
        // before the HTTP response unwinds.
        migratingAccount = true
        do {
            resp = try await call()
        } catch APIError.http(409, _) {
            migratingAccount = false
            return .taken
        } catch APIError.http(429, _) {
            migratingAccount = false
            return .cooldown
        } catch APIError.http(_, let body) {
            migratingAccount = false
            return .other(body ?? "Server refused the migration")
        } catch {
            migratingAccount = false
            return .other(error.localizedDescription)
        }

        WebSocketService.shared.disconnect()
        ContactService.shared.wipe()
        GroupService.shared.wipe()
        AudioRoomService.shared.wipe()
        PushDecryptCache.wipe()
        NotificationPrefsService.shared.wipe()
        // A UIN move REUSES the same identity (only the server-side handle
        // changes), so chat history (peer-keyed), favourites, archive and
        // per-chat settings/sounds all stay valid. Don't nuke them like a burn
        // does — that was the move-to-new-UIN data loss. Reset only the
        // in-memory thread cache; the rows stay on disk and reload on boot.
        MessageStore.shared.resetInMemory()
        VisitStore.shared.wipe()
        RandomChatService.shared.wipe()
        CallService.shared.wipe()
        NotificationService.shared.wipe()
        VoIPPushService.shared.wipe()
        NearbyService.shared.wipe()
        NicknameCache.wipe()
        AvatarThumbCache.wipe()
        GroupNameCache.wipe()
        RemovedContactsStore.shared.wipe()
        ReactionInboxStore.shared.wipe()
        MentionInboxStore.shared.wipe()
        SignalProtocolDB.shared.wipe()
        EncryptedBlobDiskCache.shared.clear()
        PresenceService.shared.status = .online
        PresenceService.shared.statusMessage = nil
        typingByUIN = [:]
        pendingOpenChatUIN = nil
        pendingOpenGroupID = nil
        pendingOpenPending = false
        pendingOpenReports = false
        pendingOpenUserProfile = nil
        pendingAddUIN = nil
        pendingAddHost = nil

        let nickname = AuthService.shared.nickname
        KeychainStore.delete(KeychainStore.Keys.uin)
        KeychainStore.delete(KeychainStore.Keys.token)
        KeychainStore.setString(KeychainStore.Keys.uin, String(resp.new_uin))
        KeychainStore.setString(KeychainStore.Keys.token, resp.token)
        if !nickname.isEmpty {
            KeychainStore.setString(KeychainStore.Keys.nickname, nickname)
        }
        await APIClient.shared.setToken(resp.token)

        booted = false
        bootError = nil
        await boot()

        migratingAccount = false
        return .success(newUIN: resp.new_uin)
    }

    /// User-initiated nuclear reset. Wipes server account + every local
    /// store, then re-runs `boot()` which mints a fresh identity.
    /// `deleteServerAccount` is opt-out ONLY for the wipe-PIN path, which is
    /// explicitly device-local unless the user turned the server erase on. The
    /// user-facing "Burn account" button keeps the old always-delete behaviour.
    func burnAccount(deleteServerAccount: Bool = true) async {
        // ⚠ IN A DECOY SESSION THIS BURNS THE DECOY, NEVER THE REAL ACCOUNT.
        //
        // "Burn account" is a plain destructive row in Settings and a coercer
        // is exactly the person who taps it. Run unchanged it would have called
        // `wipeLocalIdentity()` — deleting the REAL recovery seed and identity
        // keys out of the Keychain, unrecoverably, from inside the duress view
        // — plus the global favourites/archive/sound stores that belong to the
        // real user. The duress session is supposed to be the sacrificial one;
        // it must be able to destroy itself and nothing else.
        //
        // What the coercer sees is what they asked for: the account empties and
        // the app starts over.
        if PanicPINService.shared.isDecoy {
            await burnDecoySession()
            return
        }
        if deleteServerAccount {
            await AuthService.shared.deleteServerAccount()
        }
        WebSocketService.shared.disconnect()

        ContactService.shared.wipe()
        GroupService.shared.wipe()
        PushDecryptCache.wipe()
        NotificationPrefsService.shared.wipe()
        MessageStore.shared.clearAll()
        VisitStore.shared.wipe()
        RandomChatService.shared.wipe()
        CallService.shared.wipe()
        NotificationService.shared.wipe()
        VoIPPushService.shared.wipe()
        FavoritesStore.shared.wipe()
        ArchiveStore.shared.wipe()
        ContactSoundStore.shared.wipe()
        ChatSettingsStore.shared.wipe()
        NearbyService.shared.wipe()
        NicknameCache.wipe()
        AvatarThumbCache.wipe()
        GroupNameCache.wipe()
        RemovedContactsStore.shared.wipe()
        ReactionInboxStore.shared.wipe()
        MentionInboxStore.shared.wipe()
        EncryptedBlobDiskCache.shared.clear()
        PresenceService.shared.status = .online
        PresenceService.shared.statusMessage = nil
        typingByUIN = [:]
        pendingOpenChatUIN = nil
        pendingOpenGroupID = nil
        pendingOpenPending = false
        pendingOpenReports = false
        pendingOpenUserProfile = nil
        pendingAddUIN = nil
        pendingAddHost = nil

        await AuthService.shared.wipeLocalIdentity()

        booted = false
        bootError = nil
        await boot()
    }

    /// The decoy-session half of `burnAccount`. Empties the seeded history and
    /// roster and leaves the duress view sitting on a blank account.
    ///
    /// Deliberately does NOT remove the decoy PIN from the vault: rewriting a
    /// slot needs the real slot key, which a decoy session does not hold (by
    /// design — see `PanicPINService.changeDecoyPIN`). The PIN keeps working
    /// and keeps opening an empty account, which is exactly what a burnt
    /// account looks like.
    private func burnDecoySession() async {
        MessageDB.destroyDecoyStore()
        DecoySeedStore.destroy()
        MessageStore.shared.clearInMemory()
        ContactService.shared.clearForDecoy()
        GroupService.shared.clearForDecoy()
        StoryService.shared.clearForDecoy()
        VisitStore.shared.clearForDecoy()
        // `reload()` and not `configure(decoy:)`: the latter only rebuilds the
        // container when the mode CHANGES, and we are already in decoy mode —
        // it would leave the session holding a handle to a deleted file.
        MessageDB.shared.reload()
        MessageStore.shared.reloadFromDB()
    }

    /// Soft switch to a different existing account. Wipes only the
    /// in-memory view of the current account (contacts, groups,
    /// message store, WebSocket) — persistent storage (per-account
    /// Keychain entries, per-account MessageDB file) stays intact
    /// so switching back later resumes where we left off.
    ///
    /// No-op if the target account isn't in the roster or is
    /// already active.
    func switchToAccount(_ id: UUID) async {
        guard AccountManager.shared.accounts.contains(where: { $0.id == id }) else { return }
        guard id != AccountManager.shared.activeAccountID else { return }
        AccountManager.shared.setActive(id)
        await rebootForActiveAccount()
    }

    /// Federation §5a.5: make backup `host` the PRIMARY home — one-tap
    /// disaster recovery for a dead/blocked primary island. Refreshes the
    /// target's token FIRST (recover challenge-response: possession of the
    /// signing key IS the credential, no phrase) and ABORTS if the island is
    /// unreachable — a failed promote is a no-op, never a stranded account.
    /// Only then swaps primary/backup in Keychain/AccountManager/
    /// MultihomeStore and reboots the session onto the new island. History is
    /// per-account local, it survives the move; the v=2 prekey bundle is
    /// per-island, so contacts see a routine safety-number change. boot()'s
    /// bootstrap republishes the record (new primary first, old demoted).
    /// Returns a localized error string, or nil on success.
    func promoteBackupToPrimary(host: String) async -> String? {
        guard let accountID = AccountManager.shared.activeAccountID,
              let uinStr = KeychainStore.string(KeychainStore.Keys.uin),
              let oldUin = Int(uinStr),
              let oldToken = KeychainStore.string(KeychainStore.Keys.token),
              let sigBytes = KeychainStore.data(KeychainStore.Keys.signingPriv),
              let signingPriv = try? Curve25519.Signing.PrivateKey(rawRepresentation: sigBytes) else {
            return "multihome.err.generic".localized
        }
        let oldHost = Multihome.ownHost()
        guard host != oldHost,
              MultihomeStore.shared.list(ownUin: oldUin).contains(where: { $0.host == host }) else {
            return "multihome.err.generic".localized
        }
        let cred: Multihome.Credentials
        do {
            guard let c = try await Multihome.recoverOn(host: host, signingPriv: signingPriv) else {
                // 404 = this identity never registered there (island wiped us):
                // nothing to promote onto, and nothing was changed.
                return "multihome.err.unreachable".localized
            }
            cred = c
        } catch {
            return "multihome.err.unreachable".localized
        }

        // Token in hand — the swap below is pure local bookkeeping.
        WebSocketService.shared.disconnect()
        KeychainStore.setString(KeychainStore.Keys.uin, String(cred.uin))
        KeychainStore.setString(KeychainStore.Keys.token, cred.token)
        AccountManager.shared.update(accountID, serverURL: "https://\(host)")
        MultihomeStore.shared.promoteSwap(
            oldOwnUin: oldUin, newOwnUin: cred.uin, promotedHost: host,
            oldPrimary: MultihomeStore.Home(
                ownUin: cred.uin, host: oldHost, uin: oldUin, jwt: oldToken,
                addedAt: Date(), auto: nil
            )
        )
        await rebootForActiveAccount()
        // Self-push the new home order to contacts (gossip B1) once the new
        // session has booted (its contact roster is loaded by boot()).
        await MessageService.shared.pushHomeRecordToContacts()
        return nil
    }

    /// Add a brand-new account on `serverURL`, switch active to it,
    /// and let boot mint a fresh identity on the new server. Returns
    /// false when AccountManager refuses the add (roster at limit) —
    /// no switch happens, no boot fires, the caller surfaces the
    /// reason to the user. Returns true on a successful add even if
    /// the subsequent register fails (the user can retry via the
    /// switcher; the dangling account stays in the roster).
    /// Outcome of resolving a pasted access token for a (possibly closed) island.
    enum ResolvedToken: Equatable {
        case open               // public island / empty token — no header
        case durable(String)    // redeemed invite -> durable device token
        case keep(String)       // standing token or a transient error — use as-is
        case badToken           // gated island, token wrong/expired -> abort
        var token: String? {
            switch self {
            case .durable(let t), .keep(let t): return t
            default: return nil
            }
        }
    }

    private static func hostOnly(_ serverURL: String) -> String {
        let s = serverURL.trimmingCharacters(in: .whitespaces)
        let withScheme = s.contains("://") ? s : "https://\(s)"
        return URLComponents(string: withScheme)?.host ?? s
    }

    /// Redeem a pasted access token for `serverURL`. A one-time invite is
    /// exchanged for a durable per-device token (so it's actually consumed); an
    /// open island returns `.open`; a bad token returns `.badToken` (caller aborts).
    static func resolveAccessToken(serverURL: String, entered: String?) async -> ResolvedToken {
        guard let t = entered?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return .open }
        let host = hostOnly(serverURL)
        switch await AccessRedeemer.redeem(host: host, entered: t) {
        case .ok: return .durable(AccessTokenStore.token(for: host) ?? t)
        case .noGate: return .open
        case .badToken: return .badToken
        case .error: return .keep(t)   // standing token / blip — keep the entered token
        }
    }

    @discardableResult
    func addAccount(serverURL: String, serverToken: String? = nil, invite: String? = nil) async -> Bool {
        // Stash the server-join invite for the fresh register that boot() runs
        // on the new account. Consumed once in AuthService.register; harmless on
        // open servers (the backend ignores it unless policy=invite).
        if let invite, !invite.isEmpty {
            UserDefaults.standard.set(invite, forKey: Self.pendingServerInviteKey)
        }
        // Closed (masquerade) island: a one-time INVITE access token must be
        // redeemed into a durable per-device token here, else stamping the raw
        // invite forever would never consume it (= reshareable). Returns the
        // durable; nil on an open island; aborts on a bad token.
        let effToken = await Self.resolveAccessToken(serverURL: serverURL, entered: serverToken)
        if effToken == .badToken {
            UserDefaults.standard.removeObject(forKey: Self.pendingServerInviteKey)
            return false
        }
        // AccountManager.add also setActive(new.id) and triggers
        // mirrorActiveToLegacy → App Group file + rcq.baseURL
        // already point at the new account by the time
        // rebootForActiveAccount runs. serverToken optional; non-nil
        // for self-host backends behind a Caddy X-RCQ-Auth gate, nil
        // for public deployments (api.rcq.app, default self-host).
        guard AccountManager.shared.add(serverURL: serverURL, serverToken: effToken.token) != nil else {
            UserDefaults.standard.removeObject(forKey: Self.pendingServerInviteKey)
            return false
        }
        await rebootForActiveAccount()
        return true
    }

    /// Restore an existing identity from its 24-word BIP39 phrase onto
    /// `serverURL` as a NEW local account. Derives the keypair from the seed,
    /// proves possession of the signing key to the server (`/auth/recover`
    /// challenge → Ed25519 signature), and on success adds + activates the
    /// account with the recovered UIN/token/keys/seed already in the Keychain,
    /// then boots it (bootstrap validates the cached identity — no re-register).
    ///
    /// Returns nil on success, or a localized error string. On failure the
    /// dangling account is rolled back and the previous active (if any) is
    /// rebooted, so the caller stays where it was. Used from both the
    /// onboarding "Restore from phrase" entry (fresh install: no previous
    /// account, the gate in `boot()` having suppressed the launch throwaway)
    /// and Settings "Add account → Restore".
    func recoverAccount(phrase words: [String], serverURL: String, serverToken: String? = nil) async -> String? {
        if AccountManager.shared.isAtAccountLimit {
            return String(format: "add_account.limit".localized, AccountManager.maxAccounts)
        }
        guard let decoded = RecoveryPhrase.decode(words) else {
            return "recovery.restore.error.invalid".localized
        }
        // 32 bytes = a seed (new accounts) → derive; 64 bytes = a legacy
        // account's raw idPriv||signPriv export → use directly, no seed carried.
        let keys: RecoveryPhrase.DerivedKeys
        let seedToStore: Data?
        do {
            if decoded.count == 32 {
                keys = try RecoveryPhrase.deriveKeys(seed: decoded)
                seedToStore = decoded
            } else if decoded.count == 64 {
                keys = try RecoveryPhrase.keysFromRaw(
                    identityPriv: Data(decoded.prefix(32)),
                    signingPriv: Data(decoded.suffix(32)))
                seedToStore = nil
            } else {
                return "recovery.restore.error.invalid".localized
            }
        } catch { return "recovery.restore.error.generic".localized }

        // Closed island: redeem a one-time invite into a durable token before the
        // recover probes (which need the gate header to get through).
        let resolved = await Self.resolveAccessToken(serverURL: serverURL, entered: serverToken)
        if resolved == .badToken { return "access_token.bad".localized }
        let effToken = resolved.token

        let previousActiveID = AccountManager.shared.activeAccountID
        guard let acct = AccountManager.shared.add(serverURL: serverURL, serverToken: effToken) else {
            return String(format: "add_account.limit".localized, AccountManager.maxAccounts)
        }
        // The new account is now active: AccountManager.add already mirrored
        // rcq.baseURL + the App Group active-id, so APIClient targets
        // `serverURL` and KeychainStore.set lands under `acct.id`. Tear down the
        // outgoing session's socket + in-memory identity and clear any stale
        // token so the unauthenticated recover probes go out clean. Engage the
        // proxy / pick a reachable base exactly like boot() does pre-register so
        // recovery works on a censored network too.
        WebSocketService.shared.disconnect()
        AuthService.shared.resetForAccountSwitch()
        // A private island gates ALL requests behind a Caddy X-RCQ-Auth header,
        // so the (user-)unauthenticated recover probes still need the masquerade
        // token to get through. Nil for public backends. effToken = the redeemed
        // durable token (or the entered standing token), never the raw invite.
        await APIClient.shared.setServerToken(effToken)
        await APIClient.shared.setToken(nil)
        _ = await APIClient.shared.refreshActiveBase()

        struct ChalBody: Encodable { let signing_key: String }
        struct ChalOut: Decodable { let challenge: String }
        struct RecBody: Encodable { let signing_key: String; let challenge: String; let signature: String }
        struct RecOut: Decodable { let uin: Int; let token: String }

        do {
            let chal: ChalOut = try await APIClient.shared.request(
                "POST", "/auth/recover/challenge",
                body: ChalBody(signing_key: keys.signingPubB64),
                authenticated: false
            )
            let signature = try RecoveryPhrase.signChallenge(
                signingPrivate: keys.signingPriv, challenge: chal.challenge)
            let rec: RecOut = try await APIClient.shared.request(
                "POST", "/auth/recover",
                body: RecBody(signing_key: keys.signingPubB64, challenge: chal.challenge, signature: signature),
                authenticated: false
            )

            // Already on this device? Stop here, before anything is written.
            //
            // A number holds ONE set of libsignal keys on the server (the
            // `signal_identity_key` column on the user row; the `devices` table
            // is for secondary devices and no client registers one). A second
            // local copy of a number therefore does not merely start empty: on
            // its first boot `ensureBootstrapped` finds an empty store, runs
            // `freshBootstrap`, and uploads a NEW identity key under the same
            // uin. The second copy takes the number's server-side keys and the
            // first is left holding key material the server no longer knows,
            // permanently unable to open that number's group messages. Android
            // had a dialog here and shipped a guard in 913c4f7; iOS had nothing,
            // so this happened silently, up to `hardCap` copies.
            //
            // ⚠ Compared as (uin, serverURL): islands number independently, so
            // uin 134 here and uin 134 elsewhere are different people and a
            // genuine restore onto another island must still work.
            //
            // ⚠ The legacy fallback matters. `string(_:forAccount:)` reads the
            // prefixed slot only; an install that predates multi-account keeps
            // its uin in the unprefixed slot, and without the fallback the
            // comparison returns nil for account[0] and waves the duplicate
            // through — on exactly the installs most likely to have one.
            let firstAccountID = AccountManager.shared.accounts
                .sorted(by: { $0.createdAt < $1.createdAt }).first?.id
            let duplicate = AccountManager.shared.accounts.contains { other in
                guard other.id != acct.id, other.serverURL == serverURL else { return false }
                let otherUIN = KeychainStore.string(KeychainStore.Keys.uin, forAccount: other.id)
                    ?? (other.id == firstAccountID ? KeychainStore.string(KeychainStore.Keys.uin) : nil)
                return otherUIN == String(rec.uin)
            }
            if duplicate {
                KeychainStore.wipeAccount(acct.id)
                AccountManager.shared.remove(acct.id)
                if let prev = previousActiveID {
                    AccountManager.shared.setActive(prev)
                    await rebootForActiveAccount()
                }
                return String(format: "recovery.restore.error.already_here".localized, rec.uin)
            }

            // Server kept the profile — pull the real nickname back.
            await APIClient.shared.setToken(rec.token)
            var nick = "user-\(rec.uin)"
            if let p: UserProfile = try? await APIClient.shared.request("GET", "/users/\(rec.uin)/info"),
               !p.nickname.isEmpty {
                nick = p.nickname
            }

            // Persist the recovered identity under the new account's prefix.
            KeychainStore.set(KeychainStore.Keys.identityPriv, keys.identityPriv.rawRepresentation)
            KeychainStore.set(KeychainStore.Keys.signingPriv,  keys.signingPriv.rawRepresentation)
            if let seedToStore { KeychainStore.set(KeychainStore.Keys.recoverySeed, seedToStore) }
            KeychainStore.setString(KeychainStore.Keys.uin, String(rec.uin))
            KeychainStore.setString(KeychainStore.Keys.token, rec.token)
            KeychainStore.setString(KeychainStore.Keys.nickname, nick)
        } catch {
            // Roll back the dangling account; restore the previous active.
            KeychainStore.wipeAccount(acct.id)
            AccountManager.shared.remove(acct.id)
            if let prev = previousActiveID {
                AccountManager.shared.setActive(prev)
                await rebootForActiveAccount()
            }
            if case let APIError.http(status, _) = error, status == 404 {
                return "recovery.restore.error.notfound".localized
            }
            return "recovery.restore.error.generic".localized
        }

        // Boot the recovered account: the cached uin+token now validate in
        // bootstrapIfNeeded → ready, with no fresh registration.
        await rebootForActiveAccount()
        return nil
    }

    /// Common sequence used after `setActive` or `add`: disconnect
    /// the old WebSocket, drop every in-memory cache that was
    /// scoped to the previous account, swap MessageDB to the new
    /// account's SQLite file, and re-run boot() so the new
    /// account's Keychain identity + server URL get picked up.
    ///
    /// Critically does NOT touch Keychain entries or SQLite rows —
    /// those live under per-account prefixes / filenames and
    /// survive untouched for the next switch-back. The wipe set
    /// mirrors burnAccount()'s pile minus the destructive bits
    /// (wipeLocalIdentity, deleteServerAccount, SignalProtocolDB.wipe).
    private func rebootForActiveAccount() async {
        WebSocketService.shared.disconnect()
        // Drop AuthService's in-memory snapshot of the OLD active
        // account FIRST so any view that re-renders during the
        // booted=false → booted=true window (BootSplash etc.) reads
        // a clean "no identity" state instead of the stale UIN that
        // belonged to the account we're switching away from.
        AuthService.shared.resetForAccountSwitch()

        // Re-point the masquerade header to the new account's token
        // BEFORE anything fires HTTP against the destination server.
        // boot() also does this defensively, but flipping here covers
        // the brief window where AuthService is being torn down.
        await APIClient.shared.setServerToken(AccountManager.shared.active?.serverToken)

        // Reset to defaultLegacy so the new account's boot fetch
        // populates the actual capabilities of the destination server,
        // not the stale outgoing one. Without this, switching from
        // api.rcq.app (uinShop=true) to a self-host account would
        // briefly show the UIN-shop row in Settings until the new
        // /server/info reply lands.
        serverCapabilities = .defaultLegacy
        AccountManager.serverMaxAccounts = AccountManager.hardCap

        ContactService.shared.wipe()
        GroupService.shared.wipe()
        // Re-point cross-island contacts at the NEW account (per-account store);
        // boot()'s ContactService.refresh then merges the right ones in. Without
        // this, a cross-island contact added on one local account bled into the
        // others (founder report).
        CrossIslandStore.shared.bind(accountID: AccountManager.shared.activeAccountID)
        CrossIslandRequestsStore.shared.bind(accountID: AccountManager.shared.activeAccountID)
        VisitedIslandsStore.shared.bind(accountID: AccountManager.shared.activeAccountID)
        PushDecryptCache.wipe()
        NotificationPrefsService.shared.wipe()
        // Soft switch: clear only the IN-MEMORY thread cache. Do NOT delete rows
        // — history lives in a per-account SQLite file and must survive so a
        // switch-back resumes the conversation. (clearAll() deletes rows; that's
        // the burn/migrate path, not this one. This was the chat-history loss.)
        MessageStore.shared.resetInMemory()
        VisitStore.shared.wipe()
        RandomChatService.shared.wipe()
        CallService.shared.wipe()
        NotificationService.shared.wipe()
        // Favourites / archive / per-chat sounds / per-chat settings are
        // persistent per-device organizational data, NOT transient view state.
        // They live under global UserDefaults keys, so wiping them on a soft
        // switch permanently destroyed them for EVERY account — that was the
        // favourites/archive loss on server switch. Leave them intact here;
        // only burnAccount() (nuclear reset) clears them.
        NearbyService.shared.wipe()
        NicknameCache.wipe()
        AvatarThumbCache.wipe()
        GroupNameCache.wipe()
        RemovedContactsStore.shared.wipe()
        ReactionInboxStore.shared.wipe()
        MentionInboxStore.shared.wipe()
        EncryptedBlobDiskCache.shared.clear()
        PresenceService.shared.status = .online
        PresenceService.shared.statusMessage = nil
        typingByUIN = [:]
        pendingOpenChatUIN = nil
        pendingOpenGroupID = nil
        pendingOpenPending = false
        pendingOpenReports = false
        pendingOpenUserProfile = nil
        pendingAddUIN = nil
        pendingAddHost = nil

        MessageDB.shared.reload()
        SignalProtocolDB.shared.reload()
        // Load the NEW account's conversations into the in-memory store now that
        // MessageDB points at its SQLite file. The singleton's init→rehydrate
        // only runs once at app launch, so without this the chat list stayed
        // EMPTY after an account switch until an app restart (founder report).
        MessageStore.shared.reloadFromDB()
        // Favorites are per-account — reload the new account's set so stars
        // don't bleed over from the previously active account.
        FavoritesStore.shared.rebindActiveAccount()

        booted = false
        bootError = nil
        await boot()
    }

    /// `deleteServerAccount` comes out of the WIPE SLOT payload the entered PIN
    /// just opened (default false), never from prefs — see PINVault.SlotPayload.
    func performPanicWipe(deleteServerAccount: Bool) async {
        PINVault.destroy()
        MessageDB.destroyDecoyStore()
        DecoySeedStore.destroy()
        await burnAccount(deleteServerAccount: deleteServerAccount)
        PanicPINService.shared.finishWipe()
    }

    func resumeAfterUnlock() async {
        guard booted, !PanicPINService.shared.isDecoy else { return }
        guard let uin = AuthService.shared.ownUIN,
              let token = KeychainStore.string(KeychainStore.Keys.token) else { return }
        isOffline = false
        if !WebSocketService.shared.isConnected {
            WebSocketService.shared.connect(
                uin: uin, token: token, baseURL: APIClient.shared.baseURL,
                serverToken: AccountManager.shared.active?.serverToken
            )
        }
        await syncOwnPresenceFromServer(uin: uin)
        await ContactService.shared.refresh()
        await GroupService.shared.refresh()
        await MessageService.shared.fetchOfflineQueue()
    }

    private func syncOwnPresenceFromServer(uin: Int) async {
        do {
            let me: UserProfile = try await APIClient.shared.request("GET", "/users/\(uin)/info")
            // Coerce a legacy .offline self-row to .online — the picker
            // can't reach .offline directly.
            let resolved: UserStatus = (me.status == .offline) ? .online : me.status
            PresenceService.shared.status = resolved
            PresenceService.shared.statusMessage = me.statusMessage
            AuthService.shared.updateNicknameLocal(me.nickname)
            // The same response has carried the picture all along and this was
            // throwing it away, which is why the header had nothing to draw.
            PresenceService.shared.setOwnAvatar(id: me.avatarMediaID, key: me.avatarMediaKey)
        } catch {
            // Soft-fail.
        }
    }

    /// Manual censorship-bypass toggle (Android parity — the home ⋮ menu item).
    /// Engages or drops the sing-box obfuscation transport live and reconnects
    /// the socket so traffic immediately routes through (or stops routing
    /// through) it, no app restart. A manual turn-off also persists the
    /// auto-disable opt-out so the failure-driven auto-engage doesn't turn it
    /// straight back on.
    func setBypass(_ on: Bool) async {
        UserDefaults.standard.set(!on, forKey: "rcq.singbox.autoDisabled")
        await SingBoxTransport.shared.setEnabled(on)
        WebSocketService.shared.reconnectNow()
    }

    private func handle(_ event: WebSocketService.Event) {
        switch event {
        case .opened:
            // A live realtime socket is the definitive "we're online" signal —
            // clear any stale offline badge the boot watchdog may have set after
            // a slow first connect (the "Без сети while everything works" case).
            if isOffline { isOffline = false }
            // Drain offline queue on every (re)connect.
            Task { await MessageService.shared.fetchOfflineQueue() }
            // Re-sync audio room subscription if we were inside one.
            // Skipped the unconditional contact refresh that used to
            // live here — presence diffs come in via WS events, so
            // polling on every reconnect just added flicker when the
            // watchdog tripped over a slow round-trip and tore down
            // a healthy socket.
            AudioRoomService.shared.restoreOnForeground()
            // Learn where TURN lives, and bring the call tunnel up if the
            // obfuscated connection is on, before anybody places a call.
            //
            // ⚠ Not only an optimisation. Until this ran, the credentials were
            // fetched inside the first call, so `CallDiagnostics.turnHost` was
            // nil for anyone who had not called yet — and the network audit
            // silently skipped the one check that can say calls are blocked.
            // The report that started all of this came from a phone that had
            // never placed a successful call (#468). Android does the same on
            // connect, as `prewarmRelayPath`.
            Task { await WebRTCManager.shared.prewarmRelayPath() }

        case .closed:
            // No-op. WebSocketService has its own scheduleReconnect()
            // with exponential backoff that fires from handleDisconnect.
            // We used to ALSO schedule a 2s sleeper here that called
            // connect() — every .closed queued one, the Tasks accumulated,
            // and each one cancelled the in-flight WS task on fire. Result
            // was a 1-second reconnect storm (1300+ open/close per 20 min
            // from a single tester). Leave the reconnect entirely to
            // WebSocketService.
            break

        case .accountBurned:
            // Suppressed during migration — see `migratingAccount`.
            if migratingAccount { return }
            Task { await self.burnAccount() }

        case .presence(let uin, let status, let message):
            let contact = ContactService.shared.contacts.first(where: { $0.uin == uin })
            let wasOnline = contact?.status != .offline
            ContactService.shared.updatePresence(uin: uin, status: status, statusMessage: message)
            GroupService.shared.updateMemberPresence(uin: uin, status: status)
            // Online/offline chime ONLY for actual contacts. A
            // presence event also arrives for users we merely share
            // a group with — chiming on every group co-member's
            // come-and-go was noise the user asked to kill. (It also
            // had a bug: a non-contact resolved `wasOnline` to true
            // via the nil-compare, so their going-offline chimed.)
            if contact != nil {
                if status == .offline && wasOnline {
                    SoundService.shared.play(.contactOffline, thread: .peer(uin: uin))
                } else if status != .offline && !wasOnline {
                    SoundService.shared.play(.contactOnline, thread: .peer(uin: uin))
                }
            }

        case .envelope(let env):
            guard let outcome = MessageService.shared.ingest(envelope: env) else { return }
            // Same envelope can arrive twice (WS live + HTTP queue drain);
            // MessageStore dedupes by UUID, only fire effects on first.
            guard outcome.isNewContent else { return }
            let thread = outcome.thread
            // Per-contact sound override only meaningful for 1:1 threads.
            let sender: Int? = {
                if case .peer(let uin) = thread { return uin }
                return nil
            }()
            // Prefer the snippet of the message we just appended; fall
            // back to a generic localized "new message" if for some
            // reason the thread is empty (control envelope that
            // somehow flagged isNewContent — defensive).
            let latest = MessageStore.shared.messages(for: thread).last
            let preview = latest?.previewSnippet ?? "chat.banner.new_message".localized
            let title: String
            let viewing = MessageBannerService.shared.isViewing(thread)
            switch thread {
            case .peer(let uin):
                if !viewing { ContactService.shared.incrementUnread(for: uin) }
                title = ContactService.shared.contacts.first(where: { $0.uin == uin })?.nickname ?? String(uin)
            case .group(let id):
                if !viewing { GroupService.shared.incrementUnread(id) }
                title = GroupService.shared.find(id)?.name ?? "Group"
            }
            // Notification mode: .none = silent everywhere (still unread + in
            // the chat, but NO banner/sound/local-notification). .mentions =
            // same suppression UNLESS this message @mentions us (group only;
            // 1:1 has no mentions concept so it's only ever .all/.none).
            let mode = SoundService.shared.notifyMode(thread: thread)
            let mentionsMe: Bool = {
                if case .group = thread, let t = latest?.text {
                    return MessageService.shared.bodyMentionsMe(t)
                }
                return false
            }()
            let suppressed = (mode == .none) || (mode == .mentions && !mentionsMe)
            let bannerShown = !suppressed && MessageBannerService.shared.tryPresent(
                thread: thread, title: title, body: preview,
            )
            // Sound is tied to banner visibility — silent when the
            // user is already in the chat (the message just appears
            // in the open thread, no need for a chime) and silent
            // when the app is backgrounded (APNs alert sound fires instead).
            if bannerShown {
                SoundService.shared.playIncoming(fromUIN: sender, thread: thread)
            }
            if !suppressed {
                NotificationService.shared.presentIfBackgrounded(
                    title: title, body: preview, threadKey: "\(thread.kindString)-\(thread.rawKey)"
                )
            }

        case .typing(let from, let active):
            typingByUIN[from] = active
            typingTimers[from]?.invalidate()
            if active {
                typingTimers[from] = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
                    Task { @MainActor in self?.typingByUIN[from] = false }
                }
            }

        case .contactRequest(let id, let from, let nick):
            ContactService.shared.appendPendingRequest(.init(id: id, from_uin: from, nickname: nick, state: "pending"))

        case .contactResponse(_, let accepted, _):
            if accepted { Task { await ContactService.shared.refresh() } }

        case .contactRemoved(let peer):
            // Peer removed us from their contacts (ICQ-style mutual delete).
            // Drop them from our local list so the UI updates instantly.
            // Skip RemovedContactsStore here — the deleter, not the deleted,
            // decides who to filter.
            ContactService.shared.removeLocal(peer)

        case .groupChanged(let group):
            GroupService.shared.upsert(group)

        case .groupDeleted(let id):
            GroupService.shared.purge(id)
            MessageStore.shared.clearThread(.group(id: id))

		case
             .randomMatch, .randomEnd,
             .callOffer, .callAnswer, .callIce, .callEnd, .callUnreachable,
             .callRenegotiate, .callRenegotiateAnswer, .callRenegotiateDecline,
             .callIceRestart, .callIceRestartAnswer,
             .roomEnterRejected, .roomRoster, .roomMemberEntered, .roomMemberLeft,
             .roomOffer, .roomAnswer, .roomIce, .roomSpeaking,
             .roomKicked, .roomDeleted, .roomMembershipRevoked, .roomKeyRotated,
             .roomMemberMuted, .roomOwnerOnlyChanged, .roomRenamed,
             .storyPosted, .storyDeleted,
             .hoodMessage, .hoodCount, .hoodDelete, .hoodReaction:
            // Owned by their respective services that subscribe directly.
            break
        }
    }

}

// MARK: - Server capabilities

/// Server-advertised capabilities consumed by the iOS client to gate
/// optional surfaces. The flagship gate today is the in-app UIN shop:
/// `api.rcq.app` advertises `uinShop=true`, every self-host backend
/// running `rcq-server-ref` defaults to `false`, and `SettingsView`
/// hides the row entirely on backends that don't sell UINs in-app.
///
/// Default values are deliberately permissive (everything on) so that
/// legacy backends predating `/server/info` keep working — they 404
/// the lookup and we fall through to the defaults, which match the
/// pre-flag behaviour. Future capabilities should follow the same
/// rule: pick the default that preserves the old behaviour.
struct ServerCapabilities: Decodable, Equatable {
    var uinShop: Bool
    var hallOfFame: Bool
    // Operator-toggleable optional features (admin console → Features). Each
    // defaults TRUE so a legacy server that omits the field keeps showing the
    // tab (pre-flag behaviour); the operator hides a feature by turning it off,
    // and the backing route is also 404-gated server-side.
    var nearby: Bool
    var randomChat: Bool
    var hood: Bool
    var stories: Bool
    // How many accounts one device may hold (operator-set). Caps the account
    // switcher; defaults to the historical 5.
    var maxAccountsPerDevice: Int

    init(
        uinShop: Bool,
        hallOfFame: Bool = true,
        nearby: Bool = true,
        randomChat: Bool = true,
        hood: Bool = true,
        stories: Bool = true,
        maxAccountsPerDevice: Int = 5
    ) {
        self.uinShop = uinShop
        self.hallOfFame = hallOfFame
        self.nearby = nearby
        self.randomChat = randomChat
        self.hood = hood
        self.stories = stories
        self.maxAccountsPerDevice = maxAccountsPerDevice
    }

    static let defaultLegacy = ServerCapabilities(uinShop: true, hallOfFame: true)

    private enum CodingKeys: String, CodingKey {
        case uinShop = "uin_shop"
        case hallOfFame = "hall_of_fame"
        case nearby
        case randomChat = "random_chat"
        case hood
        case stories
        case maxAccountsPerDevice = "max_accounts_per_device"
    }

    // hall_of_fame is decode-optional (default false) so an old server that
    // omits it hides the surface; uin_shop stays required to preserve its
    // existing fetch behaviour (a response without it falls back to defaultLegacy).
    // The feature toggles are decode-optional + default TRUE so an old server
    // (or one that omits them) keeps the tabs visible.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uinShop = try c.decode(Bool.self, forKey: .uinShop)
        hallOfFame = try c.decodeIfPresent(Bool.self, forKey: .hallOfFame) ?? false
        nearby = try c.decodeIfPresent(Bool.self, forKey: .nearby) ?? true
        randomChat = try c.decodeIfPresent(Bool.self, forKey: .randomChat) ?? true
        hood = try c.decodeIfPresent(Bool.self, forKey: .hood) ?? true
        stories = try c.decodeIfPresent(Bool.self, forKey: .stories) ?? true
        maxAccountsPerDevice = try c.decodeIfPresent(Int.self, forKey: .maxAccountsPerDevice) ?? 5
    }
}

struct ServerInfoResponse: Decodable {
    let name: String
    /// The operator's welcome / rules text. Served since islands existed and
    /// read by nothing, which is why the admin panel warned that typing here
    /// changed nothing.
    let welcome: String?
    let capabilities: ServerCapabilities
}

@MainActor
enum ServerInfoService {
    /// Fetch `/server/info` against the currently-pointed backend. Returns
    /// `nil` on any network or decode failure — we never block boot on
    /// this, and we never collapse a previously-known-good capability
    /// set on a transient miss. Callers should only adopt the returned
    /// value on success; see `AppState.boot` for the gating.
    /// `/server/info` for an island we are NOT on, by host. The name and the
    /// house rules belong on the confirm before joining, which is the one
    /// moment anybody reads them, and that has to ask the island itself rather
    /// than the one we happen to be on. Nil when it does not answer.
    static func fetch(host: String) async -> ServerInfoResponse? {
        guard let url = URL(string: "https://\(host)/server/info") else { return nil }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await URLSession(configuration: .ephemeral).data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(ServerInfoResponse.self, from: data)
        } catch {
            return nil
        }
    }

    static func fetch() async -> ServerCapabilities? {
        do {
            let info: ServerInfoResponse = try await APIClient.shared.request(
                "GET",
                "/server/info",
                authenticated: false
            )
            return info.capabilities
        } catch {
            return nil
        }
    }
}

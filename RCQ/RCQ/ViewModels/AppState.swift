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
    /// Honest 0..1 progress for the boot splash bar. Raised at the awaited
    /// milestones of `doBoot` (never derived from time), reset only at
    /// `boot()` entry inside the single-flight, and raise-only in between:
    /// the chain has legitimate status regressions (.engagingStealth back to
    /// .connecting on the de-tunnel fallback) and a bar that moves backwards
    /// reads as a broken app. See `advanceBoot(to:)`.
    @Published private(set) var bootProgress: Double = 0

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
    /// servers keep the same surfaces as before. The window between boot
    /// start and the fetch landing is bridged by the per-account
    /// `ServerCapabilitiesCache` (seeded in `doBoot` and on account
    /// switch), so a surface the island's operator turned off no longer
    /// flashes for one round-trip on every entry; `.defaultLegacy`
    /// survives only for a never-seen account.
    @Published var serverCapabilities: ServerCapabilities = .defaultLegacy
    /// What this island calls itself and the house rules its operator typed,
    /// from the same `/server/info` reply. Empty until the boot fetch lands and
    /// on any island that leaves them blank; Settings then falls back to the
    /// host, which is all we honestly know.
    @Published var serverName: String = ""
    @Published var serverWelcome: String = ""
    /// Which logo the island we are on is currently serving, "" for none. Read
    /// by `IslandAvatarView` (through the switcher's per-account card, so a row
    /// for an island this process is not talking to still has one).
    @Published var serverLogoVersion: String = ""
    @Published var typingByUIN: [Int: Bool] = [:]
    @Published var pendingAddUIN: Int? = nil
    /// Island host from a contact link's `?h=` (spec §5) — set BEFORE
    /// pendingAddUIN so the observer reads both; nil = same-island link.
    @Published var pendingAddHost: String? = nil
    @Published var pendingOpenChatUIN: Int? = nil
    @Published var pendingOpenGroupID: Int? = nil
    /// Set once, by a FRESH registration in onboarding: the recovery phrase is
    /// shown before anything else, so a reinstall does not silently end the
    /// account (founder, 05.09). Restore never sets it; those people have it.
    @Published var showPhraseNudge: Bool = false
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

    /// A `.rcq` address tapped in a chat, or handed to the app as a URL: the
    /// reader opens on it. ContactListView presents `SitesView` for it.
    @Published var pendingOpenSite: SiteOpenRequest? = nil

    /// Where the `.rcq` browser should open. `address` nil is the start screen
    /// (the menu entry); `page` nil is the site's front page.
    struct SiteOpenRequest: Identifiable, Equatable {
        let id = UUID()
        let address: String?
        let page: String?
    }

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
        // Our own device list just changed under us: the web session will
        // claim a key slot the moment it boots. Re-read rather than trust a
        // list from before the link.
        await SignalCryptoService.invalidateOwnDevices()
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
        // A host that ends in `.rcq`, whatever the scheme: a site inside the
        // network, never a page for the web view to resolve.
        if SiteAddressParser.link(from: url) != nil { return true }
        guard url.scheme == "https" || url.scheme == "http",
              url.host == "rcq.app",
              url.pathComponents.count >= 3 else { return false }
        return ["s", "r", "u", "g"].contains(url.pathComponents[1])
    }

    func handle(deepLink url: URL) {
        // A `.rcq` host, whatever the scheme: `https://e2ee.rcq/en.html` the
        // way a person shares their own site, `rcq://e2ee.rcq` the way the
        // linkifier marks a bare address. The reader, never a browser. Above
        // the duress guard on purpose: a read is anonymous and acts for no
        // account (see `SitesRepository`), and the browser's own menu entry
        // is open in a decoy session anyway.
        if let link = SiteAddressParser.link(from: url) {
            pendingOpenSite = SiteOpenRequest(address: link.address, page: link.page)
            return
        }
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
        networkReady = true
        // The boot that led here ran offline, so the island's capabilities
        // are still the legacy defaults: read them before the drain below,
        // or a room log the account already reads stays untouched for the
        // rest of the run.
        await refreshServerInfo()
        await syncOwnPresenceFromServer(uin: uin)
        await ContactService.shared.refresh()
        await GroupService.shared.refresh()
        await MessageService.shared.fetchOfflineQueue()
        await VaultSync.sweep(force: true)
    }

    /// Whether `/server/info` of the island we are on has been read this
    /// session. Until it has, `serverCapabilities` is the legacy default
    /// and nothing that is gated on a flag (the room log above all) runs,
    /// so a boot that fell into the offline branch, or whose one read timed
    /// out, is followed by another read at the next online moment.
    @Published private(set) var serverInfoRead = false

    /// Does this island run a vault? ⚠⚠ THREE STATES, not two: true, false and
    /// nil for "not answered yet".
    ///
    /// Sections are hidden entirely without a vault, and only an explicit "no"
    /// un-files anything. Reading "not answered yet" as "no" is not a cosmetic
    /// flash: it takes the members of a PIN-gated section and draws them, by
    /// name and with their unread badges, in Online / Offline / Other islands,
    /// while the section's own header disappears from the list. The web client
    /// shipped that way for a day. A chat can only BE filed if the island had a
    /// vault when it was filed, so an unanswered probe keeps the cached filing.
    var vaultCapability: Bool? {
        serverInfoRead ? serverCapabilities.vault : nil
    }

    /// Read `/server/info` for the island we are on and adopt the answer:
    /// the capability flags, the account cap, the island's name and house
    /// rules, plus the deposit-token prewarm the flags may call for. Only a
    /// successful read is adopted; a miss keeps what is known (never a
    /// downgrade on a transient failure) and leaves `serverInfoRead` false
    /// so the next opening asks again.
    func refreshServerInfo() async {
        guard let info = await ServerInfoService.fetch() else { return }
        serverInfoRead = true
        serverCapabilities = info.capabilities
        // Remember the answer per account so the NEXT entry seeds from it
        // instead of `.defaultLegacy` (whose permissive nearby=true flashed
        // the Nearby bar button on islands that turned it off). The decoy
        // guard lives in the cache itself.
        if let id = AccountManager.shared.activeAccountID {
            ServerCapabilitiesCache.record(info.capabilities, for: id)
        }
        AccountManager.serverMaxAccounts = info.capabilities.maxAccountsPerDevice
        serverName = info.name
        serverWelcome = info.welcome ?? ""
        serverLogoVersion = info.logoVersion ?? ""
        // Stage 3: the island reads bundles against anonymous deposit
        // tokens, and each costs a proof of work. Mint the first batch
        // now, in the background, so the first message to a new peer
        // does not sit on one. Idempotent: a stocked reserve rests.
        if info.capabilities.anonKeys && info.capabilities.depositAuth,
           let host = APIClient.shared.baseURL.host {
            let base = APIClient.shared.baseURL.absoluteString
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let masquerade = await APIClient.shared.currentServerToken()
            Task.detached(priority: .utility) {
                await DepositAuthStore.shared.prewarm(host: host, masquerade: masquerade, base: base)
            }
        }
    }

    /// The socket came up while the island's flags were never read (an
    /// offline boot that the path monitor did not catch up on, or a read
    /// that timed out): read them before the drain that follows the open.
    private func refreshServerInfoIfUnread() async {
        guard !serverInfoRead else { return }
        await refreshServerInfo()
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
            // The silence probe measures how long a PEER has been quiet, and
            // a stretch when THIS side had no link measures nothing: their
            // replies may be sitting in the queue this reconnect is about to
            // drain. Clocks shift forward by the measured gap — never reset;
            // SilenceProbe.shiftClocks explains why a flapping link makes the
            // difference matter.
            if let down = socketDownSince {
                SilenceProbe.shared.shiftClocks(by: Date().timeIntervalSince(down))
            }
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
        // The socket is down because this device refused the island's
        // certificate, not because the route died: a ladder walk would pull
        // relays and re-attempt the same refused handshake through each (§5.5).
        if IslandTrust.shared.isRefused(url: URL(string: APIClient.activeDirectBase())) { return }
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
           await APIClient.shared.probeDirectReachable() == .reachable {
            print("[route] tunnel unreachable, direct works — falling back to direct")
            SingBoxTransport.shared.stop()
            await APIClient.shared.useDirectSession()
            reach = await APIClient.shared.refreshActiveBase()
        }

        // Refused is neither: the island answered, and the app is offline for
        // it until the banner's button is pressed.
        if reach == .primary || reach == .proxy { isOffline = false }
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
                // Refused is terminal for this loop too (§5.5): the chain does
                // not change by waiting, and the banner's button restarts it.
                if reach == .refused { return }
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
        bootChainDone = false
        // Fresh boot, fresh bar. Inside the single-flight on purpose: a
        // concurrent boot() dropped above must not zero a live bar mid-run.
        bootProgress = 0
        defer {
            booting = false
            bootChainDone = true
        }
        await doBoot(suggestedNickname: suggestedNickname)
    }

    /// True once a boot chain has run to its end (any exit). The watchdog
    /// used to key on `booted`, which now flips BEFORE the network chain when
    /// the roster came from disk, so it keys on this instead.
    private var bootChainDone = true

    /// True once this boot has a session token in APIClient and a resolved
    /// base: the point from which a roster fetch can succeed. With the chat
    /// list on screen before the chain runs, its own fetches would otherwise
    /// fire unauthenticated against whatever base was last used, and the
    /// single-flight refresh would then hand the boot's own fetch that same
    /// doomed request. The services refuse to fetch while this is false, and
    /// the chat list re-runs its fetches when it flips. False again for the
    /// length of an account switch.
    @Published private(set) var networkReady = false

    /// Paint the chat list from the last roster on disk (see
    /// `RosterSnapshot`). True when there was one worth showing.
    private func hydrateRosterFromDisk() async -> Bool {
        // The main-actor facts in microseconds; the file reads, the AES and
        // the JSON decode - the founder's photographed ~4s stall on a large
        // roster - on a detached task. Rooms stay inline: that list is tiny.
        guard !PanicPINService.shared.isDecoy else { return false }
        let key = PanicPINService.shared.dataKey
        let acct = AppGroup.readActiveAccountID()
        let (contactSnap, groupList) = await Task.detached(priority: .userInitiated) {
            (RosterSnapshot.loadOffMain(.contacts, as: ContactService.Snapshot.self, dataKey: key, accountID: acct),
             RosterSnapshot.loadOffMain(.groups, as: [RCQGroup].self, dataKey: key, accountID: acct))
        }.value
        let contacts = ContactService.shared.applySnapshot(contactSnap)
        let groups = GroupService.shared.applySnapshot(groupList)
        AudioRoomService.shared.hydrateFromSnapshot()
        return contacts || groups
    }

    /// Raise-only setter for `bootProgress`: milestone bumps ride the awaited
    /// completions in `doBoot`, never the status values (those regress), and
    /// the watchdog can race the tail of the chain.
    private func advanceBoot(to value: Double) {
        if value > bootProgress { bootProgress = value }
    }

    /// Wait for a boot chain in flight to reach its end. For the paths that
    /// replace the account under the app (switch, burn, migration).
    func settleBoot() async {
        while booting {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
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
            advanceBoot(to: 1.0)
            booted = true
            return
        }

        // Last-known capabilities before the network answers, or the chat
        // list's first frame draws `.defaultLegacy` surfaces the island's
        // operator turned off (the Nearby bar button flashed on every entry).
        // Only a never-seen account keeps the legacy defaults. Deliberately
        // NOT flipping `serverInfoRead`: everything three-state
        // (`vaultCapability` above all) still waits for the live reply.
        if !serverInfoRead, let id = AccountManager.shared.activeAccountID,
           let cached = ServerCapabilitiesCache.capabilities(for: id) {
            serverCapabilities = cached
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
        networkReady = false
        await APIClient.shared.setServerToken(AccountManager.shared.active?.serverToken)
        advanceBoot(to: 0.05)

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

        // The list, now. A returning user with a roster on disk gets the chat
        // list on the first frame and the rest of this function becomes the
        // catch-up behind it: the probe chain, the identity check, the socket,
        // the fresh roster. Before this, `booted` waited at the end of ten to
        // twelve serial round trips, and the fifteen-second watchdog then
        // surrendered to an empty list. The header's orange dot says
        // "connecting" until the socket is up, which is the honest state.
        if let uin = cachedUIN, cachedToken != nil, await hydrateRosterFromDisk() {
            MessageService.shared.configure(ownUIN: uin)
            // The splash is gone from here; snap the bar's last frame full so
            // the raise-only helper mutes the rest of the chain's bumps.
            advanceBoot(to: 1.0)
            booted = true
        }

        if !pathSatisfied, let uin = cachedUIN, cachedToken != nil {
            isOffline = true
            // A roster painted from disk keeps its last-known presence for
            // the second or two until /contacts lands; with no network that
            // second never comes, and "online" would be a lie.
            ContactService.shared.markAllOffline()
            MessageService.shared.configure(ownUIN: uin)
            advanceBoot(to: 1.0)
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
                guard !self.bootChainDone else { return }
                // The view swap makes the bar moot either way; keep its last
                // frame honest instead of freezing mid-run.
                self.advanceBoot(to: 1.0)
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
                        if !self.networkReady { ContactService.shared.markAllOffline() }
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
            // Entering the transport/reachability stage. The two long stages
            // (tunnel engage, identity check) sit between the sparse bumps
            // here; the splash creeps the DISPLAYED value between them.
            advanceBoot(to: 0.15)
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
                let direct = await APIClient.shared.probeDirectReachable()
                // Only an UNREACHABLE island earns the tunnel. A refused one
                // answered perfectly well and would refuse through every relay
                // too; its banner is the way forward (§5.5).
                if direct == .unreachable {
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
            if activeBase != APIClient.prodBaseURL, await APIClient.shared.probeDirectReachable() == .reachable {
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
               await APIClient.shared.probeDirectReachable() == .reachable {
                print("[boot] tunnel unreachable, direct works — falling back to direct")
                SingBoxTransport.shared.stop()
                await APIClient.shared.useDirectSession()
                reach = await APIClient.shared.refreshActiveBase()
                bootStatus = .connecting
            }
            if reach == .primary || reach == .proxy, SingBoxTransport.shared.isActive {
                bootStatus = .stealthActive
            }
            if reach == .unreachable || reach == .refused {
                if let uin = cachedUIN, cachedToken != nil {
                    isOffline = true
                    ContactService.shared.markAllOffline()
                    MessageService.shared.configure(ownUIN: uin)
                    advanceBoot(to: 1.0)
                    booted = true
                    // A refused certificate is not retried (§5.5): the banner
                    // on the main screen holds the only way forward, and its
                    // button reconnects. Waiting would not change the chain.
                    if reach == .unreachable { scheduleTransportRetry() }
                } else if reach == .refused,
                          let change = IslandTrust.shared.change(forAddress: APIClient.activeDirectBase()) {
                    // No account yet, so no main screen to carry the banner:
                    // the boot error says what the banner would have said, and
                    // the form that started this add shows the banner itself.
                    bootError = String(
                        format: (change.typed ? "island.trust.changed_typed" : "island.trust.changed").localized,
                        change.host
                    )
                } else {
                    bootError = "boot.error.unreachable".localized
                }
                return
            }
            advanceBoot(to: 0.40)
            // The history container must be READY before anything downstream
            // can first-touch `MessageDB.shared` - the socket's first envelope
            // does exactly that ~2s in, and a first touch that races the
            // t=0 prewarm does not skip the cost, it BLOCKS on the same
            // SQLite lock the migrating background open holds (the founder's
            // hard post-entry freeze on a no-PIN device, 30.08). Awaiting
            // here keeps the UI alive through the one slow case (first
            // launch after a schema change) and is a no-op ever after.
            await MessageDB.prewarm()
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
            advanceBoot(to: 0.60)
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
            // From here a fetch can succeed: token set, base resolved.
            networkReady = true
            advanceBoot(to: 0.70)

            // Capability fetch. Failure is non-fatal: we keep the
            // permissive defaultLegacy set, which matches every
            // backend's behaviour before v0.4 added /server/info.
            // Self-host backends running rcq-server-ref return
            // {uin_shop: false} here and SettingsView drops the row
            // entirely; api.rcq.app returns {uin_shop: true} and the
            // surface stays. A miss here is retried by the first online
            // sync or socket open; see `refreshServerInfo`.
            await refreshServerInfo()
            advanceBoot(to: 0.75)

            let baseURL = APIClient.shared.baseURL
            WebSocketService.shared.connect(
                uin: uin, token: token, baseURL: baseURL,
                serverToken: AccountManager.shared.active?.serverToken
            )
            // Dial issued, not awaited: `booted` keys on the roster fetch, and
            // the header's dot owns the link truth from here.
            advanceBoot(to: 0.80)

            // Only what the first screen genuinely cannot be drawn without.
            // Contacts because the list IS the first screen; presence because
            // the header renders the person's own status. Both are small.
            // The identity check above already fetched the own profile; one
            // round trip fewer on the boot path.
            if let me = AuthService.shared.bootProfile {
                applyOwnProfile(me)
                AuthService.shared.bootProfile = nil
            } else {
                await syncOwnPresenceFromServer(uin: uin)
            }
            await ContactService.shared.refresh(joinInFlight: true)
            advanceBoot(to: 0.95)

            print("[boot] complete — booted")
            advanceBoot(to: 1.0)
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
                async let groups: Void = GroupService.shared.refresh(joinInFlight: true)
                async let queue: Void = MessageService.shared.fetchOfflineQueue()
                async let caps: Void = MessageService.shared.advertiseSenderKeysCapability()
                // The vault's own catch-up: which slots moved while this device
                // was away. `vault_changed` is pub/sub with no replay, so a
                // change another device made while this one was off is only
                // ever heard here or on the next socket reconnect.
                async let vault: Void = VaultSync.sweep(force: true)
                _ = await (groups, queue, caps, vault)
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
                if !networkReady { ContactService.shared.markAllOffline() }
                MessageService.shared.configure(ownUIN: uin)
                advanceBoot(to: 1.0)
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
        /// The numbers of this collection that are up for sale right now, set
        /// from another client (iOS cannot sell). A listed number is not the
        /// reader's to release or move onto while a buyer may be paying for
        /// it; the one thing this screen offers for it is taking it back off
        /// the market (founder, 05.09).
        var listed: [UINListing] = []

        enum CodingKeys: String, CodingKey {
            case active, owned, listed
            case maxOwned = "max_owned"
        }

        /// ⚠ Written by hand because the synthesised one does NOT fall back to
        /// a property's default value: a missing `max_owned` threw
        /// `keyNotFound` and, since the caller decodes with `try?`, the whole
        /// screen came back empty. The default above was doing nothing on
        /// exactly the islands it was written for (the flagship always sends
        /// the field, so this never showed up there). `owned` gets the same
        /// treatment: an island that omits an empty list is a screen with no
        /// numbers, not a screen with no vault.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            active = try container.decode(Int.self, forKey: .active)
            owned = try container.decodeIfPresent([OwnedUIN].self, forKey: .owned) ?? []
            maxOwned = try container.decodeIfPresent(Int.self, forKey: .maxOwned) ?? 10
            listed = (try? container.decodeIfPresent([UINListing].self, forKey: .listed)) ?? []
        }
    }

    /// Everything this account holds. Answers whether or not the island runs
    /// a shop: closing a shop stops new sales, it does not hide from people
    /// what they already own. An island too old to know the endpoint 404s and
    /// this returns nil, which the UI reads as "no vault here".
    func myUINs() async -> MyUINs? {
        try? await APIClient.shared.request("GET", "/uin/mine")
    }

    /// A number somebody is selling to somebody else. The price is the
    /// SELLER's, not a rung on this island's ladder, and the money never
    /// touches the island: it goes to the wallet the seller named.
    struct UINListing: Decodable, Identifiable, Equatable {
        let uin: Int
        let sellerUin: Int
        let priceCents: Int
        let priceDisplay: String
        /// Somebody is paying for it right now, so it is not on offer.
        var held: Bool = false

        var id: Int { uin }

        enum CodingKeys: String, CodingKey {
            case uin, held
            case sellerUin = "seller_uin"
            case priceCents = "price_cents"
            case priceDisplay = "price_display"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            uin = try c.decode(Int.self, forKey: .uin)
            sellerUin = try c.decode(Int.self, forKey: .sellerUin)
            priceCents = try c.decode(Int.self, forKey: .priceCents)
            priceDisplay = try c.decode(String.self, forKey: .priceDisplay)
            held = try c.decodeIfPresent(Bool.self, forKey: .held) ?? false
        }
    }

    /// Take one of our own numbers back off the market. Refused by the island
    /// while somebody is paying for it (409), which the screen reports.
    func unlistUIN(_ uin: Int) async -> Bool {
        do {
            let _: EmptyResponse = try await APIClient.shared.request("DELETE", "/uin/listings/\(uin)")
            return true
        } catch {
            return false
        }
    }

    /// What people are selling. ⚠ `try?` and an empty list rather than nil:
    /// this 404s on an island too old to know the endpoint, on one with the
    /// shop closed, and on one with resale switched off, and none of those
    /// three is worth a word on screen.
    func uinListings(count: Int = 12) async -> [AppState.UINListing] {
        (try? await APIClient.shared.request("GET", "/uin/listings", query: ["count": String(count)])) ?? []
    }

    /// What came back from `releaseUIN`. Separate from `MigrationResult`
    /// because giving a number away is not a migration and every refusal on it
    /// means something different to the person reading it.
    enum ReleaseResult: Equatable {
        /// The server answers with the WHOLE collection after the release, so
        /// the screen replaces its state instead of guessing what changed.
        case success(MyUINs)
        /// 400 `uin_in_use`: you cannot give away the number you answer as.
        case inUse
        /// 404 `not_owned`: this account does not hold it. Somebody released
        /// it from another device, or it was never here.
        case notOwned
        /// 404/405 from the router rather than from the handler: an island too
        /// old to have the route at all. Told apart from `notOwned` by the
        /// body, because "you do not own this" and "this island cannot do
        /// this" are two different lies to tell somebody.
        case unsupported
        /// 429: twenty releases an hour, which is a handful of deliberate taps
        /// and never a loop.
        case rateLimited
        /// 403 `suspended`.
        case suspended
        case other(String)
    }

    /// Give a held number back to the pool.
    ///
    /// Collecting numbers nobody chose is a side effect of the vault: moving
    /// onto a number parks the previous one in the collection whether it was
    /// wanted or not, and the long number handed out at signup is usually the
    /// first one people stop wanting. Until now iOS had no way to say no.
    ///
    /// ⚠ Irreversible. The number goes back into the pool and somebody else
    /// may take it, which is why this is a deliberate call behind a confirm
    /// and not a swipe.
    func releaseUIN(_ uin: Int) async -> ReleaseResult {
        do {
            let out: MyUINs = try await APIClient.shared.request("DELETE", "/uin/mine/\(uin)")
            return .success(out)
        } catch APIError.http(400, _) {
            return .inUse
        } catch APIError.http(403, _) {
            return .suspended
        } catch APIError.http(404, let body) {
            // Our handler says `{"detail":{"code":"not_owned"}}`; the router's
            // own miss says `{"detail":"Not Found"}`.
            return (body ?? "").contains("not_owned") ? .notOwned : .unsupported
        } catch APIError.http(405, _) {
            return .unsupported
        } catch APIError.http(429, _) {
            return .rateLimited
        } catch APIError.http(_, let body) {
            return .other(body ?? "Server refused")
        } catch {
            return .other(error.localizedDescription)
        }
    }

    /// A refusal from the number endpoints, turned into something a person can
    /// read. The server sends `{"detail":{"code":"..."}}`, and putting that on
    /// screen verbatim is how a user meets raw JSON.
    ///
    /// A transport failure is already a sentence ("The Internet connection
    /// appears to be offline") and must survive untouched, so anything without
    /// a `code` is passed straight through.
    static func uinRefusalText(_ raw: String) -> String {
        guard raw.contains("\"code\"") else { return raw }
        if raw.contains("suspended") { return "uin.error.suspended".localized }
        if raw.contains("too_many_uins") { return "uin.error.too_many".localized }
        if raw.contains("uin_in_use") { return "my_uins.release.error.in_use".localized }
        if raw.contains("not_owned") { return "my_uins.error.not_owned".localized }
        if raw.contains("self_target") { return "uin_shop.status.self".localized }
        // The island keeps short and patterned numbers as stock (2026-09-01),
        // and closed collections in the same breath. Both refusals mean "this
        // one is not on offer", which is a different sentence from "try again".
        if raw.contains("reserved") { return "uin_shop.error.reserved".localized }
        if raw.contains("collections_closed") { return "uin_shop.error.reserved".localized }
        return "uin_shop.error.generic".localized
    }

    /// Take a UIN INTO THE COLLECTION, without becoming it.
    ///
    /// ⚠⚠ `switch: false`, and this line has a price on it. It was flipped to
    /// true on 2026-09-01, when collections were closed and the island refused
    /// `switch: false` outright. Collections reopened on 03.09 and this client
    /// was not changed, so "take" still meant "move onto it" - and moving gives
    /// up the number you were answering as. That is how the founder lost #911:
    /// he bought an ordinary seven-digit number and a three-digit one was back
    /// on the public shelf a second later.
    ///
    /// ⚠ It also ejected him from his own account, and that is this view's half
    /// of the fault: a switch is a MIGRATION, the island bumps the number's
    /// epoch and every token minted for the old one dies - but `runPurchase`
    /// only set `held` and carried on with a token that no longer existed.
    /// Nothing here reboots the session, so nothing here may ask for a switch.
    /// Becoming a number is `moveOnto` / `activateUIN`, which does.
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
        } catch APIError.http(409, let body) {
            // 409 is TWO refusals wearing one status code: somebody else has
            // the number, or this account is at the collection cap. Reporting
            // the cap as "someone grabbed it first" sent people hunting for
            // another number they also could not have.
            if (body ?? "").contains("too_many_uins") {
                return .other("uin.error.too_many".localized)
            }
            return .taken
        } catch APIError.http(429, _) {
            return .cooldown
        } catch APIError.http(_, let body) {
            return .other(Self.uinRefusalText(body ?? "Server refused"))
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

        await settleBoot()
        networkReady = false
        WebSocketService.shared.disconnect()
        ContactService.shared.wipe()
        // The roster on disk goes with the account (a switch keeps it; see RosterSnapshot).
        RosterSnapshot.deleteActive()
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
    /// [requireServerErase] refuses to touch local storage when the island did
    /// not confirm the delete, so the app cannot tell somebody their account is
    /// gone while the row is still on the island. Android has behaved this way
    /// since its burn was fixed; iOS swallowed the failure with `try?`.
    ///
    /// It is OFF for the two callers that must wipe regardless: a duress wipe
    /// (instant, and has to work offline — the island is best-effort there) and
    /// the `accountBurned` event, where the account is already gone and a second
    /// DELETE can only fail.
    ///
    /// Returns false only in the refused case.
    @discardableResult
    func burnAccount(deleteServerAccount: Bool = true, requireServerErase: Bool = false) async -> Bool {
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
            return true
        }
        if deleteServerAccount {
            let erased = await AuthService.shared.deleteServerAccount()
            if !erased && requireServerErase {
                // Nothing has been touched yet, so leaving now leaves the
                // account whole and the user able to try again — which is the
                // truth, and better than a screen that closes on a comforting
                // lie.
                return false
            }
        }
        await settleBoot()
        networkReady = false
        WebSocketService.shared.disconnect()

        ContactService.shared.wipe()
        // The roster on disk goes with the account (a switch keeps it; see RosterSnapshot).
        RosterSnapshot.deleteActive()
        GroupService.shared.wipe()
        // A burn mints a fresh identity under the SAME account UUID, so every
        // per-account key below still resolves to the same slot afterwards and
        // nothing else empties it. The burned identity's foreign contacts, the
        // strangers holding sealed payloads for it and the islands it had
        // visited all came back attached to the new identity, which is exactly
        // what a burn says it undoes (founder, 30.08). The switch path rebinds
        // these instead; only a burn erases them.
        Multihome.stopPolling()
        CrossIslandStore.shared.wipe()
        CrossIslandRequestsStore.shared.wipe()
        StrangerQuarantine.shared.wipe()
        VisitedIslandsStore.shared.wipe()
        PushDecryptCache.wipe()
        SilenceProbe.shared.reset()
        // Same reason as the probe: the device lists key on bare peer uins.
        await PeerDeviceCache.shared.invalidateAll()
        NotificationPrefsService.shared.wipe()
        MessageStore.shared.clearAll()
        VisitStore.shared.wipe()
        RandomChatService.shared.wipe()
        CallService.shared.wipe()
        NotificationService.shared.wipe()
        VoIPPushService.shared.wipe()
        FavoritesStore.shared.wipe()
        ArchiveStore.shared.wipe()
        SectionsStore.shared.wipe()
        SectionCollapseStore.shared.wipe()
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
        // ⚠ Host-keyed, so it is NOT touched on an account switch (the other
        // accounts still need their islands drawn). A burn is the one path that
        // says everything is erased, and the file names in there are one island
        // host per file, a private self-hosted one included.
        IslandLogoStore.shared.wipe()
        // Same key, same reasoning: a pin is a statement about an island, not
        // about the account, and the burn is the one place it is erased.
        IslandTrust.shared.wipe()
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
        return true
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
        // BEFORE the flip: the chat list is interactive while a boot chain
        // still runs, and a fetch of the outgoing account that lands after
        // `setActive` would be published, cached and vaulted under the
        // incoming one. The services also check the account id per fetch;
        // this makes the window not exist in the first place.
        await settleBoot()
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
        // The chat list is interactive while the boot chain still runs, so
        // a switch can now land mid-chain; boot() drops a concurrent boot,
        // which would leave the new account half-booted under the old one's
        // identity. Let the running chain end first (its watchdog bounds it).
        await settleBoot()
        networkReady = false
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

        // Reset to the DESTINATION account's last-known capabilities (the
        // active account is already the new one here) so the switch shows
        // neither the stale outgoing island's surfaces nor `.defaultLegacy`
        // ones the new island turned off (uinShop, nearby) while the new
        // /server/info reply is in the air. `.defaultLegacy` only for an
        // account this device has never read an answer for; the boot fetch
        // still overwrites either way.
        serverCapabilities = AccountManager.shared.activeAccountID
            .flatMap { ServerCapabilitiesCache.capabilities(for: $0) } ?? .defaultLegacy
        serverInfoRead = false
        // Same reason: the outgoing island's name and rules must not sit in
        // Settings while the incoming one's reply is still in the air.
        serverName = ""
        serverWelcome = ""
        // ⚠ And the logo version with them, or the switcher's pill would keep
        // drawing the OUTGOING island's picture over the incoming island's
        // name for as long as the new reply takes: the cached card for the
        // account we just moved to is what fills it back in.
        serverLogoVersion = ""
        AccountManager.serverMaxAccounts = AccountManager.hardCap

        ContactService.shared.wipe()
        GroupService.shared.wipe()
        // Kill the backup-home poll BEFORE the stores below are repointed. It
        // is a detached 30s loop that nothing used to stop, so it outlived
        // every switch: a pass suspended in its own fetch resumed after these
        // rebinds and filed the outgoing account's rows, cross-island contact
        // requests included, under the incoming account (founder, 30.08). The
        // next drain starts it again for whoever is signed in then.
        Multihome.stopPolling()
        // Re-point cross-island contacts at the NEW account (per-account store);
        // boot()'s ContactService.refresh then merges the right ones in. Without
        // this, a cross-island contact added on one local account bled into the
        // others (founder report).
        CrossIslandStore.shared.bind(accountID: AccountManager.shared.activeAccountID)
        CrossIslandRequestsStore.shared.bind(accountID: AccountManager.shared.activeAccountID)
        StrangerQuarantine.shared.bind(accountID: AccountManager.shared.activeAccountID)
        VisitedIslandsStore.shared.bind(accountID: AccountManager.shared.activeAccountID)
        // The sections tree is per account and holds section names plus the uin
        // of every filed chat, so it is rebound here rather than left standing.
        SectionsStore.shared.bind(accountID: AccountManager.shared.activeAccountID)
        // Which sections are folded is per account too: the ids in it are the
        // outgoing account's, and they mean nothing in the incoming one's tree.
        SectionCollapseStore.shared.bind(accountID: AccountManager.shared.activeAccountID)
        ContactsVault.resetSyncState()
        PushDecryptCache.wipe()
        // Probe timers key on bare peer uins, which mean nothing on the
        // account we are switching to. The cached device lists key on the
        // same uins: uin 777 on the island we are leaving and uin 777 on the
        // one we are joining are two people with two sets of devices.
        SilenceProbe.shared.reset()
        await PeerDeviceCache.shared.invalidateAll()
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
        // Re-point the in-memory store at the NEW account's SQLite file. The
        // windows themselves were dropped by `resetInMemory` above, so this is
        // now the cheap half of what it used to be: nothing is read back here,
        // and each chat reads its own window when it is opened.
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
            applyOwnProfile(me)
        } catch {
            // Soft-fail.
        }
    }

    private func applyOwnProfile(_ me: UserProfile) {
        // Coerce a legacy .offline self-row to .online — the picker
        // can't reach .offline directly.
        let resolved: UserStatus = (me.status == .offline) ? .online : me.status
        PresenceService.shared.status = resolved
        PresenceService.shared.statusMessage = me.statusMessage
        AuthService.shared.updateNicknameLocal(me.nickname)
        // The same response has carried the picture all along and this was
        // throwing it away, which is why the header had nothing to draw.
        PresenceService.shared.setOwnAvatar(id: me.avatarMediaID, key: me.avatarMediaKey)
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

    /// The trust banner's button was pressed (§5.2): the island's certificate
    /// is on file now, so the API sessions are rebuilt and the socket redialled
    /// the way a route change rebuilds them, and a boot that ended on the
    /// refusal runs again. The route itself is left alone: the island was
    /// reachable all along, only refused.
    func reconnectAfterTrustAccepted() async {
        if APIClient.activeDirectBase() != APIClient.prodBaseURL,
           await APIClient.shared.probeDirectReachable() == .reachable {
            await APIClient.shared.useDirectSession()
        } else {
            await APIClient.shared.applyTransportProxy()
        }
        if booted {
            if isOffline {
                await runOnlineSync()
            } else {
                WebSocketService.shared.reconnectNow()
            }
        } else if bootError != nil {
            await boot()
        }
    }

    private func handle(_ event: WebSocketService.Event) {
        switch event {
        case .opened:
            // A live realtime socket is the definitive "we're online" signal —
            // clear any stale offline badge the boot watchdog may have set after
            // a slow first connect (the "Без сети while everything works" case).
            if isOffline { isOffline = false }
            // Drain offline queue on every (re)connect. The flags first when
            // they were never read: the room-log half of the drain is gated
            // on them.
            //
            // Never before `booted`. The socket opens in the middle of the
            // boot chain, and the drain that used to start right here walked
            // the whole backlog on the main actor while the first frames were
            // still being laid out: the list appeared and then stopped
            // answering. The drain has its own home at the end of `doBoot`
            // (and `runOnlineSync`), behind the interface; a socket that comes
            // up before that point can wait for it.
            if booted {
                Task {
                    await refreshServerInfoIfUnread()
                    await MessageService.shared.fetchOfflineQueue()
                }
            }
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
            // No chime against a roster restored from disk: its statuses are
            // last-known, not live, so the first live word about anybody
            // would read as them arriving or leaving right now.
            if contact != nil, !ContactService.shared.hydratedFromSnapshot {
                if status == .offline && wasOnline {
                    SoundService.shared.play(.contactOffline, thread: .peer(uin: uin))
                } else if status != .offline && !wasOnline {
                    SoundService.shared.play(.contactOnline, thread: .peer(uin: uin))
                }
            }

        case .envelope(let env):
            var decryptError: Error?
            let outcome = MessageService.shared.ingest(envelope: env, decryptError: &decryptError)
            // Stage 5: a logged broadcast names its seq. Once this frame is
            // dealt with (stored, deduped, or dropped for good: our own echo,
            // a replay) the room's cursor may move past it, so the next log
            // fetch does not serve it again. One that did not open stays
            // unacked and comes back through the drain, which holds it.
            if let gid = env.groupID, let seq = env.seq, outcome != nil || decryptError == nil {
                MessageService.shared.noteLiveGroupLogRow(gid: gid, seq: seq)
            }
            guard let outcome else { return }
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
            // The whole snapshot, so `ownerUIN` and every member's role come
            // with it: `upsert` replaces the row rather than diffing the
            // roster, which is what makes a handover land here live.
            GroupService.shared.upsert(group)

        case .groupOwnerChanged(let id, let owner):
            GroupService.shared.applyOwnerLocally(groupID: id, ownerUIN: owner)

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
             .roomMemberMuted, .roomOwnerOnlyChanged, .roomRenamed:
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
/// rule: pick the default that preserves the old behaviour. The single
/// exceptions are `hallOfFame` and `envelopeClass` (default FALSE), and
/// `uinShop`, which is a hard decode: an answer without it fails the whole
/// decode and the caller keeps the capability set it already had.
// Codable, not just Decodable: `ServerCapabilitiesCache` persists the last
// decoded answer per account. The synthesized encode uses the same
// CodingKeys, so a cached blob round-trips through the custom decoder like
// a wire reply would.
struct ServerCapabilities: Codable, Equatable {
    var uinShop: Bool
    var hallOfFame: Bool
    // Operator-toggleable optional features (admin console → Features). Each
    // defaults TRUE so a legacy server that omits the field keeps showing the
    // tab (pre-flag behaviour); the operator hides a feature by turning it off,
    // and the backing route is also 404-gated server-side.
    var nearby: Bool
    var randomChat: Bool
    // An island may run no report desk at all (admin console → Features). When
    // it doesn't, the two report entries go with it: a form the island answers
    // 403 and a screen that stays empty are worse than an absent menu row.
    // Permissive default like the rest, so an island older than the flag keeps
    // accepting reports.
    var reports: Bool
    // How many accounts one device may hold (operator-set). Caps the account
    // switcher; defaults to the historical 5.
    var maxAccountsPerDevice: Int
    // Stage 2 of the metadata plan: the island classifies a sealed row from the
    // sender's `cls` and honours `ring` on a `"message"` deposit, so a waking
    // call signal no longer has to be typed `"call"` to reach a closed app.
    // Defaults FALSE, like `hallOfFame` above, though for a different reason:
    // that one is a surface the flagship has and other islands do not, while
    // this is a wire ability. The permissive rule preserves old behaviour for
    // surfaces an old island already had; this
    // flag was born together with `ring`, so an island that omits it is an
    // island that does not know `ring`, and treating it as capable would turn
    // every cross-island call to it into silence. False here makes the call
    // path fall back to the legacy `"call"` deposit, which such an island
    // still rings on. Read by `CrossIslandSender`, never by the UI.
    var envelopeClass: Bool
    // Stage 3 of the metadata plan: the three key lookups (`/keys/{uin}/devices`
    // and the two bundles) accept no session token, so a fetch no longer tells
    // the island "A is about to talk to B" under A's identity. `anonKeys` says
    // the island serves them open; `depositAuth` says it also ISSUES the
    // anonymous deposit tokens a bundle fetch spends to take a one-time prekey.
    // Only BOTH together switch the lookups to the anonymous wire: one without
    // the other would be a half-anonymous request that gets the bundle minus
    // its prekey. Absent on an old island means false, and false means the
    // old authenticated path, exactly as before. Read by `SignalSession`,
    // never by the UI.
    var anonKeys: Bool
    var depositAuth: Bool
    // Stage 5 of the metadata plan: a post into a room is one row in the
    // room's log, read through /messages/group-log/fetch on a per-device
    // cursor, instead of one queue row per member. Absent on an old island
    // means false, and false means the client never calls the log endpoints:
    // its rooms keep arriving through /messages/queue exactly as before. The
    // first fetch flips the account to "log reader" on the island, so this is
    // read before every drain, never assumed. Read by `MessageService`, never
    // by the UI.
    var groupLog: Bool
    // Stage 4 of the metadata plan: the island serves PUT/GET/DELETE
    // /vault/{slot}, opaque versioned client-sealed slots per account. An
    // island that advertises it gets the contact list mirrored into the
    // account's `contacts` slot after every roster refresh (see
    // `ContactsVault`); one that does not is left alone. Absent means false.
    var vault: Bool

    init(
        uinShop: Bool,
        hallOfFame: Bool = true,
        nearby: Bool = true,
        randomChat: Bool = true,
        reports: Bool = true,
        maxAccountsPerDevice: Int = 5,
        envelopeClass: Bool = false,
        anonKeys: Bool = false,
        depositAuth: Bool = false,
        groupLog: Bool = false,
        vault: Bool = false
    ) {
        self.uinShop = uinShop
        self.hallOfFame = hallOfFame
        self.nearby = nearby
        self.randomChat = randomChat
        self.reports = reports
        self.maxAccountsPerDevice = maxAccountsPerDevice
        self.envelopeClass = envelopeClass
        self.anonKeys = anonKeys
        self.depositAuth = depositAuth
        self.groupLog = groupLog
        self.vault = vault
    }

    /// ⚠⚠ `uinShop: false`, and it is the ONE capability whose default is not
    /// "preserve the old behaviour".
    ///
    /// Every other default here is permissive so an island too old to answer
    /// `/server/info` keeps working as it did. This one is not, because the
    /// thing it gates is a shop: an island that has not answered yet, or
    /// cannot, or omits the field, must not have a storefront drawn for it on
    /// a guess. Showing a shop that is not there costs a person a wasted trip;
    /// hiding one that is there costs them one tap once the island answers.
    ///
    /// Android decodes with `false` (RcqApi.kt) and the web falls back to
    /// `false` per field (server-info.ts). iOS was the only client that failed
    /// OPEN here.
    static let defaultLegacy = ServerCapabilities(uinShop: false, hallOfFame: true)

    private enum CodingKeys: String, CodingKey {
        case uinShop = "uin_shop"
        case hallOfFame = "hall_of_fame"
        case nearby
        case randomChat = "random_chat"
        case reports
        case maxAccountsPerDevice = "max_accounts_per_device"
        case envelopeClass = "envelope_class"
        case anonKeys = "anon_keys"
        case depositAuth = "deposit_auth"
        case groupLog = "group_log"
        case vault
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
        reports = try c.decodeIfPresent(Bool.self, forKey: .reports) ?? true
        maxAccountsPerDevice = try c.decodeIfPresent(Int.self, forKey: .maxAccountsPerDevice) ?? 5
        // Absent means "predates ring": see the field comment.
        envelopeClass = try c.decodeIfPresent(Bool.self, forKey: .envelopeClass) ?? false
        // Absent means "predates open key lookups": see the field comment.
        anonKeys = try c.decodeIfPresent(Bool.self, forKey: .anonKeys) ?? false
        depositAuth = try c.decodeIfPresent(Bool.self, forKey: .depositAuth) ?? false
        // Absent means "predates the room log": see the field comment.
        groupLog = try c.decodeIfPresent(Bool.self, forKey: .groupLog) ?? false
        // Absent means "predates the vault": see the field comment.
        vault = try c.decodeIfPresent(Bool.self, forKey: .vault) ?? false
    }
}

/// Last-known `/server/info` capabilities per account, UserDefaults under the
/// account's UUID exactly like `AccountCardCache` (nothing here is a secret:
/// which surfaces an island advertises is served to anyone who can reach it).
/// Written on every successful `refreshServerInfo`, read to seed
/// `serverCapabilities` at boot and on account switch, so a feature the
/// operator disabled does not flash for the length of one round-trip on
/// every entry.
///
/// ⚠ Decoy-guarded on BOTH sides, mirroring `AccountCardCache`'s write rule:
/// a decoy session must not write (nothing about it touches disk) and must
/// not READ the real account's entry either, or the duress view would draw
/// the real island's feature set. Reads answer nil there, which lands the
/// caller on `.defaultLegacy`, the same face every fresh account shows.
///
/// ⚠ This cache feeds `serverCapabilities` ONLY. It never flips
/// `serverInfoRead`, so the three-state `vaultCapability` (nil until the
/// island answers THIS session) keeps waiting for the live reply.
@MainActor
enum ServerCapabilitiesCache {
    private static let prefix = "rcq.serverCaps.v1."

    private static func key(_ id: UUID) -> String { prefix + id.uuidString }

    static func capabilities(for id: UUID) -> ServerCapabilities? {
        guard !PanicPINService.shared.isDecoy,
              let data = UserDefaults.standard.data(forKey: key(id)) else { return nil }
        return try? JSONDecoder().decode(ServerCapabilities.self, from: data)
    }

    static func record(_ caps: ServerCapabilities, for id: UUID) {
        guard !PanicPINService.shared.isDecoy,
              let data = try? JSONEncoder().encode(caps) else { return }
        UserDefaults.standard.set(data, forKey: key(id))
    }

    /// Dropped along with the rest of an account's local state.
    static func forget(_ id: UUID) {
        UserDefaults.standard.removeObject(forKey: key(id))
    }
}

struct ServerInfoResponse: Decodable {
    let name: String
    /// The operator's welcome / rules text. Served since islands existed and
    /// read by nothing, which is why the admin panel warned that typing here
    /// changed nothing.
    let welcome: String?
    /// Digest of the island's logo; nil or empty means it has none and every
    /// caller draws the lettered tile (`IslandAvatarView`).
    ///
    /// ⚠ A VERSION, NOT A URL AND NOT THE PICTURE. The island sends twelve
    /// characters and the client builds
    /// `https://<host>/server/logo?v=<version>` itself. Two reasons. This
    /// reply is read on every boot AND by `fetch(host:)` against islands we are
    /// only PROBING, so a data URI in here would put a picture on all of those
    /// paths every time. And a URL would let any island, including one we have
    /// no account on, point the phone at a third-party host and collect the
    /// request; an island only ever gets to say WHETHER it has a logo and
    /// WHICH one.
    ///
    /// Absent on an island older than the field, which reads as no logo and
    /// draws the tile: the same permissive default the capability flags take.
    let logoVersion: String?
    let capabilities: ServerCapabilities

    private enum CodingKeys: String, CodingKey {
        case name
        case welcome
        case logoVersion = "logo_version"
        case capabilities
    }
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
            // `IslandHTTP`, not a bare session: this is the first handshake
            // with an island a person is about to join, so it rides the tunnel
            // when one is up and meets the trust rule like every island call.
            let (data, resp) = try await IslandHTTP.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(ServerInfoResponse.self, from: data)
        } catch {
            return nil
        }
    }

    /// The whole answer for the island we ARE on, not just the flags: the name
    /// and the house rules are two fields of the same reply, and dropping them
    /// here is why an operator could fill both in and see neither anywhere in
    /// the app except a join confirm for somebody else's island.
    static func fetch() async -> ServerInfoResponse? {
        do {
            return try await APIClient.shared.request(
                "GET",
                "/server/info",
                authenticated: false
            )
        } catch {
            return nil
        }
    }
}

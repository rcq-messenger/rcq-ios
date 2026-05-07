import Combine
import CoreLocation
import Foundation
import UIKit

/// People Nearby — opt-in, time-limited geo-discovery. Client
/// computes a level-6 geohash (~1.2km tile) from CoreLocation,
/// ships only the hash to `/nearby/checkin`, and refreshes
/// `/nearby/list?bucket=...` every 30s while the screen is visible.
/// Server never sees raw coordinates; mutual-visibility means a
/// passive sweeper can't enumerate without also being checked in.
///
/// State machine:
///   .idle            — not checked in. The "go online" button
///                      kicks off `start(ttl:)`.
///   .pending         — location request in flight (CL permission,
///                      first fix). Spinner UI.
///   .active(...)     — checked in, refreshing the list every 30s.
///                      `expiresAt` drives the countdown header in
///                      NearbyView.
///   .denied          — CoreLocation permission denied; UI shows a
///                      Settings deep-link.
///
/// On burn-account `wipe()` ends the checkin server-side too — we
/// don't want stale rows pointing at a UIN that no longer exists.
@MainActor
final class NearbyService: NSObject, ObservableObject {
    static let shared = NearbyService()

    enum State: Equatable {
        case idle
        case pending
        case active(bucketID: String, expiresAt: Date)
        case denied
        case error(String)
    }

    @Published private(set) var state: State = .idle
    /// Last-fetched list of nearby users in our bucket. Empty when
    /// idle / nobody else around. Refreshes via the 30s polling
    /// timer while `state == .active`.
    @Published private(set) var people: [NearbyPerson] = []
    /// Anonymous display name shown to other Nearby users and used
    /// as the byline on Hood Chat messages. Generated once and
    /// persisted so the same label sticks across app launches —
    /// otherwise a stranger you saw yesterday would show up under a
    /// new name today, which defeats the "I recognise that handle"
    /// mini-affordance Hood Chat depends on. The user can mint a
    /// fresh one via `regenerateDisplayName()`.
    @Published private(set) var displayName: String = NearbyService.loadOrMintDisplayName()
    /// Whether the next checkin should travel under the anonymous
    /// `displayName` (default) or under the real account nickname.
    /// Persists across launches; the user toggles it from the
    /// opt-in screen. Off-anonymous mode is for power-users who
    /// explicitly want to be discoverable as themselves — most
    /// people stay anonymous.
    @Published var anonymous: Bool = NearbyService.loadAnonymous()

    /// TTL we requested at start time. Useful for the "extend"
    /// affordance (re-checkin without a new fix).
    private var lastRequestedTTL: TimeInterval = 60 * 60

    private static let displayNameDefaultsKey = "nearby.displayName"
    private static let anonymousDefaultsKey = "nearby.anonymous"

    private let manager = CLLocationManager()
    private var refreshTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    override private init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        // Live-presence wiring. The 30s `/nearby/list` poll is
        // the catch-up source of truth; presence WS events let us
        // patch the in-flight roster between polls so a stranger
        // going `online → away` flips their dot without the user
        // having to close and re-open the sheet. We only mutate
        // rows already in `people` — a checkin we don't yet know
        // about waits for the next poll to surface.
        WebSocketService.shared.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self else { return }
                if case .presence(let uin, let status, _) = event {
                    self.applyPresence(uin: uin, status: status)
                }
            }
            .store(in: &cancellables)
        // Auto-stop on app termination. The opt-in TTL is "be
        // visible while the app is alive (foreground or
        // backgrounded) up to N minutes" — closing the Nearby
        // sheet must NOT end visibility, but quitting the app
        // should. iOS doesn't always grant termination time, so
        // this is best-effort; the server-side TTL is the
        // backstop. Doesn't fire for backgrounding (the user
        // wants to keep getting Add requests while their phone
        // is locked), only for actual termination.
        NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { await self.stop() }
            }
            .store(in: &cancellables)
    }

    private func applyPresence(uin: Int, status: UserStatus) {
        guard let idx = people.firstIndex(where: { $0.uin == uin }) else { return }
        var p = people[idx]
        // A peer flipping to `.offline` should also drop out of
        // the list — the server-side filter only fires at poll
        // time, but we want the row gone immediately.
        if status == .offline {
            people.remove(at: idx)
            return
        }
        p.status = status
        people[idx] = p
    }

    // MARK: - lifecycle

    /// Begin a check-in for `ttlSeconds`. Triggers a CL permission
    /// prompt the first time. Once a fix arrives we POST to
    /// `/nearby/checkin` with the hashed bucket and start the
    /// 30s refresh loop.
    ///
    /// Idempotent against retries — calling while in `.pending`
    /// or `.active` is a no-op so a double-tap or a re-entry from
    /// the error screen doesn't fire two location requests
    /// concurrently.
    func start(ttlSeconds: TimeInterval) {
        guard ttlSeconds >= 5 * 60 else { return }
        // Don't stack a new request on top of an in-flight one;
        // also avoid the pathological "I already have an active
        // checkin, why am I requesting location again" case.
        switch state {
        case .pending, .active:
            return
        default:
            break
        }
        lastRequestedTTL = ttlSeconds
        state = .pending
        let auth = manager.authorizationStatus
        switch auth {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
            // didChangeAuthorization → requestLocation
        case .authorizedWhenInUse, .authorizedAlways:
            // `requestLocation()` is one-shot and always fires the
            // delegate. Earlier code took a "cached" shortcut on
            // subsequent starts, but that returned stale GPS from
            // before the user simulated a Berlin location in
            // Xcode — so iPhone uploaded one bucket and sim
            // uploaded another, and they never found each other.
            // Fresh fix every time is correct.
            manager.requestLocation()
        case .denied, .restricted:
            state = .denied
        @unknown default:
            state = .denied
        }
    }

    /// Drop any in-flight error / pending state and let the caller
    /// kick off a fresh `start(ttlSeconds:)` — used by the error
    /// screen's "Reset" button so retries always start from a
    /// known-good `.idle`.
    func forceReset() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        people = []
        state = .idle
    }

    /// End the current checkin. Pulls the row server-side and
    /// stops the local polling. DELETE is fired *unconditionally*
    /// (even if the local state is already `.idle`) so calling
    /// this from `NearbyView.onDisappear` also sweeps any stale
    /// server-side row from a prior session that didn't get
    /// explicitly stopped — without this, opening the app right
    /// after a previous checkin would still leak the user into
    /// other people's lists for the rest of the TTL window.
    func stop() async {
        refreshTimer?.invalidate()
        refreshTimer = nil
        people = []
        state = .idle
        HoodChatService.shared.leave()
        let _: EmptyResponse? = try? await APIClient.shared.request("DELETE", "/nearby/checkin")
    }

    /// Burn-account hook.
    func wipe() {
        Task { await self.stop() }
    }

    // MARK: - server I/O

    /// Mint a new anonymous label, persist it, and (if we're
    /// currently checked in) push it to the server with a fresh
    /// checkin so other clients see the change. Listed in the
    /// public API so the UI can offer a "shuffle" affordance.
    func regenerateDisplayName() {
        let next = NearbyService.mintDisplayName()
        UserDefaults.standard.set(next, forKey: NearbyService.displayNameDefaultsKey)
        displayName = next
        if case .active(let bucket, _) = state {
            Task { await postCheckin(bucketID: bucket, ttl: lastRequestedTTL) }
        }
    }

    /// Persist the anonymous toggle and re-broadcast our checkin
    /// if we're already live. The opposite-state nickname (real
    /// nickname vs minted handle) propagates to other clients on
    /// their next list refresh.
    func setAnonymous(_ value: Bool) {
        anonymous = value
        UserDefaults.standard.set(value, forKey: NearbyService.anonymousDefaultsKey)
        if case .active(let bucket, _) = state {
            Task { await postCheckin(bucketID: bucket, ttl: lastRequestedTTL) }
        }
    }

    private func postCheckin(bucketID: String, ttl: TimeInterval) async {
        struct Body: Encodable {
            let bucket_id: String
            let ttl_seconds: Int
            // null when the user opted out of anonymous mode —
            // server falls back to the real account nickname,
            // matching the legacy-fallback path documented in
            // `routers/nearby.py`.
            let display_name: String?
        }
        struct Resp: Decodable { let expires_at: Date }
        do {
            let resp: Resp = try await APIClient.shared.request(
                "POST", "/nearby/checkin",
                body: Body(
                    bucket_id: bucketID,
                    ttl_seconds: Int(ttl),
                    display_name: anonymous ? displayName : nil
                )
            )
            state = .active(bucketID: bucketID, expiresAt: resp.expires_at)
            await refreshList()
            startRefreshTimer()
        } catch {
            // Log the underlying reason so iPhone Console captures
            // it — when the user reports "Try again" loops, the
            // actual error string (network, 4xx body, decode mismatch)
            // shows up here.
            print("[Nearby] postCheckin failed bucket=\(bucketID) ttl=\(ttl): \(error)")
            let detail = (error as? APIError).map { Self.describe($0) }
                ?? error.localizedDescription
            state = .error("Couldn't register your location.\n\(detail)")
        }
    }

    private static func describe(_ err: APIError) -> String {
        switch err {
        case .http(let code, let body):
            let trimmed = (body ?? "").prefix(120)
            return "HTTP \(code) — \(trimmed)"
        case .transport(let underlying):
            return underlying.localizedDescription
        case .decoding(let underlying):
            return "Decode: \(underlying.localizedDescription)"
        }
    }

    /// Pull the live list of nearby users. Called every 30s while
    /// active; also fires once immediately after `postCheckin`.
    /// Queries the caller's own bucket plus its eight neighbours —
    /// two devices on different sides of a 1km tile boundary
    /// (common in dense cities) still find each other. The query
    /// param is comma-separated: `?bucket=A,B,C,...`.
    ///
    /// Must go through `APIClient.request(query:)` rather than
    /// inlining `?bucket=...` in the path string — `APIClient`
    /// constructs the URL via `baseURL.appendingPathComponent`,
    /// which percent-encodes `?` and `,` as path characters. The
    /// server saw `/nearby/list%3Fbucket%3D...` and returned 404,
    /// silently breaking the whole feature.
    func refreshList() async {
        guard case .active(let bucket, _) = state else { return }
        let buckets = Geohash.selfAndNeighbours(of: bucket)
        let csv = buckets.joined(separator: ",")
        do {
            let resp: [NearbyPerson] = try await APIClient.shared.request(
                "GET", "/nearby/list",
                query: ["bucket": csv]
            )
            people = resp.sorted { $0.nickname.lowercased() < $1.nickname.lowercased() }
        } catch {
            // Soft-fail: keep the previous list. The next tick
            // retries.
        }
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshList() }
        }
    }

    // MARK: - anonymous display name

    /// Read the persisted anonymous label, generating a fresh one
    /// on first use. Stored in standard `UserDefaults` rather than
    /// the App Group container — the NSE doesn't need it, and we
    /// want it scoped to the main app.
    private static func loadOrMintDisplayName() -> String {
        if let stored = UserDefaults.standard.string(forKey: displayNameDefaultsKey),
           !stored.isEmpty {
            return stored
        }
        let fresh = mintDisplayName()
        UserDefaults.standard.set(fresh, forKey: displayNameDefaultsKey)
        return fresh
    }

    private static func loadAnonymous() -> Bool {
        // Default ON when the key has never been written. A bare
        // `bool(forKey:)` returns false in that case, which would
        // silently flip the user to non-anonymous mode at first
        // launch — the wrong default for a privacy feature.
        if UserDefaults.standard.object(forKey: anonymousDefaultsKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: anonymousDefaultsKey)
    }

    /// Two-word adjective+noun handle followed by a 4-digit number,
    /// e.g. "Wandering Stranger #4982". Word lists are deliberately
    /// gentle — drifty wanderer vibes, no edge or persona — to
    /// match the "you're a guest in this neighbourhood for an hour"
    /// framing of People Nearby.
    private static func mintDisplayName() -> String {
        let adjectives = [
            "Wandering", "Curious", "Silent", "Quirky", "Hopeful",
            "Restless", "Drifting", "Gentle", "Vibrant", "Witty",
            "Roaming", "Quiet", "Lucky", "Cosy", "Misty",
            "Twilight", "Dreamy", "Easy", "Mellow", "Fleeting",
        ]
        let nouns = [
            "Stranger", "Wanderer", "Traveler", "Passerby", "Drifter",
            "Visitor", "Voyager", "Nomad", "Soul", "Walker",
            "Guest", "Watcher", "Reader", "Sketcher", "Daydreamer",
            "Listener", "Observer", "Pilgrim", "Rambler", "Spirit",
        ]
        let adj = adjectives.randomElement() ?? "Wandering"
        let noun = nouns.randomElement() ?? "Stranger"
        let num = Int.random(in: 1000...9999)
        return "\(adj) \(noun) #\(num)"
    }
}

// MARK: - CLLocationManagerDelegate

extension NearbyService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                if case .pending = self.state {
                    manager.requestLocation()
                }
            case .denied, .restricted:
                self.state = .denied
            default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.first else { return }
        let bucket = Geohash.encode(
            lat: loc.coordinate.latitude,
            lon: loc.coordinate.longitude,
            length: 6
        )
        // Surface raw fix + computed bucket so cross-device
        // testing has something to compare against. Two devices
        // claiming the same simulated location should print the
        // same bucket — if they don't, the location simulation
        // didn't take effect on one of them.
        print("[Nearby] fix lat=\(loc.coordinate.latitude) lon=\(loc.coordinate.longitude) → bucket=\(bucket)")
        Task { @MainActor in
            await self.postCheckin(bucketID: bucket, ttl: self.lastRequestedTTL)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            // Don't go to .error if we were already idle — the
            // delegate fires spurious permission-related errors
            // sometimes.
            if case .pending = self.state {
                self.state = .error("Couldn't get your location.")
            }
        }
    }
}

/// One row in the nearby list. Rendered in NearbyView; tap →
/// option to send a contact request via the regular
/// `/contacts/request` endpoint.
struct NearbyPerson: Identifiable, Hashable, Decodable {
    let uin: Int
    let nickname: String
    /// True when `nickname` is the minted "Wandering Stranger
    /// #..." handle and the UIN should be hidden in the UI;
    /// false when this user opted out of anonymous mode at
    /// checkin time and `nickname` holds their real account
    /// nickname (UIN is fine to surface alongside it).
    let anonymous: Bool
    /// Mutable so `NearbyService.applyPresence` can patch the
    /// row in-place when a `.presence` WS event arrives between
    /// the 30s polling ticks.
    var status: UserStatus
    let statusMessage: String?
    /// Gender hint. Server already gated by `gender_visibility`;
    /// null = hide, otherwise the literal "male"/"female"/"other"
    /// the GenderIcon helper renders.
    let gender: String?
    let bucketID: String
    let expiresAt: Date

    var id: Int { uin }

    enum CodingKeys: String, CodingKey {
        case uin, nickname, anonymous, status, gender
        case statusMessage = "status_message"
        case bucketID = "bucket_id"
        case expiresAt = "expires_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.uin = try c.decode(Int.self, forKey: .uin)
        self.nickname = try c.decode(String.self, forKey: .nickname)
        self.anonymous = (try? c.decodeIfPresent(Bool.self, forKey: .anonymous)) ?? true
        let raw = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? "offline"
        self.status = UserStatus(rawValue: raw) ?? .offline
        self.statusMessage = try c.decodeIfPresent(String.self, forKey: .statusMessage)
        self.gender = try? c.decodeIfPresent(String.self, forKey: .gender)
        self.bucketID = try c.decode(String.self, forKey: .bucketID)
        self.expiresAt = try c.decode(Date.self, forKey: .expiresAt)
    }
}

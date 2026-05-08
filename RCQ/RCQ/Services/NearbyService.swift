import Combine
import CoreLocation
import Foundation
import UIKit

/// People Nearby — opt-in, time-limited geo-discovery. Client computes a
/// level-6 geohash (~1.2km tile) from CoreLocation and ships only the hash
/// to the server; mutual-visibility means a passive sweeper can't enumerate.
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
    @Published private(set) var people: [NearbyPerson] = []
    /// Anonymous handle persisted across launches so strangers can
    /// re-recognise it in Hood Chat.
    @Published private(set) var displayName: String = NearbyService.loadOrMintDisplayName()
    @Published var anonymous: Bool = NearbyService.loadAnonymous()

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
        WebSocketService.shared.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self else { return }
                if case .presence(let uin, let status, _) = event {
                    self.applyPresence(uin: uin, status: status)
                }
            }
            .store(in: &cancellables)
        // Best-effort auto-stop on termination; server TTL is the backstop.
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
        if status == .offline {
            people.remove(at: idx)
            return
        }
        p.status = status
        people[idx] = p
    }

    // MARK: - lifecycle

    /// Begin a check-in for `ttlSeconds`. Idempotent against retries.
    func start(ttlSeconds: TimeInterval) {
        guard ttlSeconds >= 5 * 60 else { return }
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
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            state = .denied
        @unknown default:
            state = .denied
        }
    }

    func forceReset() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        people = []
        state = .idle
    }

    /// End the current checkin. DELETE fires unconditionally so a
    /// stale prior-session row gets swept on .onDisappear.
    func stop() async {
        refreshTimer?.invalidate()
        refreshTimer = nil
        people = []
        state = .idle
        HoodChatService.shared.leave()
        let _: EmptyResponse? = try? await APIClient.shared.request("DELETE", "/nearby/checkin")
    }

    func wipe() {
        Task { await self.stop() }
    }

    // MARK: - server I/O

    func regenerateDisplayName() {
        let next = NearbyService.mintDisplayName()
        UserDefaults.standard.set(next, forKey: NearbyService.displayNameDefaultsKey)
        displayName = next
        if case .active(let bucket, _) = state {
            Task { await postCheckin(bucketID: bucket, ttl: lastRequestedTTL) }
        }
    }

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
            // null = server uses real account nickname.
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

    /// Polls own bucket plus eight neighbours so devices straddling
    /// a tile boundary still find each other. Must go through
    /// `query:` — `appendingPathComponent` percent-encodes `?`/`,`.
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
            // Soft-fail: keep previous list, next tick retries.
        }
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshList() }
        }
    }

    // MARK: - anonymous display name

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
        // Default ON; a bare bool(forKey:) returns false on a fresh key.
        if UserDefaults.standard.object(forKey: anonymousDefaultsKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: anonymousDefaultsKey)
    }

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
        print("[Nearby] fix lat=\(loc.coordinate.latitude) lon=\(loc.coordinate.longitude) → bucket=\(bucket)")
        Task { @MainActor in
            await self.postCheckin(bucketID: bucket, ttl: self.lastRequestedTTL)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            // Delegate fires spurious permission-related errors sometimes.
            if case .pending = self.state {
                self.state = .error("Couldn't get your location.")
            }
        }
    }
}

/// One row in the nearby list.
struct NearbyPerson: Identifiable, Hashable, Decodable {
    let uin: Int
    let nickname: String
    /// True when `nickname` is the minted handle (UIN should be hidden).
    let anonymous: Bool
    var status: UserStatus
    let statusMessage: String?
    /// null = hide, otherwise "male"/"female"/"other".
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

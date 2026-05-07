import Foundation

/// Local-only "people viewed your profile" tally. Lives entirely on the receiver's
/// device — when somebody opens our profile, their client sends a sealed `.visit`
/// envelope, our `MessageService` decrypts it and calls `record(viewer:at:)` here.
/// The server never sees the count, who incremented it, or that it exists at all.
///
/// Storage is a tiny JSON file in Application Support. Visits older than
/// `pruneAfter` are dropped on every save so the file can't grow unboundedly.
/// Same-viewer pings within `dedupWindow` collapse into one entry — protects
/// against tap-spam reloading the profile page (LinkedIn-style 1 unique view
/// per hour per viewer).
@MainActor
final class VisitStore: ObservableObject {
    static let shared = VisitStore()

    struct Visit: Codable, Equatable {
        let viewer: Int
        let at: Date
    }

    /// Window in which a repeated visit from the same UIN is treated as a duplicate
    /// rather than a fresh view. One hour matches the classic "unique visitor" feel.
    static let dedupWindow: TimeInterval = 60 * 60
    /// Drop visits older than this on every persist. 30 days gives us slack for any
    /// future "last 7 / 14 / 30 days" UI without retaining cold data forever.
    static let pruneAfter: TimeInterval = 30 * 86_400

    @Published private(set) var visits: [Visit] = []

    private let fileURL: URL

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RCQ", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("visits.json")
        load()
    }

    /// Append a visit if the same viewer hasn't pinged us in `dedupWindow`. Persists.
    func record(viewer: Int, at: Date) {
        // Clamp future-dated visits to "now" — sender clocks can drift, and we
        // don't want a misconfigured device inflating the next-7-days bucket.
        let clamped = min(at, Date())
        if let last = visits.last(where: { $0.viewer == viewer })?.at,
           clamped.timeIntervalSince(last) < Self.dedupWindow {
            return
        }
        visits.append(Visit(viewer: viewer, at: clamped))
        persist()
    }

    /// How many visits landed within the last `window` seconds.
    func count(within window: TimeInterval = 7 * 86_400) -> Int {
        let cutoff = Date().addingTimeInterval(-window)
        return visits.lazy.filter { $0.at >= cutoff }.count
    }

    /// Burn-account sweep. Erases the file and the in-memory copy.
    func wipe() {
        visits.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Visit].self, from: data) else {
            return
        }
        visits = decoded
    }

    private func persist() {
        let cutoff = Date().addingTimeInterval(-Self.pruneAfter)
        visits = visits.filter { $0.at >= cutoff }
        guard let data = try? JSONEncoder().encode(visits) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}

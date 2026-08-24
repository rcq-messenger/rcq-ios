import SwiftUI

/// The nine paintings the site floats on fed.rcq.app, cached per island.
///
/// An island's own LOGO is a different thing and lives in `IslandLogoStore`:
/// that one is uploaded by the operator and can be absent. This is decoration
/// the project ships, so every island has one and it never needs an operator to
/// do anything. The picker draws the logo ON the painting.
///
/// ⚠ Which painting a host gets is FNV-1a over the host, never `hashValue`:
/// Swift seeds its hashing per process, so the same island would change picture
/// on every launch, and it has to match what Android computes
/// (`IslandCatalog.artIndex`) or one island would be two different pictures
/// depending on the device in your hand. The flagship always gets island-1, the
/// green one, exactly as the website's hero does.
@MainActor
final class IslandArtStore: ObservableObject {
    static let shared = IslandArtStore()

    private let base = "https://rcq.app/islands/island-"
    private var memory: [Int: UIImage] = [:]
    private var logos: [String: UIImage] = [:]
    private var missed: Set<Int> = []

    static func index(forHost host: String) -> Int {
        let h = host.lowercased()
        if h == "api.rcq.app" { return 1 }
        var hash: UInt32 = 2_166_136_261
        for byte in h.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return 2 + Int(hash % 8)   // 2...9; island-1 is the flagship's
    }

    func cached(host: String) -> UIImage? { memory[Self.index(forHost: host)] }

    /// The painting, from memory, then the caches directory, then the site.
    /// Null draws nothing and the card stands on its own, which is a card and
    /// not a hole.
    func load(host: String) async -> UIImage? {
        let n = Self.index(forHost: host)
        if let hit = memory[n] { return hit }
        if missed.contains(n) { return nil }
        let file = Self.fileURL(n)
        if let data = try? Data(contentsOf: file), let img = UIImage(data: data) {
            memory[n] = img
            return img
        }
        guard let url = URL(string: "\(base)\(n).png") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("image/*", forHTTPHeaderField: "Accept")
        do {
            // ⚠ IslandHTTP, not URLSession.shared: same rule as the island
            // logos. A picture must never be the one request that steps outside
            // a tunnel the user deliberately engaged.
            let (data, resp) = try await IslandHTTP.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  data.count <= 3 * 1024 * 1024, let img = UIImage(data: data)
            else {
                missed.insert(n)
                return nil
            }
            try? data.write(to: file, options: .atomic)
            memory[n] = img
            return img
        } catch {
            missed.insert(n)
            return nil
        }
    }

    /// An island's mirrored logo, cached beside the paintings and keyed on the
    /// URL, so a replaced logo (a new file name from the catalogue) is a new
    /// cache entry rather than a stale picture.
    func logo(urlString: String?) async -> UIImage? {
        guard let urlString, urlString.hasPrefix("https://"), let url = URL(string: urlString) else { return nil }
        if let hit = logos[urlString] { return hit }
        let file = Self.logoFileURL(urlString)
        if let data = try? Data(contentsOf: file), let img = UIImage(data: data) {
            logos[urlString] = img
            return img
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("image/*", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await IslandHTTP.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  data.count <= 256 * 1024, let img = UIImage(data: data)
            else { return nil }
            try? data.write(to: file, options: .atomic)
            logos[urlString] = img
            return img
        } catch {
            return nil
        }
    }

    private static func logoFileURL(_ urlString: String) -> URL {
        let name = urlString.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("island-art", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("logo-\(name.suffix(80))")
    }

    private static func fileURL(_ n: Int) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("island-art", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("island-\(n).png")
    }
}

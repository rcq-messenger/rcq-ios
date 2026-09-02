import Foundation

/// The sites this device opened last: newest first, ten at most.
///
/// Per DEVICE and not per account, on purpose (founder, 02.09, all three
/// clients): a `.rcq` read carries no identity (see `SitesRepository`), so a
/// list of them belongs to the phone the way a browser's history does, not to
/// whichever account happens to be signed in. Keyed `name@host` like the pins,
/// for the same reason the pins are: `blog.rcq` here and `blog.flagship.rcq` on
/// the flagship are one site, and a list keyed by what was typed would show it
/// twice. The address to show is rebuilt from the pair at draw time, against
/// whatever island the reader is on NOW, so a row recorded under one account
/// still opens the right site under another.
///
/// ⚠ Device-wide also means a duress session sees it. Nothing here is secret,
/// but it is a record of reading, which is why it is capped and why every row
/// can be removed.
///
/// Not `@MainActor`, same lock as `SitePins`: cheaper than hopping actors for
/// an array of ten.
final class SiteRecents {
    static let shared = SiteRecents()

    struct Entry: Equatable {
        let name: String
        let host: String
        /// The manifest's title at the last open, for the second line of the
        /// row; a catalogue row shows the same thing.
        let title: String?

        var key: String { "\(name)@\(host)" }
    }

    static let limit = 10

    private static let storeKey = "rcq.siteRecents.v1"

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func all() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return read()
    }

    /// A page of this site was opened: it moves to the top, or joins there,
    /// and the tail past the cap falls off.
    func touch(_ address: SiteAddress, title: String?) {
        lock.lock()
        defer { lock.unlock() }
        var rows = read().filter { $0.key != address.pinKey }
        rows.insert(Entry(name: address.name, host: address.host, title: title), at: 0)
        write(Array(rows.prefix(Self.limit)))
    }

    func remove(key: String) {
        lock.lock()
        defer { lock.unlock() }
        write(read().filter { $0.key != key })
    }

    private func read() -> [Entry] {
        let rows = defaults.array(forKey: Self.storeKey) as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let name = row["name"] as? String, let host = row["host"] as? String else { return nil }
            return Entry(name: name, host: host, title: row["title"] as? String)
        }
    }

    private func write(_ rows: [Entry]) {
        let plain: [[String: Any]] = rows.map { row in
            var d: [String: Any] = ["name": row.name, "host": row.host]
            if let title = row.title { d["title"] = title }
            return d
        }
        defaults.set(plain, forKey: Self.storeKey)
    }
}

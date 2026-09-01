import Foundation

/// Trust on first use for site signing keys.
///
/// ⚠⚠ A manifest signature proves only that whoever holds the key in it made
/// these bytes; it says nothing about whether that is the same person as last
/// time. This is the half that does: the first key seen for a site is
/// remembered, and a different one later is REPORTED rather than accepted
/// silently. The same rule as safety numbers — the island may serve other
/// bytes, it may not pass them off as the same site.
///
/// The pin is keyed `name@host`, NEVER by what the reader typed. `blog.rcq` on
/// your own island and `blog.flagship.rcq` are one site; keyed by the typed
/// string they would have been two pins, and a key change would have gone
/// unseen on the other one.
///
/// Not `@MainActor`: the reader runs off the main thread and a pin is checked
/// in the middle of a fetch. A lock is cheaper than hopping actors for a
/// dictionary lookup.
final class SitePins {
    static let shared = SitePins()

    /// Same shape as the web's `rcq.web.sitePins`: a flat `name@host` → base64
    /// key map. Plain `UserDefaults` rather than the keychain — a pin is not a
    /// secret, and losing it costs a re-trust, not an account.
    private static let storeKey = "rcq.sitePins.v1"

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Returns true when this site was pinned to a DIFFERENT key before. A
    /// first sighting is stored and reported as unchanged; a changed key is
    /// NOT stored, so the banner keeps appearing until the reader decides.
    @discardableResult
    func pin(_ address: SiteAddress, key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var pins = read()
        let known = pins[address.pinKey]
        if let known, known != key { return true }
        if known == nil {
            pins[address.pinKey] = key
            write(pins)
        }
        return false
    }

    /// The key we have on file, if any. For chrome that wants to show it.
    func pinnedKey(for address: SiteAddress) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return read()[address.pinKey]
    }

    /// Accept a new key for a site, after the reader decided to trust it.
    func repin(_ address: SiteAddress, key: String) {
        lock.lock()
        defer { lock.unlock() }
        var pins = read()
        pins[address.pinKey] = key
        write(pins)
    }

    /// Forget a site entirely. Its next visit is a first use again.
    func forget(_ address: SiteAddress) {
        lock.lock()
        defer { lock.unlock() }
        var pins = read()
        pins.removeValue(forKey: address.pinKey)
        write(pins)
    }

    private func read() -> [String: String] {
        defaults.dictionary(forKey: Self.storeKey) as? [String: String] ?? [:]
    }

    private func write(_ pins: [String: String]) {
        defaults.set(pins, forKey: Self.storeKey)
    }
}

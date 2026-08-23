import Combine
import Foundation
import UIKit

/// Per-thread chat preferences. Currently just disappearing-message TTL,
/// but the structure is here for whatever per-thread toggles we add
/// later (notification mute is in `SoundService` because it needs to
/// gate sound playback at receive time, but that could move here too).
///
/// Each setting is **independent per side** — the user's local
/// preference on a thread doesn't propagate to the peer. For TTL this
/// matches Apple Messages's model: my "delete after 1h" only deletes
/// my copy. Symmetric across-the-wire deletion would need a session
/// settings envelope, which we're keeping out of scope until LibSignal
/// lands.
///
/// Persisted in UserDefaults — the dataset is small (one row per chat
/// the user has touched) and never security-sensitive.
@MainActor
final class ChatSettingsStore: ObservableObject {
    static let shared = ChatSettingsStore()

    /// `peer:<UIN>` / `group:<id>` → TTL in seconds. Absent or `0` means
    /// disappearing is off for that thread.
    @Published private(set) var ttlByThread: [String: Int] = [:]

    /// `peer:<UIN>` / `group:<id>` → screen-secure mode on. When on for a
    /// thread, that chat's screen is blanked in screenshots/recording (on
    /// BOTH sides — the flag is propagated to the peer via a `secureScreen`
    /// envelope), and a screenshot posts a "took a screenshot" notice.
    @Published private(set) var secureByThread: [String: Bool] = [:]

    private static let storageKey = "rcq.chat.ttl"
    private static let secureKey = "rcq.chat.secure"

    /// Discrete options the UI exposes. Off (`nil`), then a few human
    /// scales — minutes for testing, hours for normal use, a day for
    /// "definitely gone tomorrow."
    static let ttlOptions: [(label: String, seconds: Int?)] = [
        ("Off",        nil),
        ("1 minute",   60),
        ("5 minutes",  300),
        ("1 hour",     3_600),
        ("24 hours",   86_400),
        ("7 days",     604_800),
    ]

    private init() { load() }

    /// Live TTL for a thread, or nil if disappearing is off.
    func ttl(for thread: ThreadID) -> Int? {
        let v = ttlByThread[Self.threadKey(thread)] ?? 0
        return v > 0 ? v : nil
    }

    /// Set or clear the TTL for a thread. Pass nil to turn disappearing off.
    func setTTL(_ ttl: Int?, for thread: ThreadID) {
        let key = Self.threadKey(thread)
        if let ttl, ttl > 0 {
            ttlByThread[key] = ttl
        } else {
            ttlByThread.removeValue(forKey: key)
        }
        save()
    }

    /// Whether screen-secure mode is on for a thread.
    func isSecure(thread: ThreadID) -> Bool {
        secureByThread[Self.threadKey(thread)] ?? false
    }

    /// Set/clear screen-secure mode for a thread (local store only — the
    /// caller propagates to the peer via a `secureScreen` envelope).
    func setSecure(_ on: Bool, for thread: ThreadID) {
        let key = Self.threadKey(thread)
        if on { secureByThread[key] = true } else { secureByThread.removeValue(forKey: key) }
        saveSecure()
    }

    /// Burn-account hook — wipe everything along with the rest of the
    /// local state.
    func wipe() {
        ttlByThread.removeAll()
        secureByThread.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
        UserDefaults.standard.removeObject(forKey: Self.secureKey)
    }

    /// Human label for the live TTL of a thread — used by the chat header
    /// menu indicator and the system-notice text.
    static func label(for ttl: Int?) -> String {
        guard let ttl else { return "Off" }
        return ttlOptions.first { $0.seconds == ttl }?.label ?? "\(ttl)s"
    }

    /// The instant an inbound disappearing message should count down FROM,
    /// given the sender's `ts` (epoch SECONDS, straight off the envelope) and
    /// the time this device would otherwise have used: the island's deposit
    /// time for a queued row, receipt for everything else.
    ///
    /// Returns nil when the claim is unusable, and nil means "keep doing what
    /// this client did before this field existed: the caller stores no anchor
    /// and the countdown runs from `sentAt`. An old peer that sends no `ts` at
    /// all lands here too, which is the whole compatibility story.
    ///
    /// ⚠ `ts` is written by the peer's client, inside the ciphertext where the
    /// island cannot touch it but the SENDER can put anything. Two rails:
    ///
    /// • A value in the FUTURE of `receipt` (more than a minute, which is
    ///   ordinary clock skew) is rejected. This is the one that matters. The
    ///   bubble prints "disappears after 1 minute" from `ttl`, so a sender who
    ///   pairs `ttl: 60` with a `ts` a year out would have that message sit in
    ///   the recipient's history for a year while the UI promised a minute. A
    ///   sender is entitled to choose the timer; it is not entitled to make the
    ///   timer we display a lie.
    ///
    /// • A value at or before the epoch, or more than a year older than
    ///   `receipt`, is rejected. Zero, a negative, and a client that sent
    ///   MILLISECONDS (which lands either absurdly far forward, caught by the
    ///   rail above, or absurdly far back once divided wrong) are bugs, not
    ///   clocks. Honouring them would expire everything the moment it arrived.
    ///   A year is far past the longest timer we offer, so nothing legitimate
    ///   is inside this rail.
    ///
    /// Rejection is never a drop: the message is kept and counted from
    /// `receipt`, which is exactly what this client did yesterday.
    nonisolated static func senderSentAt(ts: Int?, receipt: Date) -> Date? {
        guard let ts, ts > 0 else { return nil }
        let claimed = Date(timeIntervalSince1970: TimeInterval(ts))
        if claimed > receipt.addingTimeInterval(60) { return nil }
        if claimed < receipt.addingTimeInterval(-365 * 24 * 3_600) { return nil }
        return claimed
    }

    /// Same key shape as `ThreadID.kindString` + `.rawKey` join. Kept
    /// private so Swift name-mangling doesn't drift between callers.
    private static func threadKey(_ thread: ThreadID) -> String {
        switch thread {
        case .peer(let uin):  return "peer:\(uin)"
        case .group(let id):  return "group:\(id)"
        }
    }

    private func load() {
        if let raw = UserDefaults.standard.dictionary(forKey: Self.storageKey) {
            ttlByThread = raw.compactMapValues { $0 as? Int }
        }
        if let raw = UserDefaults.standard.dictionary(forKey: Self.secureKey) {
            secureByThread = raw.compactMapValues { $0 as? Bool }
        }
    }

    private func save() {
        UserDefaults.standard.set(ttlByThread, forKey: Self.storageKey)
    }

    private func saveSecure() {
        UserDefaults.standard.set(secureByThread, forKey: Self.secureKey)
    }
}

/// GLOBAL chat wallpaper (one for the whole app, Android parity). The
/// selection is `""` (default theme bg), `preset:<id>`, or `custom` (a JPEG
/// saved on disk). Persisted in UserDefaults; the custom image is a file.
@MainActor
final class ChatBackgroundStore: ObservableObject {
    static let shared = ChatBackgroundStore()

    @Published private(set) var selection: String = ""
    /// HOME / chat-list wallpaper (a SEPARATE selection, founder's choice).
    @Published private(set) var homeSelection: String = ""
    /// Bumped when a custom image file is replaced, so views re-read it.
    @Published private(set) var customStamp: Int = 0
    @Published private(set) var homeCustomStamp: Int = 0

    /// Is the CUSTOM image light or dark? `nil` when the selection is not a
    /// custom image, or when it has not been measured yet.
    ///
    /// The built-in presets do not need this: they are authored per theme
    /// (`Theme.Wallpaper`), so the chrome standing on them always has the
    /// ground its colours were written for. A picture out of the user's gallery
    /// has no such promise, because somebody in the dark theme picks a white
    /// beach, and it is the one case where the FOREGROUND has to give way.
    /// This is the measurement it gives way on: the mean tone of the top strip,
    /// against the same WCAG 0.179 line Android's `needsLightChrome` uses.
    /// A view compares it with its own `colorScheme` and decides.
    @Published private(set) var customIsLight: Bool?
    @Published private(set) var homeCustomIsLight: Bool?

    private static let key = "rcq.chat.background"
    private static let homeKey = "rcq.home.background"
    private static let toneKey = "rcq.chat.background.light"
    private static let homeToneKey = "rcq.home.background.light"

    /// Which measurement a landing tone belongs to, one counter per surface.
    ///
    /// The measurement runs off the main actor and takes as long as the photo
    /// is big. Pick a large dark picture and then a small light one a moment
    /// later and the second decode finishes FIRST, so without this the first
    /// one lands last and persists the outgoing picture's verdict for the
    /// incoming picture. Every start bumps its counter; a result that is not
    /// from the current one is dropped.
    private var chatToneStamp = 0
    private var homeToneStamp = 0

    private init() {
        selection = UserDefaults.standard.string(forKey: Self.key) ?? ""
        homeSelection = UserDefaults.standard.string(forKey: Self.homeKey) ?? ""
        customIsLight = UserDefaults.standard.object(forKey: Self.toneKey) as? Bool
        homeCustomIsLight = UserDefaults.standard.object(forKey: Self.homeToneKey) as? Bool
        // An image saved by a build that predates the measurement has a file
        // and no tone. Measure it once, off the main actor, rather than
        // making everyone who upgrades re-pick their wallpaper.
        measureIfMissing(home: false)
        measureIfMissing(home: true)
    }

    static func imageURL(home: Bool) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent(home ? "rcq-home-bg.jpg" : "rcq-chat-bg.jpg")
    }
    static var customImageURL: URL { imageURL(home: false) }

    func selection(home: Bool) -> String { home ? homeSelection : selection }
    func customStamp(home: Bool) -> Int { home ? homeCustomStamp : customStamp }
    func customIsLight(home: Bool) -> Bool? { home ? homeCustomIsLight : customIsLight }

    /// How the chrome standing on this surface's wallpaper should paint itself.
    ///
    /// The rule is `WallpaperSurface.mode`, shared with the home screen so one
    /// picture set in both slots is read the same way on both. This is only the
    /// store's side of it, so a view has to know nothing but its own theme.
    func surface(home: Bool, isLightTheme: Bool) -> WallpaperSurface {
        WallpaperSurface.mode(
            selection: selection(home: home),
            customIsLight: customIsLight(home: home),
            isLightTheme: isLightTheme
        )
    }

    func set(_ s: String, home: Bool = false) {
        if home {
            homeSelection = s
            UserDefaults.standard.set(s, forKey: Self.homeKey)
        } else {
            selection = s
            UserDefaults.standard.set(s, forKey: Self.key)
        }
    }

    /// Save a picked image (already JPEG-compressed) as the custom wallpaper.
    func saveCustom(_ data: Data, home: Bool = false) {
        let url = Self.imageURL(home: home)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
        if home { homeCustomStamp &+= 1 } else { customStamp &+= 1 }
        set("custom", home: home)
        // Cleared FIRST. Replacing one custom image with another would
        // otherwise leave the outgoing picture's tone in place for as long as
        // the measurement takes, and a bright photo inheriting a dark one's
        // verdict is exactly the wrong answer at exactly the wrong moment.
        adoptTone(nil, home: home)
        let stamp = bumpToneStamp(home: home)
        // Measured from the bytes we already hold, so the picker's own
        // "done" is also the moment the chrome knows what it is standing on.
        // ⚠ `self` is re-bound to a `let` before the hop. A `[weak self]`
        // capture is a mutable var, and reading a var from inside a second
        // concurrently-executing closure is an error under Swift 6.
        Task.detached(priority: .utility) { [weak self, data] in
            let light = Self.topStripIsLight(data)
            guard let store = self else { return }
            await MainActor.run { store.adoptTone(light, home: home, stamp: stamp) }
        }
    }

    func wipe() {
        set(""); set("", home: true)
        // Bumped so a measurement still in flight cannot paint a tone back
        // onto a wallpaper that no longer exists.
        _ = bumpToneStamp(home: false)
        _ = bumpToneStamp(home: true)
        adoptTone(nil, home: false)
        adoptTone(nil, home: true)
        try? FileManager.default.removeItem(at: Self.imageURL(home: false))
        try? FileManager.default.removeItem(at: Self.imageURL(home: true))
    }

    /// Next stamp for a surface. Every measurement takes one before it hops
    /// off the actor and hands it back when it lands.
    private func bumpToneStamp(home: Bool) -> Int {
        if home {
            homeToneStamp &+= 1
            return homeToneStamp
        }
        chatToneStamp &+= 1
        return chatToneStamp
    }

    /// `stamp` is nil for the synchronous writes (clearing on a new pick, on
    /// wipe), which are always current by definition. A measurement passes the
    /// stamp it started with and is dropped if a newer one has started since.
    private func adoptTone(_ light: Bool?, home: Bool, stamp: Int? = nil) {
        if let stamp, stamp != (home ? homeToneStamp : chatToneStamp) { return }
        let key = home ? Self.homeToneKey : Self.toneKey
        if let light {
            UserDefaults.standard.set(light, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        if home { homeCustomIsLight = light } else { customIsLight = light }
    }

    /// Backfill for a custom image that is on disk with no tone recorded.
    private func measureIfMissing(home: Bool) {
        guard selection(home: home) == "custom", customIsLight(home: home) == nil else { return }
        let url = Self.imageURL(home: home)
        let stamp = bumpToneStamp(home: home)
        Task.detached(priority: .utility) { [weak self] in
            guard let data = try? Data(contentsOf: url) else { return }
            let light = Self.topStripIsLight(data)
            // See `saveCustom`: bound to a `let` before the actor hop.
            guard let store = self else { return }
            await MainActor.run { store.adoptTone(light, home: home, stamp: stamp) }
        }
    }

    /// Mean tone of the TOP eighth of a wallpaper, the strip the header and
    /// the first rows cover, as "is it light".
    ///
    /// Downsampled to 8x2 before averaging on purpose: the only question being
    /// asked is light-or-dark, and sixteen box-filtered pixels answer it
    /// exactly as well as twelve megapixels while costing nothing to hold.
    /// Same shape as Android's `topStripTone` + `needsLightChrome`, and the
    /// same 0.179 WCAG line, so the two clients decide alike on one picture.
    ///
    /// `nonisolated` and taking bytes rather than a URL: it runs off the main
    /// actor, and decoding a gallery photo is not work for the actor that
    /// draws the chat list.
    nonisolated static func topStripIsLight(_ data: Data) -> Bool? {
        guard let source = UIImage(data: data)?.cgImage else { return nil }
        // CGImage crop coordinates have their origin at the TOP-left, which is
        // the strip we want without any flipping.
        let rows = max(1, source.height / 8)
        guard let strip = source.cropping(
            to: CGRect(x: 0, y: 0, width: source.width, height: rows)
        ) else { return nil }
        let w = 8, h = 2
        // `data: nil` lets Core Graphics own the buffer: handing it a pointer
        // into a local array would let that pointer outlive the call that
        // produced it, which is the classic way to make this crash on somebody
        // else's photo and nowhere else.
        guard let ctx = CGContext(
            data: nil,
            width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(strip, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let raw = ctx.data else { return nil }
        let pixels = raw.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var total = 0.0
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            total += relativeLuminance(
                r: pixels[i], g: pixels[i + 1], b: pixels[i + 2]
            )
        }
        return total / Double(w * h) >= 0.179
    }

    /// WCAG relative luminance of an sRGB triplet.
    private nonisolated static func relativeLuminance(r: UInt8, g: UInt8, b: UInt8) -> Double {
        func linear(_ c: UInt8) -> Double {
            let v = Double(c) / 255
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }
}

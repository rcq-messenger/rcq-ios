import Foundation

/// The commit this binary was built from, dropped into the bundle by the
/// "Stamp the commit into the bundle" build phase.
///
/// ⚠ It lives in a plain resource rather than Info.plist because the plist is
/// regenerated after the script phases run, which quietly ate the first
/// version of this. Empty when the phase did not run (a stale build, or a
/// checkout with no git).
enum BuildStamp {
    static let value: String = {
        guard let url = Bundle.main.url(forResource: "build-stamp", withExtension: "txt"),
              let s = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }()

    /// "1.0.0 (131) · a1b2c3d, 07.09.2026" — a trailing `+` on the commit means
    /// the tree had uncommitted edits when this was built.
    static func line(prefix: String = "") -> String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let head = "\(prefix)\(v) (\(b))"
        return value.isEmpty ? head : "\(head) · \(value)"
    }
}

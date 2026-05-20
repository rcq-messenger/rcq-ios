import Combine
import Foundation
import SwiftUI
import UIKit

/// Telegram-style in-app banner shown above the NavigationStack when a
/// new envelope lands while the app is foregrounded. Suppressed for the
/// thread the user is already viewing — the message itself lands in the
/// open chat, which is signal enough.
@MainActor
final class MessageBannerService: ObservableObject {
    static let shared = MessageBannerService()

    @Published private(set) var current: Banner?

    /// Set by ChatView on appear / cleared on disappear. Banners for
    /// the active thread are skipped (user already sees the message
    /// arrive).
    private var activeThread: ThreadID?
    private var dismissTask: Task<Void, Never>?

    private static let visibleDuration: TimeInterval = 3.5

    /// Tap-routing target. `thread(_)` routes to a chat via the
    /// existing pending-open flags on AppState; `auction` routes to
    /// the UIN auction sheet via the same overlay host.
    enum Target: Equatable {
        case thread(ThreadID)
        case auction
        // Reputation grants — no tap routing; the banner is informational
        // ("you received +N reputation"). Tap dismisses, that's it.
        case reputation
    }

    struct Banner: Identifiable, Equatable {
        let id: UUID
        let target: Target
        let title: String
        let body: String

        static func == (lhs: Banner, rhs: Banner) -> Bool { lhs.id == rhs.id }
    }

    private init() {}

    func setActive(_ thread: ThreadID?) {
        activeThread = thread
        // If the user just navigated into the thread the banner is
        // pointing at, retire it — the chat is now on-screen.
        if let cur = current, case .thread(let bt) = cur.target, bt == thread {
            current = nil
            dismissTask?.cancel()
        }
    }

    /// Clear active-thread only if it still matches `thread` — guards
    /// against an `onDisappear` from a sheet-presenting parent (which
    /// fires while the chat is still effectively on-screen) wiping out
    /// the slot mid-session.
    func clearActiveIfMatches(_ thread: ThreadID) {
        if activeThread == thread {
            activeThread = nil
        }
    }

    /// Decide whether to surface a banner for the given thread. Returns
    /// `true` when the banner was shown; the caller uses the return value
    /// to gate the incoming-sound effect so audio + visual stay in sync.
    @discardableResult
    func tryPresent(thread: ThreadID, title: String, body: String) -> Bool {
        // Background → APNs handles the user-facing alert.
        guard UIApplication.shared.applicationState == .active else { return false }
        // Same chat that's currently on-screen — don't double up.
        if activeThread == thread { return false }
        return showBanner(target: .thread(thread), title: title, body: body)
    }

    /// Non-thread banner — used for system events like a UIN-auction
    /// outbid. Suppressed when the app is backgrounded (APNs handles
    /// it) but not gated on `activeThread`. Tap routes through
    /// `Target.auction` to open the auction sheet.
    @discardableResult
    func tryPresentSystem(title: String, body: String, target: Target) -> Bool {
        guard UIApplication.shared.applicationState == .active else { return false }
        return showBanner(target: target, title: title, body: body)
    }

    private func showBanner(target: Target, title: String, body: String) -> Bool {
        let banner = Banner(id: UUID(), target: target, title: title, body: body)
        current = banner
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.visibleDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                if self.current?.id == banner.id { self.current = nil }
            }
        }
        return true
    }

    func dismiss(_ id: UUID) {
        guard current?.id == id else { return }
        current = nil
        dismissTask?.cancel()
    }
}

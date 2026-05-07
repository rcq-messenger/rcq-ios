import SwiftUI

/// Random Chat entry surface. Hosts the START button and queue indicator
/// when no session is active, and pivots to ChatView the moment a stranger
/// is matched. The same sheet stays mounted across (idle → queueing →
/// matched → idle again) cycles, so Skip just re-renders the screen
/// rather than dismissing and re-presenting.
struct RouletteView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var service = RandomChatService.shared

    /// Drives navigation to the user's own profile when they tap
    /// "Open profile" inside the age-gate modal. Set when the modal's
    /// CTA fires; cleared when the resulting sheet closes.
    @State private var openOwnProfile: Bool = false

    var body: some View {
        ZStack {
            Theme.Color.bgPrimary.ignoresSafeArea()
            // Compute (peer, endedReason) up front so the
            // `chatSurface` call site lives at a single,
            // identity-stable position in the SwiftUI view tree —
            // the previous switch-per-case structure put .matched
            // and .ended in different `_ConditionalContent`
            // branches, which iOS treats as different View
            // identities. Result: every .matched → .ended
            // transition unmounted and re-mounted ChatView,
            // appearing to the user as "chat closed mid-send".
            // With a single branch, the chat surface stays
            // mounted across the transition; only the banner
            // appears on top.
            let chatBinding = activeChat
            let _ = print("[Roulette] body: state=\(state) hasBinding=\(chatBinding != nil)")
            if let chatBinding {
                chatSurface(peer: chatBinding.peer, endedReason: chatBinding.endedReason)
            } else {
                inactiveContent
            }
        }
        // Swipe-down-to-dismiss is handy for idle/queueing but
        // dangerous mid-chat — iOS sometimes processes a
        // PhotoPicker dismiss as a parent-sheet swipe, which
        // would yank Roulette closed mid-send. Lock the sheet
        // while we're in an active chat; the user can still leave
        // explicitly via the X / back buttons.
        // (Defensive — kept even though the parent now uses
        // `fullScreenCover` and has no swipe gesture at all. If
        // we ever flip back to `.sheet` this stays correct.)
        .interactiveDismissDisabled(isInActiveChat)
        // Age-gate modal. Server returns 403 with code "age_required"
        // (no age set on profile) or "under_18" (age set but below 18).
        // Stranger Mode is 18+ only — this is the iOS-side surface for
        // that contract, with the backend enforcing it server-side.
        .alert(
            ageGateTitle,
            isPresented: ageGateBinding,
            actions: { ageGateActions },
            message: { Text(ageGateMessage) }
        )
        // Profile sheet — fired from the age-gate "Set your age" CTA.
        // We push the local user's own profile so they can fill in the
        // age and come back to Stranger Mode.
        .sheet(isPresented: $openOwnProfile) {
            if let ownUIN = AuthService.shared.ownUIN {
                NavigationStack {
                    UserInfoView(uin: ownUIN, isOwn: true)
                }
            }
        }
        .onAppear { print("[Roulette] onAppear state=\(state)") }
        .onDisappear { print("[Roulette] onDisappear state=\(state)") }
    }

    private var ageGateBinding: Binding<Bool> {
        Binding(
            get: { service.ageGateBlock != nil },
            set: { if !$0 { service.acknowledgeAgeGate() } }
        )
    }

    private var ageGateTitle: String {
        switch service.ageGateBlock {
        case .ageRequired: return "stranger.gate.age_required.title".localized
        case .under18:     return "stranger.gate.under_18.title".localized
        case .none:        return ""
        }
    }

    private var ageGateMessage: String {
        switch service.ageGateBlock {
        case .ageRequired: return "stranger.gate.age_required.body".localized
        case .under18:     return "stranger.gate.under_18.body".localized
        case .none:        return ""
        }
    }

    @ViewBuilder
    private var ageGateActions: some View {
        switch service.ageGateBlock {
        case .ageRequired:
            // Set-your-age CTA opens the local profile. Modal dismisses
            // first, profile pushes a beat later so SwiftUI doesn't
            // race the sheet stack.
            Button("stranger.gate.cta.set_age".localized) {
                service.acknowledgeAgeGate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    openOwnProfile = true
                }
            }
            Button("common.cancel".localized, role: .cancel) {
                service.acknowledgeAgeGate()
            }
        case .under18, .none:
            // Below-18 has no path forward — just an OK acknowledgement.
            Button("common.ok".localized, role: .cancel) {
                service.acknowledgeAgeGate()
            }
        }
    }

    private var state: String {
        switch service.state {
        case .idle: return "idle"
        case .queueing: return "queueing"
        case .matched(let p): return "matched(\(p.uin))"
        case .ended(let r): return "ended(\(r))"
        }
    }

    private var isInActiveChat: Bool {
        switch service.state {
        case .matched, .ended: return true
        default: return false
        }
    }

    /// Either we're showing the live chat or we're not. Collapses
    /// `.matched` and `.ended(lastPeer)` into a single shape so
    /// the chatSurface call below has a stable identity.
    private var activeChat: (peer: RandomPeer, endedReason: String?)? {
        switch service.state {
        case .matched(let peer):
            return (peer, nil)
        case .ended(let reason):
            if let last = service.lastPeer { return (last, reason) }
            return nil
        default:
            return nil
        }
    }

    @ViewBuilder
    private var inactiveContent: some View {
        switch service.state {
        case .queueing:
            queueing
        case .ended(let reason):
            idle(message: endedMessage(for: reason))
        default:
            idle(message: nil)
        }
    }

    /// Chat shell used in both `.matched` and `.ended(lastPeer)`
    /// states. Banner is the only visual diff — ChatView itself
    /// stays identity-stable across the transition.
    ///
    /// The wrapping `NavigationStack` is load-bearing. Without it
    /// the chain looked like
    ///   `fullScreenCover { RouletteView { ChatView { .sheet { PhotoPicker } } } }`
    /// and on iOS 17+ SwiftUI unwinds the modal hierarchy
    /// incorrectly when the inner `.sheet` (PhotoPicker /
    /// VideoPicker) dismisses — it tears down the parent
    /// fullScreenCover too, so the user lost the random session
    /// the moment they finished sending a photo. Wrapping
    /// ChatView in its own NavigationStack gives those inner
    /// sheets a UIKit `UINavigationController` to scope their
    /// presentation against, so picker dismiss no longer
    /// propagates upward. ChatView already has
    /// `.toolbar(.hidden, for: .navigationBar)` so the nav-bar
    /// chrome stays hidden as before.
    private func chatSurface(peer: RandomPeer, endedReason: String?) -> some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let reason = endedReason {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(Theme.Color.statusBusy)
                        Text(endedMessage(for: reason))
                            .font(.caption)
                            .foregroundColor(Theme.Color.textPrimary)
                            .lineLimit(2)
                        Spacer()
                        Button("common.close".localized) { service.clearEnded() }
                            .font(.caption.weight(.semibold))
                            .foregroundColor(Theme.Color.accent)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Theme.Color.bgSecondary)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                ChatView(target: .randomPeer(peer))
            }
            .animation(.easeInOut(duration: 0.2), value: endedReason)
        }
    }

    // MARK: - states

    private func idle(message: String?) -> some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "theatermasks.fill")
                .font(.system(size: 80))
                .foregroundColor(Theme.Color.accent)
            VStack(spacing: 6) {
                Text("random.title".localized).font(.title2.bold())
                    .foregroundColor(Theme.Color.textPrimary)
                Text("random.body".localized)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundColor(Theme.Color.textSecondary)
                    .padding(.horizontal, 24)
            }
            if let message {
                Text(message)
                    .font(.caption.italic())
                    .foregroundColor(Theme.Color.textSecondary)
                    .padding(.horizontal, 24)
                    .multilineTextAlignment(.center)
            }
            Button { Task { await service.startQueue() } } label: {
                Text("random.cta.start".localized).font(.system(.title3, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Theme.Color.accent)
                    .cornerRadius(8)
            }
            .padding(.horizontal, 32)
            Button("common.close".localized) { dismiss() }
                .foregroundColor(Theme.Color.textSecondary)
            Spacer()
        }
    }

    private var queueing: some View {
        VStack(spacing: 18) {
            Spacer()
            ProgressView().tint(Theme.Color.accent).scaleEffect(1.6)
            Text("random.queueing.title".localized)
                .font(.headline)
                .foregroundColor(Theme.Color.textPrimary)
            Text("random.queueing.body".localized)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundColor(Theme.Color.textSecondary)
                .padding(.horizontal, 32)
            Button { Task { await service.leave() } } label: {
                Text("common.cancel".localized).font(.system(.body, weight: .semibold))
                    .foregroundColor(Theme.Color.statusBusy)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(Theme.Color.bgSecondary)
                    .cornerRadius(8)
            }
            .padding(.horizontal, 32)
            Spacer()
        }
    }

    private func endedMessage(for reason: String) -> String {
        switch reason {
        case "expired":           return "random.ended.expired".localized
        case "peer_left":         return "random.ended.peer_left".localized
        case "peer_skipped":      return "random.ended.peer_skipped".localized
        case "peer_disconnected": return "random.ended.peer_disconnected".localized
        default:                  return "random.ended.default".localized
        }
    }
}

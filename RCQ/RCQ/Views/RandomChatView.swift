import SwiftUI

/// Random Chat entry surface. Hosts START + queue indicator when idle
/// and pivots to ChatView once matched; the sheet stays mounted across
/// idle → queueing → matched → idle cycles so Skip just re-renders.
struct RandomChatView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var service = RandomChatService.shared

    @State private var openOwnProfile: Bool = false

    var body: some View {
        ZStack {
            Theme.Color.bgPrimary.ignoresSafeArea()
            // Single-branch chatSurface call: putting .matched and
            // .ended in separate ConditionalContent branches assigns
            // different identities and unmounts ChatView mid-send.
            let chatBinding = activeChat
            let _ = print("[Roulette] body: state=\(state) hasBinding=\(chatBinding != nil)")
            if let chatBinding {
                chatSurface(peer: chatBinding.peer, endedReason: chatBinding.endedReason)
            } else {
                inactiveContent
            }
        }
        // Defensive: PhotoPicker dismiss can register as a parent-sheet
        // swipe and close Roulette mid-send. Parent uses fullScreenCover
        // now but this stays correct if we ever flip back to .sheet.
        .interactiveDismissDisabled(isInActiveChat)
        // Age gate: server 403s with "age_required" or "under_18".
        .alert(
            ageGateTitle,
            isPresented: ageGateBinding,
            actions: { ageGateActions },
            message: { Text(ageGateMessage) }
        )
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
            // Modal dismiss + brief delay before pushing profile to
            // avoid racing SwiftUI's sheet stack.
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

    // Wrapping NavigationStack is load-bearing: on iOS 17+, an inner
    // .sheet (PhotoPicker) dismiss tears down the parent fullScreenCover
    // unless the inner sheets have a UINavigationController to scope to.
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
            // Leaving is the destructive end of the session, so it is red, and
            // the colour lives on the Text: the app sets a green `.tint` at the
            // root, and a plain `Button("…")` takes that tint no matter what
            // `.foregroundColor` the button itself carries.
            Button { dismiss() } label: {
                Text("common.close".localized)
                    .foregroundColor(Theme.Color.statusBusy)
            }
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

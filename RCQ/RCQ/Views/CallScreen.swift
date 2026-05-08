import AVKit
import SwiftUI
import WebRTC

/// Full-screen call surface: ringing, in-call, and the brief end-state hint.
struct CallScreen: View {
    @StateObject private var calls = CallService.shared
    @StateObject private var rtc = WebRTCManager.shared

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if case .connected = calls.state, let track = rtc.remoteVideoTrack {
                WebRTCVideoView(track: track)
                    .ignoresSafeArea()
            }

            switch calls.state {
            case .idle:
                EmptyView()

            case .outgoingRinging(let c):
                ringing(call: c, label: "call.outgoing.calling".localized)

            case .incomingRinging(let c):
                incoming(call: c)

            case .connected(let c):
                connected(call: c)

            case .ended(let c, let reason):
                endedOverlay(call: c, reason: reason)
            }

            if calls.incomingVideoUpgrade, case .connected(let c) = calls.state {
                videoUpgradePrompt(call: c)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .zIndex(10)
            }

            if case .connected(let c) = calls.state,
               c.media == .video,
               let local = rtc.localVideoTrack {
                VStack {
                    HStack {
                        Spacer()
                        WebRTCVideoView(track: local)
                            .frame(width: 96, height: 128)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(.white.opacity(0.15), lineWidth: 1)
                            )
                            .padding(.trailing, 18)
                    }
                    Spacer()
                }
                .padding(.top, 90)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - state surfaces

    private func ringing(call: Call, label: String) -> some View {
        VStack(spacing: 22) {
            Spacer()
            avatarOrb(call.peerNickname)
            VStack(spacing: 6) {
                Text(call.peerNickname).font(.title.bold()).foregroundColor(.white)
                Text(label).font(.callout).foregroundColor(.white.opacity(0.7))
                mediaBadge(call.media)
            }
            Spacer()
            hangupButton(label: "common.cancel".localized)
                .padding(.bottom, 60)
        }
    }

    private func incoming(call: Call) -> some View {
        VStack(spacing: 22) {
            Spacer()
            avatarOrb(call.peerNickname)
            VStack(spacing: 6) {
                Text(call.peerNickname).font(.title.bold()).foregroundColor(.white)
                Text((call.media == .video
                      ? "call.incoming.video"
                      : "call.incoming.voice").localized)
                    .font(.callout).foregroundColor(.white.opacity(0.7))
            }
            Spacer()
            HStack(spacing: 60) {
                callButton(systemName: "phone.down.fill", color: .red, label: "call.action.decline".localized) {
                    calls.decline()
                }
                callButton(systemName: "phone.fill", color: .green, label: "call.action.accept".localized) {
                    calls.accept()
                }
            }
            .padding(.bottom, 60)
        }
    }

    private func connected(call: Call) -> some View {
        VStack(spacing: 22) {
            HStack(spacing: 12) {
                Button { calls.minimize() } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(.white.opacity(0.15))
                        .clipShape(Circle())
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(call.peerNickname).font(.headline).foregroundColor(.white)
                    LiveDurationLabel(startedAt: call.startedAt)
                }
                Spacer()
                mediaBadge(call.media)
            }
            .padding(.horizontal, 18).padding(.top, 12)
            .background(
                LinearGradient(
                    colors: [.black.opacity(0.45), .clear],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea(edges: .top)
            )
            Spacer()
            if call.media == .audio {
                avatarOrb(call.peerNickname)
            }
            Spacer()
            controlBar(media: call.media)
                .padding(.bottom, 12)
            hangupButton(label: "End call")
                .padding(.bottom, 36)
        }
    }

    private func controlBar(media: CallMedia) -> some View {
        HStack(spacing: 28) {
            controlButton(
                systemName: rtc.micMuted ? "mic.slash.fill" : "mic.fill",
                active: rtc.micMuted,
                label: "Mute"
            ) { rtc.toggleMicMute() }

            if media == .video {
                controlButton(
                    systemName: rtc.cameraOff ? "video.slash.fill" : "video.fill",
                    active: rtc.cameraOff,
                    label: "Camera"
                ) { rtc.toggleCameraOff() }

                controlButton(
                    systemName: "arrow.triangle.2.circlepath.camera.fill",
                    active: false,
                    label: "Flip"
                ) { rtc.flipCamera() }
            } else {
                // Audio call → offer mid-call video upgrade.
                controlButton(
                    systemName: "video.badge.plus",
                    active: false,
                    label: calls.outgoingVideoUpgradePending ? "Waiting…" : "Camera",
                    disabled: calls.outgoingVideoUpgradePending
                ) { calls.requestVideoUpgrade() }
            }

            controlButton(
                systemName: rtc.speakerOn ? "speaker.wave.3.fill" : "speaker.wave.1.fill",
                active: rtc.speakerOn,
                label: "Speaker"
            ) { rtc.toggleSpeaker() }

            VStack(spacing: 4) {
                AudioRoutePickerButton()
                    .frame(width: 52, height: 52)
                Text("Route")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.7))
            }
        }
    }

    private func controlButton(systemName: String, active: Bool, label: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    Circle()
                        .fill(active ? Color.white : Color.white.opacity(0.15))
                        .frame(width: 52, height: 52)
                    Image(systemName: systemName)
                        .font(.system(size: 20))
                        .foregroundColor(active ? .black : .white)
                }
                Text(label)
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }

    private func endedOverlay(call: Call, reason: String) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "phone.down.fill")
                .font(.system(size: 36))
                .foregroundColor(.white.opacity(0.5))
            Text(endedTitle(for: reason))
                .font(.title3.bold()).foregroundColor(.white)
            Text(call.peerNickname)
                .font(.callout).foregroundColor(.white.opacity(0.6))
            if let duration = calls.lastCallDuration {
                Text(formatDuration(duration))
                    .font(.system(size: 32, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
            }
            Spacer()
            Button("Close") { calls.clearEnded() }
                .foregroundColor(.white.opacity(0.8))
                .padding(.bottom, 60)
        }
    }

    private func videoUpgradePrompt(call: Call) -> some View {
        VStack {
            Spacer()
            VStack(spacing: 16) {
                Image(systemName: "video.badge.plus")
                    .font(.system(size: 32))
                    .foregroundColor(.white)
                Text("\(call.peerNickname) wants to enable video")
                    .font(.headline)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                HStack(spacing: 24) {
                    Button {
                        calls.declineVideoUpgrade()
                    } label: {
                        Text("Decline")
                            .font(.callout.weight(.semibold))
                            .foregroundColor(.white)
                            .frame(minWidth: 100)
                            .padding(.vertical, 12)
                            .background(Color.white.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    Button {
                        calls.acceptVideoUpgrade()
                    } label: {
                        Text("Accept")
                            .font(.callout.weight(.semibold))
                            .foregroundColor(.black)
                            .frame(minWidth: 100)
                            .padding(.vertical, 12)
                            .background(Color.white)
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.15), lineWidth: 1)
            )
            .padding(.horizontal, 32)
            Spacer()
        }
    }

    private func formatDuration(_ secs: TimeInterval) -> String {
        let total = Int(secs.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - subviews

    private func avatarOrb(_ name: String) -> some View {
        let initial = name.first.map(String.init) ?? "?"
        return ZStack {
            Circle()
                .fill(LinearGradient(
                    colors: [Theme.Color.accent, Theme.Color.accent.opacity(0.6)],
                    startPoint: .top, endPoint: .bottom
                ))
                .frame(width: 140, height: 140)
            Text(initial.uppercased())
                .font(.system(size: 56, weight: .bold))
                .foregroundColor(.white)
        }
    }

    private func mediaBadge(_ media: CallMedia) -> some View {
        HStack(spacing: 4) {
            Image(systemName: media == .video ? "video.fill" : "phone.fill")
                .font(.system(size: 11))
            Text(media == .video ? "video" : "audio")
                .font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(.white.opacity(0.15))
        .foregroundColor(.white.opacity(0.9))
        .clipShape(Capsule())
    }

    private func hangupButton(label: String) -> some View {
        Button { calls.hangUp() } label: {
            VStack(spacing: 4) {
                ZStack {
                    Circle().fill(Color.red).frame(width: 70, height: 70)
                    Image(systemName: "phone.down.fill")
                        .font(.system(size: 26))
                        .foregroundColor(.white)
                }
                Text(label).font(.caption).foregroundColor(.white.opacity(0.7))
            }
        }
    }

    private func callButton(systemName: String, color: Color, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    Circle().fill(color).frame(width: 70, height: 70)
                    Image(systemName: systemName)
                        .font(.system(size: 26))
                        .foregroundColor(.white)
                }
                Text(label).font(.caption).foregroundColor(.white.opacity(0.7))
            }
        }
    }

    private func endedTitle(for reason: String) -> String {
        switch reason {
        case "declined":  return "Call declined"
        case "busy":      return "User is busy"
        case "cancelled": return "Call cancelled"
        case "hangup":    return "Call ended"
        default:          return "Call ended"
        }
    }
}

private struct WebRTCVideoView: UIViewRepresentable {
    let track: RTCVideoTrack

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView(frame: .zero)
        view.videoContentMode = .scaleAspectFill
        track.add(view)
        return view
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        track.add(uiView)
    }

    static func dismantleUIView(_ uiView: RTCMTLVideoView, coordinator: ()) {
    }
}

/// SwiftUI bridge for `AVRoutePickerView`.
private struct AudioRoutePickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = UIColor.white.withAlphaComponent(0.15)
        container.layer.cornerRadius = 26

        let picker = AVRoutePickerView()
        picker.activeTintColor = .white
        picker.tintColor = .white
        picker.backgroundColor = .clear
        picker.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(picker)
        NSLayoutConstraint.activate([
            picker.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            picker.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            picker.widthAnchor.constraint(equalToConstant: 36),
            picker.heightAnchor.constraint(equalToConstant: 36),
        ])
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

private struct LiveDurationLabel: View {
    let startedAt: Date
    @State private var now = Date()

    var body: some View {
        let secs = max(0, Int(now.timeIntervalSince(startedAt)))
        Text(String(format: "%d:%02d", secs / 60, secs % 60))
            .font(.system(size: 13, design: .monospaced))
            .foregroundColor(.white.opacity(0.7))
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now = $0 }
    }
}

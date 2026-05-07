import AVKit
import SwiftUI
import WebRTC

/// Full-screen call surface. Covers ringing (in & out), in-call, and the
/// brief post-end "X declined / hung up" hint before auto-dismiss.
///
/// During an active call the backdrop becomes the remote `RTCMTLVideoView`
/// (Metal-backed); a small picture-in-picture in the corner mirrors the
/// local camera so the user can frame themselves.
struct CallScreen: View {
    @StateObject private var calls = CallService.shared
    @StateObject private var rtc = WebRTCManager.shared

    var body: some View {
        ZStack {
            // Solid dark background — visible during ringing states and
            // until the first remote video frame lands.
            Color.black.ignoresSafeArea()

            // Remote video fills the whole surface once we're connected
            // and the peer's video track has arrived.
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

            // Inbound mid-call upgrade prompt. Floats above any chrome
            // (video remote, audio avatar, control bar) so the user
            // can't miss it. Auto-dismisses on Accept / Decline; also
            // disappears if the call ends or peer cancels.
            if calls.incomingVideoUpgrade, case .connected(let c) = calls.state {
                videoUpgradePrompt(call: c)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .zIndex(10)
            }

            // Local self-view PIP — only on connected video calls. Sits
            // below the top status bar (peer name + duration) so the two
            // don't overlap on devices with narrow notches. Far from the
            // hangup button so it's not accidentally tapped.
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

    /// Outgoing ringing or in-call dial-tone screen — single big avatar
    /// circle, peer nickname, "Calling…" subtitle, hangup button.
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
            // Top status bar over the remote video — peer name + duration,
            // sized to read against any background. Subtle scrim on top
            // ensures legibility even on bright video frames.
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
            // For audio-only calls the avatar fills the canvas (no remote
            // video to render). For video calls the remote RTCMTLVideoView
            // is rendered behind everything by the parent ZStack.
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

    /// Mid-call control row — mic mute, camera flip + on/off (video only),
    /// speakerphone toggle. Sits above the hangup button. Each control
    /// reflects WebRTCManager's current state via @Published bindings.
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
                // Audio call → offer "Turn on camera". Tap kicks off the
                // mid-call upgrade: local PIP lights up immediately, peer
                // gets an Accept/Decline prompt. Disabled while a previous
                // request is still awaiting the peer's answer.
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

            // Native iOS route picker — handset / speaker / BT / AirPods /
            // CarPlay all show up as a system sheet. The Speaker toggle
            // above is a 1-tap shortcut; this is the proper picker for
            // anything else (mid-call BT switch was the missing piece).
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
            // Show duration only when the call actually reached connected.
            // For declined / cancelled / busy calls `lastCallDuration` is
            // nil and we just leave the title alone ("Call declined" etc).
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

    /// Inbound audio→video upgrade prompt. Centred card with the peer
    /// name + Accept / Decline. Solid backdrop blur so it reads against
    /// either the audio avatar or a remote video frame.
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

    /// "M:SS" — same format as the live duration label.
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

/// SwiftUI bridge for `RTCMTLVideoView` — Metal-backed renderer that
/// libwebrtc fills with decoded frames as they arrive. We hand it the
/// track on creation; the framework wires the rest internally.
private struct WebRTCVideoView: UIViewRepresentable {
    let track: RTCVideoTrack

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView(frame: .zero)
        view.videoContentMode = .scaleAspectFill
        track.add(view)
        return view
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        // If a different track instance arrives (rare — typically the same
        // track lives across the whole call), reattach the renderer.
        track.add(uiView)
    }

    static func dismantleUIView(_ uiView: RTCMTLVideoView, coordinator: ()) {
        // Metal renderers hold strong refs to their last frame buffer;
        // detaching here lets WebRTC release the track cleanly when the
        // call ends and the SwiftUI view goes away.
    }
}

/// SwiftUI bridge for `AVRoutePickerView`. Tap pops the system audio
/// route sheet (handset / speaker / Bluetooth / AirPods / CarPlay).
/// Styled to match the round in-call control buttons — translucent white
/// fill, white glyph. The picker draws its own glyph; we just sit it
/// inside a circle background.
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

/// "0:42" — refreshes once a second from a Timer publisher. Lives in its
/// own subview so the surrounding CallScreen doesn't redraw the whole
/// surface every tick.
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

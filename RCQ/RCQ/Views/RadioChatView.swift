import SwiftUI
import UIKit

/// In-session chat surface for Radio Chat. Transport is
/// MultipeerConnectivity, history is in-memory, foreground only.
struct RadioChatView: View {
    @StateObject private var radio = RadioService.shared
    @State private var input: String = ""
    @State private var replyTarget: RadioMessage?
    // Tap-to-toggle PTT. Tap once to start broadcasting, tap again to
    // stop. Visual mic-fill + red background make the active state hard
    // to miss so users don't leave a hot mic open by accident.
    @State private var ptt: Bool = false

    var body: some View {
        ZStack {
            Theme.Color.bgPrimary.ignoresSafeArea()
            VStack(spacing: 0) {
                messageList
                if !radio.activeSpeakers.isEmpty {
                    speakingPill
                }
                if let reply = replyTarget {
                    replyStrip(reply)
                }
                composer
            }
        }
        .onDisappear {
            if ptt {
                ptt = false
                radio.stopTalking()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    radio.leaveActiveSession()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Theme.Color.accent)
                }
            }
            ToolbarItem(placement: .principal) {
                principalContent
            }
            ToolbarItem(placement: .topBarTrailing) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundColor(Theme.Color.statusOnline)
            }
        }
    }

    // MARK: - principal slot

    @ViewBuilder
    private var principalContent: some View {
        if let room = radio.activeRoom {
            VStack(spacing: 0) {
                Text(room.name)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundColor(Theme.Color.textPrimary)
                    .lineLimit(1)
                Text(String(format: "radio.header.room".localized, radio.roster.count))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.Color.textMono)
            }
        } else if let one = radio.activeOneToOne {
            VStack(spacing: 0) {
                Text(one.displayName)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundColor(Theme.Color.textPrimary)
                    .lineLimit(1)
                Text("radio.header.one_to_one".localized)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.Color.textMono)
            }
        }
    }

    // MARK: - Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(radio.messages) { msg in
                        bubble(msg)
                            .id(msg.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
            .scrollDismissesKeyboard(.immediately)
            .onChange(of: radio.messages.count) { _ in
                if let last = radio.messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func bubble(_ msg: RadioMessage) -> some View {
        HStack {
            if msg.isFromMe { Spacer(minLength: 30) }
            VStack(alignment: msg.isFromMe ? .trailing : .leading, spacing: 2) {
                if !msg.isFromMe {
                    Text(msg.senderDisplayName)
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(Theme.Color.accent)
                }
                if let parentSender = msg.replyToSender, let parentBody = msg.replyToBody {
                    quoteBlock(sender: parentSender, body: parentBody)
                }
                EmoticonText(text: msg.text)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Metrics.bubbleRadius)
                            .fill(msg.isFromMe ? Theme.Color.bubbleSelf : Theme.Color.bubbleOther),
                    )
                if !msg.reactions.isEmpty {
                    reactionsRow(msg.reactions)
                }
            }
            .onTapGesture(count: 2) {
                radio.toggleReaction("give_heart", on: msg)
            }
            .onLongPressGesture(minimumDuration: 0.4) {
                replyTarget = msg
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            if !msg.isFromMe { Spacer(minLength: 30) }
        }
    }

    private func quoteBlock(sender: String, body: String) -> some View {
        HStack(spacing: 6) {
            Rectangle().fill(Theme.Color.accent).frame(width: 2)
            VStack(alignment: .leading, spacing: 0) {
                Text(sender)
                    .font(.caption2.bold())
                    .foregroundColor(Theme.Color.accent)
                Text(body)
                    .font(.caption2)
                    .foregroundColor(Theme.Color.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(6)
        .background(Theme.Color.bgSecondary.opacity(0.6))
        .cornerRadius(4)
    }

    private func reactionsRow(_ reactions: [String: String]) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(Set(reactions.values)).sorted(), id: \.self) { asset in
                if GIFImage.cachedImage(for: asset) != nil {
                    GIFImage(name: asset)
                        .frame(width: 18, height: 18)
                }
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Reply strip

    private func replyStrip(_ reply: RadioMessage) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrowshape.turn.up.left")
                .font(.caption)
                .foregroundColor(Theme.Color.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(reply.senderDisplayName)
                    .font(.caption2.bold())
                    .foregroundColor(Theme.Color.accent)
                Text(reply.text)
                    .font(.caption2)
                    .foregroundColor(Theme.Color.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                replyTarget = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(Theme.Color.textSecondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }

    // MARK: - Speaking pill

    private var speakingPill: some View {
        let names = radio.activeSpeakers.sorted().joined(separator: ", ")
        return HStack(spacing: 6) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .opacity(0.9)
            Text(String(format: "radio.voice.speaking_pill".localized, names))
                .font(.caption.weight(.medium))
                .foregroundColor(Theme.Color.textPrimary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.15), value: radio.activeSpeakers)
    }

    // MARK: - Composer

    // Empty input → mic (tap-to-toggle PTT). Non-empty input → send.
    private var composer: some View {
        let inputEmpty = input.trimmingCharacters(in: .whitespaces).isEmpty
        return HStack(alignment: .center, spacing: 8) {
            TextField("radio.composer.placeholder".localized, text: $input, axis: .vertical)
                .lineLimit(1...4)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Theme.Color.bgSecondary)
                .cornerRadius(8)
            ZStack {
                if inputEmpty {
                    pttButton
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                } else {
                    sendButton
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
            }
            .frame(width: 32, height: 32)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: inputEmpty)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }

    private var sendButton: some View {
        Button {
            send()
        } label: {
            Image(systemName: "paperplane.fill")
                .font(.system(size: 18))
                .foregroundColor(Theme.Color.accent)
        }
    }

    private var pttButton: some View {
        let radius: CGFloat = 16
        return Button {
            togglePTT()
        } label: {
            Image(systemName: ptt ? "mic.fill" : "mic")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(ptt ? .white : Theme.Color.accent)
                .frame(width: 32, height: 32)
                .background(
                    Circle().fill(ptt ? Color.red : Color.clear)
                )
                .scaleEffect(ptt ? 1.08 : 1.0)
                .animation(.spring(response: 0.18, dampingFraction: 0.7), value: ptt)
                .contentShape(Circle().inset(by: -radius))
        }
        .buttonStyle(.plain)
    }

    private func togglePTT() {
        if ptt {
            ptt = false
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            radio.stopTalking()
        } else {
            ptt = true
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            radio.startTalking()
        }
    }

    private func send() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let r = replyTarget
        radio.send(text: trimmed, replyTo: r)
        input = ""
        replyTarget = nil
    }
}

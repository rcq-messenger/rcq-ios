import SwiftUI
import UIKit

/// Long-press popover for a message: reactions row + actions panel over a material backdrop.
struct MessageActionOverlay: View {
    let message: Message
    let senderNickname: String
    let canDeleteForEveryone: Bool
    let canReply: Bool
    let canEdit: Bool
    let onReact: (String) -> Void
    let onReply: () -> Void
    let onEdit: () -> Void
    let onForward: () -> Void
    let onTranslate: () -> Void
    var isTranslated: Bool = false
    let onDeleteForMe: () -> Void
    let onDeleteForEveryone: () -> Void
    let onDismiss: () -> Void
    var onReport: (() -> Void)? = nil
    var onSelect: (() -> Void)? = nil
    var onResend: (() -> Void)? = nil

    @State private var showDeleteSubmenu = false

    private static let assets: [String] = [
        "smile", "biggrin", "shok", "cray", "good", "heart",
    ]

    var body: some View {
        // Telegram-style overlay: bubble "lifts" to a comfortable
        // position with reactions strip pinned ABOVE it and actions
        // menu BELOW. For long messages we used to render the bubble
        // at its natural height in a centered VStack, which pushed
        // either the reactions strip off the top or the actions menu
        // off the bottom — testers couldn't see either. Clamping the
        // bubble's slot to ~45% of available height with internal
        // scrolling keeps both anchors on-screen for any message
        // length.
        GeometryReader { geo in
            let safeHeight = geo.size.height - geo.safeAreaInsets.top - geo.safeAreaInsets.bottom
            // Reserve enough room for the two anchor panels + label
            // + spacing; the bubble takes whatever's left of the
            // ~45% budget, with a floor so short messages don't get
            // squished.
            let bubbleMaxHeight = max(140, safeHeight * 0.45)
            ZStack {
                Rectangle()
                    .fill(.regularMaterial)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { onDismiss() }

                VStack(spacing: 10) {
                    reactionsPanel
                    ScrollView {
                        VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 2) {
                            Text(senderNickname)
                                .font(.caption.weight(.semibold))
                                .foregroundColor(Theme.Color.accent)
                                // Truncate long group nicknames so a
                                // 30-char handle doesn't wrap to two
                                // lines and break the 45% height budget
                                // calculated above.
                                .lineLimit(1)
                                .truncationMode(.tail)
                            MessagePreviewCard(message: message)
                        }
                        .frame(maxWidth: 320, alignment: message.isFromMe ? .trailing : .leading)
                    }
                    .frame(maxHeight: bubbleMaxHeight)
                    actionsPanel
                        .frame(width: 260)
                }
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .center)))
            }
        }
    }

    // MARK: - reactions

    private var reactionsPanel: some View {
        // ScrollView would happily expand to the parent's full width
        // (was: pill stretched edge-to-edge on every device). Wrap in
        // an HStack with `fixedSize` on horizontal so the ScrollView
        // sizes to its CONTENT and only kicks scrolling when the row
        // genuinely overflows (small width + Dynamic Type). The
        // outer cap of 320pt prevents the pill from ballooning past
        // a comfortable reading width even when content fits.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Self.assets, id: \.self) { asset in
                    Button {
                        onReact(asset)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        onDismiss()
                    } label: {
                        ZStack {
                            if message.reactions.values.contains(asset) {
                                RoundedRectangle(cornerRadius: 18)
                                    .fill(Theme.Color.accent.opacity(0.3))
                            }
                            GIFImage(name: asset)
                                .frame(width: 30, height: 30)
                        }
                        .frame(width: 42, height: 42)
                    }
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
        }
        .frame(maxWidth: 320)
        .fixedSize(horizontal: true, vertical: false)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 26))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
    }

    // MARK: - actions

    private var actionsPanel: some View {
        VStack(spacing: 0) {
            if showDeleteSubmenu {
                actionRow("chat.action.delete_for_me".localized, icon: "trash", destructive: true) {
                    onDeleteForMe(); onDismiss()
                }
                rowDivider
                actionRow("chat.action.delete_for_everyone".localized, icon: "trash.fill", destructive: true) {
                    onDeleteForEveryone(); onDismiss()
                }
            } else {
                if let onResend, message.deliveryState == .failed {
                    actionRow("chat.action.resend".localized, icon: "arrow.clockwise", destructive: false) {
                        onResend(); onDismiss()
                    }
                    rowDivider
                }
                if canReply && canForward {
                    actionRow("chat.action.reply".localized, icon: "arrowshape.turn.up.left", destructive: false) {
                        onReply(); onDismiss()
                    }
                    rowDivider
                }
                if canEdit {
                    actionRow("chat.action.edit".localized, icon: "pencil", destructive: false) {
                        onEdit(); onDismiss()
                    }
                    rowDivider
                }
                if canForward, message.kind == .text, !message.text.isEmpty {
                    actionRow("chat.action.copy".localized, icon: "doc.on.doc", destructive: false) {
                        UIPasteboard.general.string = message.text
                        UISelectionFeedbackGenerator().selectionChanged()
                        onDismiss()
                    }
                    rowDivider
                    actionRow(
                        (isTranslated ? "chat.action.show_original" : "chat.action.translate").localized,
                        icon: "globe",
                        destructive: false
                    ) {
                        onTranslate(); onDismiss()
                    }
                    rowDivider
                }
                if canForward {
                    actionRow("chat.action.forward".localized, icon: "arrowshape.turn.up.right", destructive: false) {
                        onForward(); onDismiss()
                    }
                    rowDivider
                }
                if let onSelect {
                    actionRow("chat.action.select".localized, icon: "checkmark.circle", destructive: false) {
                        onSelect(); onDismiss()
                    }
                    rowDivider
                }
                if let onReport, !canDeleteForEveryone {
                    actionRow(
                        "chat.action.report_content".localized,
                        icon: "exclamationmark.bubble",
                        destructive: true
                    ) {
                        onReport(); onDismiss()
                    }
                    rowDivider
                }
                if canDeleteForEveryone {
                    actionRow("chat.action.delete".localized, icon: "trash", destructive: true) {
                        withAnimation(.easeInOut(duration: 0.2)) { showDeleteSubmenu = true }
                    }
                } else {
                    actionRow("chat.action.delete_for_me".localized, icon: "trash", destructive: true) {
                        onDeleteForMe(); onDismiss()
                    }
                }
            }
        }
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 0.33)
    }

    private var canForward: Bool {
        if message.deletedForEveryone { return false }
        switch message.kind {
        case .text, .photo, .video: return true
        default: return false
        }
    }

    private func actionRow(
        _ title: String,
        icon: String?,
        destructive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let tint: Color = destructive ? Color.red : Theme.Color.textPrimary
        return Button(action: action) {
            HStack(spacing: 12) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundColor(tint)
                        .frame(width: 22, alignment: .center)
                }
                Text(title)
                    .font(.system(size: 16))
                    .foregroundColor(tint)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var panelBackground: some View {
        Rectangle().fill(.regularMaterial)
    }
}

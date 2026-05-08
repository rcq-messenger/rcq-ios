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

    @State private var showDeleteSubmenu = false

    private static let assets: [String] = [
        "smile", "biggrin", "shok", "cray", "good", "heart",
    ]

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            VStack(spacing: 10) {
                reactionsPanel
                VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 2) {
                    Text(senderNickname)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(Theme.Color.accent)
                    MessagePreviewCard(message: message)
                }
                .frame(maxWidth: 320, alignment: message.isFromMe ? .trailing : .leading)
                actionsPanel
                    .frame(width: 260)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .center)))
        }
    }

    // MARK: - reactions

    private var reactionsPanel: some View {
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
